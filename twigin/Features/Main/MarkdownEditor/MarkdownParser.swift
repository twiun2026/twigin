import Foundation
import Markdown

struct MarkdownParser {
    func parse(_ source: String) -> MarkdownDocument {
        let doc = Document(parsing: source)
        var visitor = BlockVisitor(source: source)
        visitor.visit(doc)
        return MarkdownDocument(source: source, blocks: visitor.blocks)
    }
}

// MARK: - SourceRange → NSRange

/// Pre-computes a UTF-8 line-start table so each `SourceLocation`
/// (1-based line, 1-based UTF-8-byte column) can be converted to a
/// UTF-16 `NSRange` offset in O(1).
///
/// Conversion chain:
///   line + column → absolute UTF-8 byte position
///                 → `String.Index`  (encoding-agnostic)
///                 → UTF-16 offset   (for `NSRange`)
///
/// This is always safe: UTF-8 byte boundaries align with Unicode scalar
/// boundaries, which also align with UTF-16 boundaries (a 4-byte UTF-8
/// sequence is a surrogate pair in UTF-16 — both are indivisible).
/// Therefore `samePosition(in: utf16)` never returns `nil` for any valid
/// swift-markdown column value.
private struct RangeConverter {
    let source: String
    let ns: NSString
    // utf8ByteOffset[i] = byte offset of line (i+1) start; 0-indexed
    private let lineStarts: [Int]

    init(source: String) {
        self.source = source
        self.ns = source as NSString
        var starts = [0]
        var offset = 0
        for byte in source.utf8 {
            offset += 1
            if byte == 10 { starts.append(offset) }   // '\n'
        }
        lineStarts = starts
    }

    func utf16Offset(line: Int, column: Int) -> Int? {
        let li = line - 1
        guard li >= 0, li < lineStarts.count, column >= 1 else { return nil }
        let utf8Pos = lineStarts[li] + (column - 1)
        let utf8 = source.utf8
        guard utf8Pos <= utf8.count else { return nil }
        let idx = utf8.index(utf8.startIndex, offsetBy: utf8Pos)
        let utf16 = source.utf16
        guard let u16 = idx.samePosition(in: utf16) else { return nil }
        return utf16.distance(from: utf16.startIndex, to: u16)
    }

    func nsRange(for range: SourceRange) -> NSRange? {
        guard
            let lo = utf16Offset(line: range.lowerBound.line, column: range.lowerBound.column),
            let hi = utf16Offset(line: range.upperBound.line, column: range.upperBound.column),
            lo <= hi, hi <= ns.length
        else { return nil }
        return NSRange(location: lo, length: hi - lo)
    }

    /// Strips a trailing `\n` (and optional `\r`) from an `NSRange`.
    func trimmingNewline(_ r: NSRange) -> NSRange {
        var end = NSMaxRange(r)
        guard end > r.location, end <= ns.length else { return r }
        if ns.character(at: end - 1) == 10 {
            end -= 1
            if end > r.location, ns.character(at: end - 1) == 13 { end -= 1 }
        }
        return NSRange(location: r.location, length: max(0, end - r.location))
    }
}

// MARK: - Block Visitor

private struct BlockVisitor: MarkupVisitor {
    typealias Result = Void

    let conv: RangeConverter
    var blocks: [MarkdownBlock] = []

    init(source: String) { conv = RangeConverter(source: source) }

    mutating func defaultVisit(_ markup: Markup) {}

    mutating func visitDocument(_ document: Document) {
        for child in document.children { visit(child) }
    }

    // MARK: Heading

    mutating func visitHeading(_ heading: Heading) {
        guard let raw = heading.range, let r = conv.nsRange(for: raw) else { return }
        let lineRange = conv.trimmingNewline(r)
        let level = heading.level
        let markerRange = NSRange(location: lineRange.location,
                                  length: min(level, lineRange.length))
        // Skip '#' chars and any following whitespace to locate content
        let ns = conv.ns
        var cs = lineRange.location + level
        while cs < NSMaxRange(lineRange) {
            let c = ns.character(at: cs)
            guard c == 32 || c == 9 else { break }
            cs += 1
        }
        let contentRange = NSRange(location: cs, length: max(0, NSMaxRange(lineRange) - cs))
        blocks.append(.heading(level: level, markerRange: markerRange,
                               contentRange: contentRange, lineRange: lineRange))
    }

