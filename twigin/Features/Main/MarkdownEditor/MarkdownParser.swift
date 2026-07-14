import Foundation

struct MarkdownParser {
    private static let headingRegex = try! NSRegularExpression(pattern: "^(#{1,6})\\s*(.*)$", options: [.anchorsMatchLines])
    private static let checklistRegex = try! NSRegularExpression(pattern: "^\\s*[-*]\\s+\\[( |x|X)\\]\\s*(.*)$", options: [.anchorsMatchLines])
    private static let imageRegex = try! NSRegularExpression(pattern: "^!\\[([^\\]]*)\\]\\(([^\\)]+)\\)\\s*$", options: [.anchorsMatchLines])
    
    private static let bulletListRegex = try! NSRegularExpression(pattern: "^\\s*([-*+])(?!\\s*\\[)\\s*(.*)$", options: [.anchorsMatchLines])
    private static let orderedListRegex = try! NSRegularExpression(pattern: "^\\s*(\\d+)\\.\\s*(.*)$", options: [.anchorsMatchLines])
    private static let blockquoteRegex = try! NSRegularExpression(pattern: "^(\\s*>)\\s*(.*)$", options: [.anchorsMatchLines])
    private static let boldRegex = try! NSRegularExpression(pattern: "(\\*\\*)(?=\\S)(.+?)(?<=\\S)(\\*\\*)", options: [])
    private static let italicRegex = try! NSRegularExpression(pattern: "(?<!\\*)(\\*)(?=\\S)(.+?)(?<=\\S)(\\*)(?!\\*)", options: [])
    private static let strikeRegex = try! NSRegularExpression(pattern: "(~~)(?=\\S)(.+?)(?<=\\S)(~~)", options: [])
    private static let codeRegex = try! NSRegularExpression(pattern: "(`)(.+?)(`)", options: [])
    private static let highlightRegex = try! NSRegularExpression(pattern: "(==)(?=\\S)(.+?)(?<=\\S)(==)", options: [])
    
    func parse(_ source: String) -> MarkdownDocument {
        let ns = source as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var blocks: [MarkdownBlock] = []

        ns.enumerateSubstrings(in: fullRange, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let lineText = ns.substring(with: lineRange)
            let lineTextRange = NSRange(location: 0, length: (lineText as NSString).length)

            if let headingMatch = Self.headingRegex.firstMatch(in: lineText, options: [], range: lineTextRange) {
                let marker = headingMatch.range(at: 1).offsetBy(lineRange.location)
                let content = headingMatch.range(at: 2).offsetBy(lineRange.location)
                let level = marker.length
                blocks.append(.heading(level: level, markerRange: marker, contentRange: content, lineRange: lineRange))
                return
            }

            if let checklistMatch = Self.checklistRegex.firstMatch(in: lineText, options: [], range: lineTextRange) {
                let stateSymbol = (lineText as NSString).substring(with: checklistMatch.range(at: 1))
                let state: ChecklistMarker = (stateSymbol.lowercased() == "x") ? .checked : .unchecked

                let marker = checklistMatch.range.offsetBy(lineRange.location)
                let content = checklistMatch.range(at: 2).offsetBy(lineRange.location)
                let inlines = parseInline(for: source, in: lineRange)
                blocks.append(.checklist(marker: state, markerRange: marker, contentRange: content, lineRange: lineRange, inlines: inlines))
                return
            }
            
            if let bulletMatch = Self.bulletListRegex.firstMatch(in: lineText, options: [], range: lineTextRange) {
                let marker = bulletMatch.range(at: 1).offsetBy(lineRange.location)
                let content = bulletMatch.range(at: 2).offsetBy(lineRange.location)
                let inlines = parseInline(for: source, in: lineRange)
                blocks.append(.bulletList(markerRange: marker, contentRange: content, lineRange: lineRange, inlines: inlines))
                return
            }
            
            if let orderedMatch = Self.orderedListRegex.firstMatch(in: lineText, options: [], range: lineTextRange) {
                let indexStr = (lineText as NSString).substring(with: orderedMatch.range(at: 1))
                let index = Int(indexStr) ?? 1
                let marker = NSRange(location: orderedMatch.range(at: 1).location, length: orderedMatch.range(at: 1).length + 1) // 包括 "." 号
                let markerOffset = marker.offsetBy(lineRange.location)
                let content = orderedMatch.range(at: 2).offsetBy(lineRange.location)
                let inlines = parseInline(for: source, in: lineRange)
                blocks.append(.orderedList(index: index, markerRange: markerOffset, contentRange: content, lineRange: lineRange, inlines: inlines))
                return
            }
            
            if let imageMatch = Self.imageRegex.firstMatch(in: lineText, options: [], range: lineTextRange) {
                let alt = (lineText as NSString).substring(with: imageMatch.range(at: 1))
                let path = (lineText as NSString).substring(with: imageMatch.range(at: 2))
                blocks.append(.image(alt: alt, path: path, lineRange: lineRange))
                return
            }

            if let blockquoteMatch = Self.blockquoteRegex.firstMatch(in: lineText, options: [], range: lineTextRange) {
                let marker = blockquoteMatch.range(at: 1).offsetBy(lineRange.location)
                let content = blockquoteMatch.range(at: 2).offsetBy(lineRange.location)
                let inlines = parseInline(for: source, in: lineRange)
                blocks.append(.blockquote(markerRange: marker, contentRange: content, lineRange: lineRange, inlines: inlines))
                return
            }

            let inlines = parseInline(for: source, in: lineRange)
            blocks.append(.paragraph(lineRange: lineRange, inlines: inlines))
        }

        return MarkdownDocument(source: source, blocks: blocks)
    }

