import Foundation

struct MarkdownDocument {
    var source: String
    var blocks: [MarkdownBlock]
    var affectedRange: NSRange?
    var revision: Int
}

final class MarkdownDocumentState {
    var lines: [LineState] = []
    var revision: Int = 0
    var totalLength: Int = 0

    var blocks: [MarkdownBlock] {
        lines.flatMap(\.blocks)
    }

    func makeDocument(source: String, affectedRange: NSRange?) -> MarkdownDocument {
        MarkdownDocument(source: source, blocks: blocks, affectedRange: affectedRange, revision: revision)
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

enum ParserState: Hashable {
    case normal
    case inBlockquote
    case inCodeBlock
    case inList(indent: Int)

    var stableKey: String {
        switch self {
        case .normal:
            return "normal"
        case .inBlockquote:
            return "blockquote"
        case .inCodeBlock:
            return "code"
        case let .inList(indent):
            return "list:\(indent)"
        }
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
