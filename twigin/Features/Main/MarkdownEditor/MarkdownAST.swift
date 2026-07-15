import Foundation

struct MarkdownDocument {
    var source: String
    var blocks: [MarkdownBlock]
    var affectedRange: NSRange?
    var blockDiff: MarkdownBlockDiff?
    var revision: Int
}

final class MarkdownDocumentState {
    var lines: [LineState] = []
    var revision: Int = 0
    var totalLength: Int = 0

    var blocks: [MarkdownBlock] {
        lines.flatMap(\.blocks)
    }

    func makeDocument(source: String, affectedRange: NSRange?, blockDiff: MarkdownBlockDiff? = nil) -> MarkdownDocument {
        MarkdownDocument(source: source, blocks: blocks, affectedRange: affectedRange, blockDiff: blockDiff, revision: revision)
    }
}

struct LineState {
    var lineIndex: Int
    var lineRange: NSRange
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
            textHash: textHash,
            stateHash: stateHash,
            incomingState: incomingState,
            outgoingState: outgoingState,
            blocks: blocks.map { $0.shifted(by: delta) },
            containsUnresolvedSyntax: containsUnresolvedSyntax
        )
    }
}

struct ParserState: Hashable {
    struct CodeFenceState: Hashable {
        var fenceToken: String
    }

    struct ListContext: Hashable {
        enum Kind: String, Hashable {
            case bullet
            case ordered
            case checklist
        }

        var kind: Kind
        var indent: Int
    }

    enum HTMLBlockState: String, Hashable {
        case inactive
        case active
    }

    enum TableState: String, Hashable {
        case inactive
        case active
    }

    enum FootnoteState: String, Hashable {
        case inactive
        case active
    }

    enum ReferenceDefinitionState: String, Hashable {
        case inactive
        case active
    }

    enum MathBlockState: String, Hashable {
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

struct MarkdownBlockDiff {
    enum Operation {
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

struct MarkdownBlock: Hashable {
    enum Kind: Hashable {
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

    func shifted(by delta: Int) -> MarkdownBlock {
        MarkdownBlock(
            id: id,
            kind: kind,
            markerRange: markerRange?.shifted(by: delta),
            contentRange: contentRange?.shifted(by: delta),
            lineRange: lineRange.shifted(by: delta),
            inlines: inlines.map { $0.shifted(by: delta) }
        )
    }
}

struct MarkdownInline: Hashable {
    enum Kind: String, Hashable {
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

enum ChecklistMarker: String, Hashable {
    case unchecked
    case checked
}

enum MarkdownStableHash {
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

private extension NSRange {
    func shifted(by delta: Int) -> NSRange {
        NSRange(location: location + delta, length: length)
    }
}