    // MARK: Paragraph

    mutating func visitParagraph(_ paragraph: Paragraph) {
        guard let raw = paragraph.range, let r = conv.nsRange(for: raw) else { return }
        let lineRange = conv.trimmingNewline(r)
        // A paragraph containing only an Image becomes a block-level image
        let children = Array(paragraph.children)
        if children.count == 1, let img = children[0] as? Image {
            blocks.append(.image(alt: img.plainText, path: img.source ?? "", lineRange: lineRange))
            return
        }
        blocks.append(.paragraph(lineRange: lineRange, inlines: inlinePass(paragraph)))
    }

    // MARK: Lists

    mutating func visitUnorderedList(_ list: UnorderedList) {
        for child in list.children {
            guard let item = child as? ListItem else { continue }
            processUnorderedItem(item)
        }
    }

    mutating func visitOrderedList(_ list: OrderedList) {
        var idx = Int(list.startIndex)
        for child in list.children {
            guard let item = child as? ListItem else { continue }
            processOrderedItem(item, index: idx)
            idx += 1
        }
    }

    // List items are handled exclusively by the parent list visitors above.
    mutating func visitListItem(_ listItem: ListItem) {}

    private mutating func processUnorderedItem(_ item: ListItem) {
        guard let raw = item.range, let r = conv.nsRange(for: raw) else { return }
        let lineRange = conv.trimmingNewline(r)
        let para = item.children.compactMap { $0 as? Paragraph }.first
        let contentRange = para
            .flatMap { $0.range.flatMap { conv.nsRange(for: $0) } }
            .map { conv.trimmingNewline($0) } ?? lineRange
        let inlines = para.map { inlinePass($0) } ?? []

        if let checkbox = item.checkbox {
            let markerLen = max(0, contentRange.location - lineRange.location)
            blocks.append(.checklist(
                marker: checkbox == .checked ? .checked : .unchecked,
                markerRange: NSRange(location: lineRange.location, length: markerLen),
                contentRange: contentRange, lineRange: lineRange, inlines: inlines))
        } else {
            // Locate the bullet character (-, *, +), skipping any leading spaces
            let ns = conv.ns
            var mLoc = lineRange.location
            while mLoc < NSMaxRange(lineRange), ns.character(at: mLoc) == 32 { mLoc += 1 }
            let markerRange = NSRange(location: mLoc,
                                      length: mLoc < NSMaxRange(lineRange) ? 1 : 0)
            blocks.append(.bulletList(markerRange: markerRange, contentRange: contentRange,
                                      lineRange: lineRange, inlines: inlines))
        }
    }

    private mutating func processOrderedItem(_ item: ListItem, index: Int) {
        guard let raw = item.range, let r = conv.nsRange(for: raw) else { return }
        let lineRange = conv.trimmingNewline(r)
        let para = item.children.compactMap { $0 as? Paragraph }.first
        let contentRange = para
            .flatMap { $0.range.flatMap { conv.nsRange(for: $0) } }
            .map { conv.trimmingNewline($0) } ?? lineRange
        let inlines = para.map { inlinePass($0) } ?? []
        // Marker covers "1." — everything before the space that precedes content text
        let markerLen = max(0, contentRange.location - lineRange.location - 1)
        let markerRange = NSRange(location: lineRange.location, length: markerLen)
        blocks.append(.orderedList(index: index, markerRange: markerRange,
                                   contentRange: contentRange, lineRange: lineRange, inlines: inlines))
    }

