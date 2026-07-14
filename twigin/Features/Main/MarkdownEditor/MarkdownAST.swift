import Foundation

struct MarkdownDocument {
    var source: String
    var blocks: [MarkdownBlock]
}

enum MarkdownBlock {
    case heading(level: Int, markerRange: NSRange, contentRange: NSRange, lineRange: NSRange)
    case paragraph(lineRange: NSRange, inlines: [MarkdownInline])
    case checklist(marker: ChecklistMarker, markerRange: NSRange, contentRange: NSRange, lineRange: NSRange, inlines: [MarkdownInline])
    case image(alt: String, path: String, lineRange: NSRange)
    case bulletList(markerRange: NSRange, contentRange: NSRange, lineRange: NSRange, inlines: [MarkdownInline])
    case orderedList(index: Int, markerRange: NSRange, contentRange: NSRange, lineRange: NSRange, inlines: [MarkdownInline])
    case blockquote(markerRange: NSRange, contentRange: NSRange, lineRange: NSRange, inlines: [MarkdownInline])
}

enum MarkdownInline {
    case bold(markerOpen: NSRange, textRange: NSRange, markerClose: NSRange)
    case italic(markerOpen: NSRange, textRange: NSRange, markerClose: NSRange)
    case strike(markerOpen: NSRange, textRange: NSRange, markerClose: NSRange)
    case code(markerOpen: NSRange, textRange: NSRange, markerClose: NSRange)
    case highlight(markerOpen: NSRange, textRange: NSRange, markerClose: NSRange)

    var markerRanges: [NSRange] {
        switch self {
        case let .bold(markerOpen, _, markerClose),
             let .italic(markerOpen, _, markerClose),
             let .strike(markerOpen, _, markerClose),
             let .code(markerOpen, _, markerClose),
             let .highlight(markerOpen, _, markerClose):
            return [markerOpen, markerClose]
        }
    }

    var contentRange: NSRange {
        switch self {
        case let .bold(_, textRange, _),
             let .italic(_, textRange, _),
             let .strike(_, textRange, _),
             let .code(_, textRange, _),
             let .highlight(_, textRange, _):
            return textRange
        }
    }
}

enum ChecklistMarker {
    case unchecked
    case checked
}
