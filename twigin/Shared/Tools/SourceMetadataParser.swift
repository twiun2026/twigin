import Foundation

// Parser that extracts metadata (title, publishDate, first URL, tags) from raw
// Markdown source and returns a SourceModel populated with parsed values.
// The parser is stateless and Sendable so it can be executed on background queues.
struct SourceMetadataParser: Sendable {

    init() {}

    func parse(_ markdown: String) -> SourceModel {
        // Work on a mutable copy to compute content after removing metadata ranges
        var occupied: [Range<String.Index>] = []

        // collect metadata
        let titleResult = extractTitle(from: markdown)
        if let tr = titleResult.range { occupied.append(tr) }

        let dateResult = extractPublishDate(from: markdown, excluding: occupied)
        if let dr = dateResult.range { occupied.append(dr) }

        let urlResult = extractFirstURL(from: markdown, excluding: occupied)
        if let ur = urlResult.range { occupied.append(ur) }

        let tagsResult = extractTags(from: markdown, excluding: occupied)
        // tagsResult.ranges may be multiple
        occupied.append(contentsOf: tagsResult.ranges)

        // Remove metadata ranges from the source string (from end to start)
        let content = makeContent(from: markdown, removing: occupied)

        // Build SourceModel
        // Use default initializer then set properties. The parser doesn't know noteId or embedding.
        let model = SourceModel()
        model.title = titleResult.title
        model.publishDate = dateResult.date ?? Date()
        model.url = urlResult.urlString
        model.content = content
        // Many entity types in the project also expose tags property — set if available
        model.tags = tagsResult.tags

        // noteId and embedding are left for the caller to fill in (noteId is app-specific)
        return model
    }

    // MARK: - Title
    private func extractTitle(from s: String) -> (title: String, range: Range<String.Index>?) {
        var foundTitle: String = "Untitled"
        var foundRange: Range<String.Index>? = nil

        s.enumerateSubstrings(in: s.startIndex..<s.endIndex, options: .byLines) { substring, substringRange, _, stop in
            guard let line = substring else { return }
            let range = substringRange
            // Trim leading whitespace to check for heading marker
            let leadingTrimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            guard leadingTrimmed.hasPrefix("#") else { return }
            // After '#' must be whitespace to qualify as an ATX level-1 heading
            let afterHash = leadingTrimmed.index(after: leadingTrimmed.startIndex)
            if afterHash < leadingTrimmed.endIndex {
                let ch = leadingTrimmed[afterHash]
                if ch.isWhitespace {
                    // This is a title line. Extract rest of the line after the '#'
                    let titleText = leadingTrimmed[afterHash...].trimmingCharacters(in: .whitespacesAndNewlines)
                    foundTitle = String(titleText)
                    // We will remove the whole source line (including following newline when building content)
                    foundRange = expandRangeToIncludeFollowingNewline(in: s, range: range)
                    stop = true
                }
            }
        }

        return (foundTitle, foundRange)
    }

    // MARK: - Publish Date
    private func extractPublishDate(from s: String, excluding occupied: [Range<String.Index>]) -> (date: Date?, range: Range<String.Index>?) {
        // 1) Try NSDataDetector for dates
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let ns = s as NSString
            let matches = detector.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
            for m in matches {
                guard m.resultType == .date, let dt = m.date else { continue }
                if let r = Range(m.range, in: s), !rangeOverlapsAny(r, occupied) {
                    return (dt, r)
                }
            }
        }

        // 2) Fallback to regex-based search for common date patterns and try parsing
        // Patterns (ordered): yyyy-MM-dd, yyyy/MM/dd, yyyy.MM.dd, MM/dd/yyyy, Month dd, yyyy
        let patterns = [
            "\\b\\d{4}[-\\/.]\\d{1,2}[-\\/.]\\d{1,2}\\b",
            "\\b\\d{1,2}[-\\/]\\d{1,2}[-\\/]\\d{4}\\b",
            "\\b(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)[ \\t]+\\d{1,2},[ \\t]*\\d{4}\\b"
        ]

        let formatters: [DateFormatter] = {
            var arr: [DateFormatter] = []
            let df1 = DateFormatter(); df1.locale = Locale(identifier: "en_US_POSIX"); df1.dateFormat = "yyyy-MM-dd"; arr.append(df1)
            let df2 = DateFormatter(); df2.locale = Locale(identifier: "en_US_POSIX"); df2.dateFormat = "yyyy/MM/dd"; arr.append(df2)
            let df3 = DateFormatter(); df3.locale = Locale(identifier: "en_US_POSIX"); df3.dateFormat = "yyyy.MM.dd"; arr.append(df3)
            let df4 = DateFormatter(); df4.locale = Locale(identifier: "en_US_POSIX"); df4.dateFormat = "MM/dd/yyyy"; arr.append(df4)
            let df5 = DateFormatter(); df5.locale = Locale(identifier: "en_US_POSIX"); df5.dateFormat = "MMMM d, yyyy"; arr.append(df5)
            let df6 = DateFormatter(); df6.locale = Locale(identifier: "en_US_POSIX"); df6.dateFormat = "MMM d, yyyy"; arr.append(df6)
            return arr
        }()