    private func parseInline(for source: String, in lineRange: NSRange) -> [MarkdownInline] {
        let ns = source as NSString
        let lineText = ns.substring(with: lineRange)
        let lineTextRange = NSRange(location: 0, length: (lineText as NSString).length)
        var result: [MarkdownInline] = []

        func appendInlineMatches(_ regex: NSRegularExpression, mapper: (NSTextCheckingResult, Int) -> MarkdownInline) {
            let matches = regex.matches(in: lineText, options: [], range: lineTextRange)
            for match in matches {
                result.append(mapper(match, lineRange.location))
            }
        }
        
        appendInlineMatches(Self.italicRegex) { match, offset in
            .italic(
                markerOpen: match.range(at: 1).offsetBy(offset),
                textRange: match.range(at: 2).offsetBy(offset),
                markerClose: match.range(at: 3).offsetBy(offset))
        }

        appendInlineMatches(Self.boldRegex) { match, offset in
            .bold(
                markerOpen: match.range(at: 1).offsetBy(offset),
                textRange: match.range(at: 2).offsetBy(offset),
                markerClose: match.range(at: 3).offsetBy(offset)
            )
        }
        
        appendInlineMatches(Self.highlightRegex) { match, offset in
            .highlight(markerOpen: match.range(at: 1).offsetBy(offset),
                       textRange: match.range(at: 2).offsetBy(offset),
                       markerClose: match.range(at: 3).offsetBy(offset))
        }

        appendInlineMatches(Self.strikeRegex) { match, offset in
            .strike(
                markerOpen: match.range(at: 1).offsetBy(offset),
                textRange: match.range(at: 2).offsetBy(offset),
                markerClose: match.range(at: 3).offsetBy(offset)
            )
        }

        appendInlineMatches(Self.codeRegex) { match, offset in
            .code(
                markerOpen: match.range(at: 1).offsetBy(offset),
                textRange: match.range(at: 2).offsetBy(offset),
                markerClose: match.range(at: 3).offsetBy(offset)
            )
        }

        return result
    }
}

private extension NSRange {
    func offsetBy(_ offset: Int) -> NSRange {
        NSRange(location: location + offset, length: length)
    }
}