    // MARK: Blockquote

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        guard let raw = blockQuote.range, let r = conv.nsRange(for: raw) else { return }
        let lineRange = conv.trimmingNewline(r)
        let markerRange = NSRange(location: lineRange.location, length: 1)
        let cs = min(lineRange.location + 2, NSMaxRange(lineRange))
        let contentRange = NSRange(location: cs, length: max(0, NSMaxRange(lineRange) - cs))
        var inlines: [MarkdownInline] = []
        for child in blockQuote.children {
            if let para = child as? Paragraph { inlines += inlinePass(para) }
        }
        blocks.append(.blockquote(markerRange: markerRange, contentRange: contentRange,
                                  lineRange: lineRange, inlines: inlines))
    }

    // Non-mutating: creates a temporary InlineVisitor, never modifies self.
    private func inlinePass(_ markup: Markup) -> [MarkdownInline] {
        var v = InlineVisitor(conv: conv)
        for child in markup.children { v.visit(child) }
        return v.inlines
    }
}

// MARK: - Inline Visitor

private struct InlineVisitor: MarkupVisitor {
    typealias Result = Void

    let conv: RangeConverter
    var inlines: [MarkdownInline] = []

    mutating func defaultVisit(_ markup: Markup) {
        for child in markup.children { visit(child) }
    }

    // Block-level handler covers standalone images; ignore inline images here.
    mutating func visitImage(_ image: Image) {}

    mutating func visitStrong(_ strong: Strong) {
        if let i = markedInline(strong, width: 2, make: MarkdownInline.bold) { inlines.append(i) }
        for child in strong.children { visit(child) }
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        if let i = markedInline(emphasis, width: 1, make: MarkdownInline.italic) { inlines.append(i) }
        for child in emphasis.children { visit(child) }
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        if let i = markedInline(strikethrough, width: 2, make: MarkdownInline.strike) { inlines.append(i) }
        for child in strikethrough.children { visit(child) }
    }

    mutating func visitInlineCode(_ code: InlineCode) {
        guard let raw = code.range, let full = conv.nsRange(for: raw), full.length >= 2 else { return }
        // Detect actual backtick-run length to support ``code`` style spans.
        let ns = conv.ns
        var mLen = 0
        while full.location + mLen < NSMaxRange(full),
              ns.character(at: full.location + mLen) == 96 { mLen += 1 }  // '`'
        guard mLen > 0, full.length >= mLen * 2 else { return }
        inlines.append(.code(
            markerOpen:  NSRange(location: full.location, length: mLen),
            textRange:   NSRange(location: full.location + mLen, length: full.length - mLen * 2),
            markerClose: NSRange(location: NSMaxRange(full) - mLen, length: mLen)))
    }

    // ==highlight== is not part of CommonMark or GFM; we detect it via a local
    // regex scan on plain Text nodes, which swift-markdown leaves unparsed.
    private static let highlightRx = try! NSRegularExpression(
        pattern: #"(==)(?=\S)(.+?)(?<=\S)(==)"#)

    mutating func visitText(_ text: Text) {
        guard let raw = text.range, let nr = conv.nsRange(for: raw), nr.length > 0 else { return }
        let str = conv.ns.substring(with: nr)
        let local = NSRange(location: 0, length: (str as NSString).length)
        for m in Self.highlightRx.matches(in: str, range: local) {
            inlines.append(.highlight(
                markerOpen:  m.range(at: 1).shifted(by: nr.location),
                textRange:   m.range(at: 2).shifted(by: nr.location),
                markerClose: m.range(at: 3).shifted(by: nr.location)))
        }
    }

    private func markedInline(
        _ node: Markup,
        width: Int,
        make: (NSRange, NSRange, NSRange) -> MarkdownInline
    ) -> MarkdownInline? {
        guard let raw = node.range, let full = conv.nsRange(for: raw),
              full.length >= width * 2 else { return nil }
        return make(
            NSRange(location: full.location, length: width),
            NSRange(location: full.location + width, length: full.length - width * 2),
            NSRange(location: NSMaxRange(full) - width, length: width))
    }
}

private extension NSRange {
    func shifted(by n: Int) -> NSRange { NSRange(location: location + n, length: length) }
}