        for pat in patterns {
            if let rx = try? NSRegularExpression(pattern: pat, options: .caseInsensitive) {
                let ns = s as NSString
                let matches = rx.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
                for m in matches {
                    guard let r = Range(m.range, in: s), !rangeOverlapsAny(r, occupied) else { continue }
                    let token = String(s[r])
                    // Try parse with known formatters
                    for df in formatters {
                        if let d = df.date(from: token) {
                            return (d, r)
                        }
                    }
                    // try ISO8601
                    if let d = ISO8601DateFormatter().date(from: token) {
                        return (d, r)
                    }
                }
            }
        }

        return (nil, nil)
    }

    // MARK: - URL
    private func extractFirstURL(from s: String, excluding occupied: [Range<String.Index>]) -> (urlString: String?, range: Range<String.Index>?) {
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let ns = s as NSString
            let matches = detector.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
            for m in matches {
                guard m.resultType == .link else { continue }
                if let r = Range(m.range, in: s), !rangeOverlapsAny(r, occupied) {
                    let token = String(s[r])
                    return (token, r)
                }
            }
        }
        return (nil, nil)
    }

    // MARK: - Tags (first 10 source lines)
    private func extractTags(from s: String, excluding occupied: [Range<String.Index>]) -> (tags: [String], ranges: [Range<String.Index>]) {
        var outTags: [String] = []
        var outRanges: [Range<String.Index>] = []

        // enumerate up to first 10 source lines
        var lineIndex = 0
        s.enumerateSubstrings(in: s.startIndex..<s.endIndex, options: .byLines) { substring, substringRange, _, stop in
            guard lineIndex < 10 else { stop = true; return }
            lineIndex += 1
            guard let line = substring else { return }
            let range = substringRange
            // If this line was already used for title or other metadata, skip
            if rangeOverlapsAny(range, occupied) { return }

            // Split by whitespace and find tokens starting with '#' and next char is not whitespace
            let tokens = line.split(whereSeparator: { $0.isWhitespace })
            var tokenStart = range.lowerBound
            for token in tokens {
                let tokenStr = String(token)
                // find token's range within the line by searching from tokenStart
                if let foundRange = s.range(of: tokenStr, options: [], range: tokenStart..<range.upperBound) {
                    tokenStart = foundRange.upperBound
                    if tokenStr.hasPrefix("#") {
                        // Ensure it's a tag like "#word" (second char not whitespace)
                        if tokenStr.count >= 2 {
                            let second = tokenStr[tokenStr.index(tokenStr.startIndex, offsetBy: 1)]
                            if !second.isWhitespace {
                                // extract clean tag name (strip leading '#', trailing punctuation)
                                var tagName = String(tokenStr.dropFirst())
                                // trim trailing punctuation like ',', '.'
                                tagName = tagName.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:!()[]{}\"'"))
                                if !tagName.isEmpty {
                                    // Avoid extracting a tag that lies inside an occupied range
                                    if !rangeOverlapsAny(foundRange, occupied) {
                                        outTags.append(tagName)
                                        // expand range to include following newline if present
                                        let r = expandRangeToIncludeFollowingNewline(in: s, range: foundRange)
                                        outRanges.append(r)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        return (outTags, outRanges)
    }

    // MARK: - Content builder
    private func makeContent(from s: String, removing ranges: [Range<String.Index>]) -> String {
        guard !ranges.isEmpty else { return s }
        var result = s
        // sort by lowerBound descending to remove safely
        let sorted = ranges.sorted { $0.lowerBound > $1.lowerBound }
        for r in sorted {
            // ensure indices are still valid in result string
            if let lowered = tryRangeInCurrentString(r, original: s, current: result) {
                result.removeSubrange(lowered)
            }
        }
        // Trim leading/trailing newlines that may be left by removals but keep internal formatting
        // Do not aggressively trim other whitespace to preserve content exactness
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}\u{200B}"))
    }

    // Try to map a range that was computed on original string into the current string after prior removals.
    // Since we remove from end to start, ranges should remain valid; here we attempt to coerce to valid indices.
    private func tryRangeInCurrentString(_ r: Range<String.Index>, original: String, current: String) -> Range<String.Index>? {
        // If original and current are identical, return r directly
        if original == current { return r }
        // Otherwise, attempt to compute offsets
        let prefixUTF16Count = original.utf16.distance(from: original.startIndex, to: r.lowerBound)
        let lengthUTF16 = original.utf16.distance(from: r.lowerBound, to: r.upperBound)
        guard let lower = indexFromUTF16Offset(prefixUTF16Count, in: current), let upper = indexFromUTF16Offset(prefixUTF16Count + lengthUTF16, in: current) else {
            return nil
        }
        return lower..<upper
    }

    // Helpers
    private func rangeOverlapsAny(_ r: Range<String.Index>, _ others: [Range<String.Index>]) -> Bool {
        for o in others {
            if r.overlaps(o) { return true }
        }
        return false
    }

    private func expandRangeToIncludeFollowingNewline(in s: String, range: Range<String.Index>) -> Range<String.Index> {
        var end = range.upperBound
        if end < s.endIndex {
            let ch = s[end]
            if ch == "\r" {
                let next = s.index(after: end)
                if next < s.endIndex && s[next] == "\n" { end = s.index(after: next) } else { end = next }
            } else if ch == "\n" {
                end = s.index(after: end)
            }
        }
        return range.lowerBound..<end
    }

    private func indexFromUTF16Offset(_ offset: Int, in s: String) -> String.Index? {
        guard offset >= 0 else { return nil }
        return offset == 0 ? s.startIndex : s.utf16.index(s.utf16.startIndex, offsetBy: offset, limitedBy: s.utf16.endIndex).flatMap { String.Index($0, within: s) }
    }
}
