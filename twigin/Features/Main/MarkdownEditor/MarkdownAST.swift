import Foundation

nonisolated struct MarkdownDocument {
    var source: String
    var affectedRange: NSRange?
    var blockDiff: MarkdownBlockDiff?
    var revision: Int
    // 直接持有行树，blocks 改为按需物化：增量渲染只用 blockDiff/affectedRange，
    // 不会触发全量 O(N) 物化；仅全量渲染 / containers 访问时才遍历整树。
    var lineStore: LineStore = .empty
    // 异步管线的全量渲染：后台已物化好的块直接携带，主线程无需再访问行树。
    var explicitBlocks: [MarkdownBlock]? = nil

    var blocks: [MarkdownBlock] {
        explicitBlocks ?? lineStore.materializedBlocks()
    }

    // 全量渲染变体：清空增量信息但共享同一行树。
    func makingFullRender() -> MarkdownDocument {
        MarkdownDocument(source: source, affectedRange: nil, blockDiff: nil, revision: revision, lineStore: lineStore)
    }
}

nonisolated final class MarkdownDocumentState {
    var lineStore: LineStore = .empty
    var revision: Int = 0
    var totalLength: Int = 0

    func makeDocument(source: String, affectedRange: NSRange?, blockDiff: MarkdownBlockDiff? = nil) -> MarkdownDocument {
        MarkdownDocument(source: source, affectedRange: affectedRange, blockDiff: blockDiff, revision: revision, lineStore: lineStore)
    }
}

nonisolated struct LineState: Sendable {
    var lineIndex: Int
    // lineRange：在 LineStore 中以“行内相对坐标”存储（location 相对行首，通常为 0）；
    // 经 LineStore.absoluteLine(at:) 物化后为绝对坐标。
    var lineRange: NSRange
    // fullLength：该行推进长度（含换行符，UTF-16）。绝对偏移由各行 fullLength 前缀和求得，
    // 这是“消灭 shift”的核心——位置不再存储，编辑后自动重算。
    var fullLength: Int
    var textHash: UInt64
    var stateHash: UInt64
    var incomingState: ParserState
    var outgoingState: ParserState
    var blocks: [MarkdownBlock]
    var containsUnresolvedSyntax: Bool

    var semanticSignature: UInt64 {
        MarkdownStableHash.hash(
            [
                incomingState.stableKey,
                outgoingState.stableKey,
                containsUnresolvedSyntax ? "1" : "0",
                String(textHash)
            ] + blocks.map { String($0.id) }
        )
    }

    func isPropagationStable(comparedTo other: LineState) -> Bool {
        incomingState.isSemanticallyEqual(to: other.incomingState)
            && outgoingState.isSemanticallyEqual(to: other.outgoingState)
            && semanticSignature == other.semanticSignature
    }

    func shifted(by delta: Int, lineIndex: Int? = nil) -> LineState {
        LineState(
            lineIndex: lineIndex ?? self.lineIndex,
            lineRange: lineRange.shifted(by: delta),
            fullLength: fullLength,
            textHash: textHash,
            stateHash: stateHash,
            incomingState: incomingState,
            outgoingState: outgoingState,
            blocks: blocks.map { $0.shifted(by: delta) },
            containsUnresolvedSyntax: containsUnresolvedSyntax
        )
    }

    // 绝对 → 相对：把行首归零，块/内联转为行内相对坐标（入树前调用）。
    func madeRelative() -> LineState {
        shifted(by: -lineRange.location)
    }
}

nonisolated struct ParserState: Hashable, Sendable {
    struct CodeFenceState: Hashable, Sendable {
        var fenceToken: String
    }

    struct ListContext: Hashable, Sendable {
        enum Kind: String, Hashable, Sendable {
            case bullet
            case ordered
            case checklist
        }

        var kind: Kind
        var indent: Int
    }

    enum HTMLBlockState: String, Hashable, Sendable {
        case inactive
        case active
    }

    enum TableState: String, Hashable, Sendable {
        case inactive
        case active
    }

    enum FootnoteState: String, Hashable, Sendable {
        case inactive
        case active
    }

    enum ReferenceDefinitionState: String, Hashable, Sendable {
        case inactive
        case active
    }

    enum MathBlockState: String, Hashable, Sendable {
        case inactive
        case active
    }

    var codeFence: CodeFenceState?
    var quoteDepth: Int
    var listStack: [ListContext]
    var htmlBlock: HTMLBlockState
    var table: TableState
    var footnote: FootnoteState
    var referenceDefinition: ReferenceDefinitionState
    var mathBlock: MathBlockState

    static let normal = ParserState(
        codeFence: nil,
        quoteDepth: 0,
        listStack: [],
        htmlBlock: .inactive,
        table: .inactive,
        footnote: .inactive,
        referenceDefinition: .inactive,
        mathBlock: .inactive
    )

    var isInCodeFence: Bool {
        codeFence != nil
    }

    var listIndent: Int? {
        listStack.last?.indent
    }

    func settingCodeFence(_ fence: CodeFenceState?) -> ParserState {
        var copy = self
        copy.codeFence = fence
        return copy
    }

    func settingQuoteDepth(_ depth: Int) -> ParserState {
        var copy = self
        copy.quoteDepth = max(0, depth)
        return copy
    }

    func settingListStack(_ stack: [ListContext]) -> ParserState {
        var copy = self
        copy.listStack = stack
        return copy
    }

    func isSemanticallyEqual(to other: ParserState) -> Bool {
        self == other
    }

    var stableKey: String {
        let fenceKey = codeFence?.fenceToken ?? "-"
        let listKey = listStack.map { "\($0.kind.rawValue):\($0.indent)" }.joined(separator: ",")
        return [
            "code:\(fenceKey)",
            "quote:\(quoteDepth)",
            "list:[\(listKey)]",
            "html:\(htmlBlock.rawValue)",
            "table:\(table.rawValue)",
            "footnote:\(footnote.rawValue)",
            "ref:\(referenceDefinition.rawValue)",
            "math:\(mathBlock.rawValue)"
        ].joined(separator: "|")
    }
}

nonisolated struct MarkdownBlockDiff: Sendable {
    enum Operation: Sendable {
        case insert(MarkdownBlock)
        case delete(MarkdownBlock)
        case modify(old: MarkdownBlock, new: MarkdownBlock)

        var newBlock: MarkdownBlock? {
            switch self {
            case let .insert(block):
                return block
            case .delete:
                return nil
            case let .modify(_, new):
                return new
            }
        }
    }

    var operations: [Operation]

    var isEmpty: Bool {
        operations.isEmpty
    }
}

// 容器角色：用于在保留单行块粒度的同时，表达多行容器块（如围栏代码块）的归属关系。
// 仅由单行状态推导（isInCodeFence / fence 匹配），不进入 ParserState，故完全不影响
// 现有的 reuse 指纹与 short-circuit 提前终止。
nonisolated enum ContainerRole: Hashable, Sendable {
    case none            // 独立单行块
    case containerStart  // 容器起始行（``` 开栏）
    case containerBody   // 容器内部行（含闭栏行）
}

nonisolated struct MarkdownBlock: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case heading(level: Int)
        case paragraph
        case checklist(marker: ChecklistMarker)
        case image(alt: String, path: String)
        case bulletList
        case orderedList(index: Int)
        case blockquote
        case codeBlock

        var stableKey: String {
            switch self {
            case let .heading(level):
                return "heading:\(level)"
            case .paragraph:
                return "paragraph"
            case let .checklist(marker):
                return "checklist:\(marker.rawValue)"
            case let .image(alt, path):
                return "image:\(alt)|\(path)"
            case .bulletList:
                return "bullet"
            case let .orderedList(index):
                return "ordered:\(index)"
            case .blockquote:
                return "blockquote"
            case .codeBlock:
                return "codeblock"
            }
        }
    }

    var id: UInt64
    var kind: Kind
    var markerRange: NSRange?
    var contentRange: NSRange?
    var lineRange: NSRange
    var inlines: [MarkdownInline]
    var containerRole: ContainerRole = .none

    func shifted(by delta: Int) -> MarkdownBlock {
        MarkdownBlock(
            id: id,
            kind: kind,
            markerRange: markerRange?.shifted(by: delta),
            contentRange: contentRange?.shifted(by: delta),
            lineRange: lineRange.shifted(by: delta),
            inlines: inlines.map { $0.shifted(by: delta) },
            containerRole: containerRole
        )
    }
}

// 多行容器块的聚合视图：由连续的 per-line 块合并得到，携带完整起止范围。
// 提供给 AST 消费方（渲染/折叠/大纲）以正确表达“一整块代码围栏”等容器语义，
// 而底层仍维持单行块粒度以支撑增量 diff 与 short-circuit。
nonisolated struct MarkdownContainerBlock {
    var id: UInt64            // 稳定 id = 起始行 block.id（行内相对坐标哈希，位置无关）
    var kind: MarkdownBlock.Kind
    var lineRange: NSRange    // 容器起止绝对范围（各成员行的并集）
    var members: [MarkdownBlock]

    var isMultiline: Bool { members.count > 1 }
}

nonisolated extension MarkdownDocument {
    // 将 blocks 聚合为容器视图：遇 .containerStart 起新组，.containerBody 续接，
    // 其余块各自成为单成员容器。相邻同语言代码块靠 .containerStart 强制切分，不会误并。
    var containers: [MarkdownContainerBlock] {
        var result: [MarkdownContainerBlock] = []
        var current: MarkdownContainerBlock?

        func flush() {
            if let container = current { result.append(container) }
            current = nil
        }

        for block in blocks {
            switch block.containerRole {
            case .containerStart:
                flush()
                current = MarkdownContainerBlock(id: block.id, kind: block.kind, lineRange: block.lineRange, members: [block])
            case .containerBody:
                if var container = current {
                    container.lineRange = NSUnionRange(container.lineRange, block.lineRange)
                    container.members.append(block)
                    current = container
                } else {
                    // 容器体出现在没有起始行的上下文（如增量窗口边界），单独成组以保持健壮。
                    current = MarkdownContainerBlock(id: block.id, kind: block.kind, lineRange: block.lineRange, members: [block])
                }
            case .none:
                flush()
                result.append(MarkdownContainerBlock(id: block.id, kind: block.kind, lineRange: block.lineRange, members: [block]))
            }
        }
        flush()
        return result
    }
}

nonisolated struct MarkdownInline: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case bold
        case italic
        case strike
        case code
        case highlight
    }

    var kind: Kind
    var markerOpen: NSRange
    var textRange: NSRange
    var markerClose: NSRange

    var markerRanges: [NSRange] {
        [markerOpen, markerClose]
    }

    var contentRange: NSRange {
        textRange
    }

    func shifted(by delta: Int) -> MarkdownInline {
        MarkdownInline(
            kind: kind,
            markerOpen: markerOpen.shifted(by: delta),
            textRange: textRange.shifted(by: delta),
            markerClose: markerClose.shifted(by: delta)
        )
    }
}

nonisolated enum ChecklistMarker: String, Hashable, Sendable {
    case unchecked
    case checked
}

nonisolated enum MarkdownStableHash {
    private static let offsetBasis: UInt64 = 1_469_598_103_934_665_603
    private static let prime: UInt64 = 1_099_511_628_211

    static func hash(_ components: [String]) -> UInt64 {
        var value = offsetBasis
        for component in components {
            mix(component, into: &value)
        }
        return value
    }

    static func hash(_ component: String) -> UInt64 {
        hash([component])
    }

    private static func mix(_ component: String, into value: inout UInt64) {
        for byte in component.utf8 {
            value ^= UInt64(byte)
            value &*= prime
        }
        value ^= 0xFF
        value &*= prime
    }
}

private nonisolated extension NSRange {
    func shifted(by delta: Int) -> NSRange {
        NSRange(location: location + delta, length: length)
    }
}
