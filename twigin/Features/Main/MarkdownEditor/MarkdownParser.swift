import Foundation
import Markdown

final class MarkdownParser {
    private struct SourceLine {
        let index: Int
        let range: NSRange
        let text: String
    }

    private struct ReuseFingerprint: Hashable {
        let textHash: UInt64
        let stateHash: UInt64
        let incomingState: ParserState
        let outgoingState: ParserState
    }

    private let headingRegex = try! NSRegularExpression(pattern: "^(\\s{0,3})(#{1,6})(?:\\s+|$)(.*)$")
    private let checklistRegex = try! NSRegularExpression(pattern: "^(\\s*[-*+]\\s+\\[( |x|X)\\]\\s*)(.*)$")
    private let unorderedListRegex = try! NSRegularExpression(pattern: "^(\\s*[-*+]\\s+)(.*)$")
    private let orderedListRegex = try! NSRegularExpression(pattern: "^(\\s*)(\\d+)\\.\\s+(.*)$")
    private let blockquoteRegex = try! NSRegularExpression(pattern: "^(\\s*>\\s?)(.*)$")
    private let imageRegex = try! NSRegularExpression(pattern: "^!\\[([^\\]]*)\\]\\(([^\\)]+)\\)$")
    private let fenceRegex = try! NSRegularExpression(pattern: "^(\\s*)(```|~~~).*$")

    private let codeInlineRegex = try! NSRegularExpression(pattern: "(`+)([^`\\n]+?)(\\1)")
    private let highlightRegex = try! NSRegularExpression(pattern: "(==)(?=\\S)(.+?)(?<=\\S)(==)")
    private let strikeRegex = try! NSRegularExpression(pattern: "(~~)(?=\\S)(.+?)(?<=\\S)(~~)")
    private let boldAsteriskRegex = try! NSRegularExpression(pattern: "(\\*\\*)(?=\\S)(.+?)(?<=\\S)(\\*\\*)")
    private let boldUnderscoreRegex = try! NSRegularExpression(pattern: "(__)(?=\\S)(.+?)(?<=\\S)(__)")
    private let italicAsteriskRegex = try! NSRegularExpression(pattern: "(?<!\\*)(\\*)(?=\\S)(.+?)(?<=\\S)(\\*)(?!\\*)")
    private let italicUnderscoreRegex = try! NSRegularExpression(pattern: "(?<!_)(_)(?=\\S)(.+?)(?<=\\S)(_)(?!_)")

    func reparseAll(source: String, state: MarkdownDocumentState) -> MarkdownDocument {
        reconcile(source: source, editedRange: NSRange(location: 0, length: state.totalLength), changeInLength: (source as NSString).length - state.totalLength, state: state, forceFull: true)
    }

    func update(source: String, editedRange: NSRange, changeInLength delta: Int, state: MarkdownDocumentState) -> MarkdownDocument {
        reconcile(source: source, editedRange: editedRange, changeInLength: delta, state: state, forceFull: state.lines.isEmpty)
    }

    func syncTextOnly(source: String, state: MarkdownDocumentState) {
        let lines = buildLines(from: source)
        state.lines = lines.enumerated().map { index, line in
            LineState(
                lineIndex: index,
                lineRange: line.range,
                textHash: hashText(line.text),
                stateHash: 0,
                incomingState: .normal,
                outgoingState: .normal,
                blocks: [],
                containsUnresolvedSyntax: true
            )
        }
        state.totalLength = (source as NSString).length
    }

    private func reconcile(
        source: String,
        editedRange: NSRange,
        changeInLength delta: Int,
        state: MarkdownDocumentState,
        forceFull: Bool
    ) -> MarkdownDocument {
        let newLines = buildLines(from: source)
        let oldLines = state.lines
        let startLine = forceFull ? 0 : lineIndex(for: editedRange.location, in: oldLines)
        let shiftedOldLines = shiftOldLines(oldLines, from: startLine, delta: delta)
        let reuseMap = buildReuseMap(from: shiftedOldLines, startingAt: startLine)

        var reconciled: [LineState] = forceFull ? [] : Array(oldLines.prefix(startLine))
        var reparsedRange: NSRange?
        var lineIndexCursor = startLine
        var shortCircuited = false

        while lineIndexCursor < newLines.count {
            let incomingState = reconciled.last?.outgoingState ?? .normal
            let parsedLine = parseLine(newLines[lineIndexCursor], incomingState: incomingState)
            reconciled.append(parsedLine)
            reparsedRange = union(reparsedRange, parsedLine.lineRange)

            if let suffixAnchor = reusableSuffixAnchor(
                for: parsedLine,
                newLineIndex: lineIndexCursor,
                allNewLines: newLines,
                shiftedOldLines: shiftedOldLines,
                reuseMap: reuseMap,
                minimumOldIndex: startLine
            ) {
                let suffixStart = suffixAnchor + 1
                if suffixStart < shiftedOldLines.count {
                    for oldLine in shiftedOldLines[suffixStart...] {
                        reconciled.append(oldLine.shifted(by: 0, lineIndex: reconciled.count))
                    }
                }
                shortCircuited = true
                break
            }

            lineIndexCursor += 1
        }

        if !shortCircuited, reconciled.count < newLines.count {
            let remainingStart = reconciled.count
            for index in remainingStart..<newLines.count {
                let incomingState = reconciled.last?.outgoingState ?? .normal
                let parsedLine = parseLine(newLines[index], incomingState: incomingState)
                reconciled.append(parsedLine)
                reparsedRange = union(reparsedRange, parsedLine.lineRange)
            }
        }

        if reconciled.count != newLines.count {
            reconciled = reconciled.prefix(newLines.count).enumerated().map { index, line in
                line.shifted(by: 0, lineIndex: index)
            }
        }

        state.lines = reconciled.enumerated().map { index, line in
            line.shifted(by: 0, lineIndex: index)
        }
        state.totalLength = (source as NSString).length
        state.revision += 1

        return state.makeDocument(source: source, affectedRange: reparsedRange)
    }

    private func buildLines(from source: String) -> [SourceLine] {
        let ns = source as NSString
        guard ns.length > 0 else { return [] }

        var lines: [SourceLine] = []
        var cursor = 0
        var index = 0

        while cursor < ns.length {
            let rawRange = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let trimmedRange = trimmingNewline(rawRange, in: ns)
            lines.append(SourceLine(index: index, range: trimmedRange, text: ns.substring(with: trimmedRange)))
            cursor = NSMaxRange(rawRange)
            index += 1
        }

        return lines
    }

    private func lineIndex(for location: Int, in lines: [LineState]) -> Int {
        guard !lines.isEmpty else { return 0 }

        var lower = 0
        var upper = lines.count - 1

        while lower <= upper {
            let mid = (lower + upper) / 2
            let line = lines[mid].lineRange
            let end = NSMaxRange(line)

            if location < line.location {
                upper = mid - 1
            } else if location > end {
                lower = mid + 1
            } else {
                return mid
            }
        }

        return min(max(lower, 0), lines.count - 1)
    }

    private func shiftOldLines(_ lines: [LineState], from startLine: Int, delta: Int) -> [LineState] {
        guard delta != 0, startLine < lines.count else { return lines }

        var shifted = lines
        for index in startLine..<shifted.count {
            shifted[index] = shifted[index].shifted(by: delta)
        }
        return shifted
    }

    private func buildReuseMap(from lines: [LineState], startingAt startLine: Int) -> [ReuseFingerprint: [Int]] {
        var lookup: [ReuseFingerprint: [Int]] = [:]
        guard startLine < lines.count else { return lookup }

        for index in startLine..<lines.count {
            let line = lines[index]
            guard !line.containsUnresolvedSyntax else { continue }
            let fingerprint = ReuseFingerprint(
                textHash: line.textHash,
                stateHash: line.stateHash,
                incomingState: line.incomingState,
                outgoingState: line.outgoingState
            )
            lookup[fingerprint, default: []].append(index)
        }

        return lookup
    }

    private func reusableSuffixAnchor(
        for line: LineState,
        newLineIndex: Int,
        allNewLines: [SourceLine],
        shiftedOldLines: [LineState],
        reuseMap: [ReuseFingerprint: [Int]],
        minimumOldIndex: Int
    ) -> Int? {
        guard !line.containsUnresolvedSyntax else { return nil }

        let fingerprint = ReuseFingerprint(
            textHash: line.textHash,
            stateHash: line.stateHash,
            incomingState: line.incomingState,
            outgoingState: line.outgoingState
        )

        guard let candidates = reuseMap[fingerprint] else { return nil }

        for candidate in candidates where candidate >= minimumOldIndex {
            guard candidate < shiftedOldLines.count else { continue }
            guard shiftedOldLines[candidate].lineRange == line.lineRange else { continue }

            let remainingNew = allNewLines.count - (newLineIndex + 1)
            let remainingOld = shiftedOldLines.count - (candidate + 1)
            guard remainingNew == remainingOld else { continue }

            if newLineIndex + 1 < allNewLines.count, candidate + 1 < shiftedOldLines.count {
                let nextTextHash = hashText(allNewLines[newLineIndex + 1].text)
                guard nextTextHash == shiftedOldLines[candidate + 1].textHash else { continue }
            }

            return candidate
        }

        return nil
    }

    private func parseLine(_ line: SourceLine, incomingState: ParserState) -> LineState {
        let textHash = hashText(line.text)
        let nsText = line.text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let trimmed = line.text.trimmingCharacters(in: .whitespaces)

        if case .inCodeBlock = incomingState {
            let closesFence = fenceRegex.firstMatch(in: line.text, range: fullRange) != nil
            let block = makeBlock(kind: .codeBlock, line: line, markerRange: nil, contentRange: line.range, inlines: [])
            return makeLineState(
                line: line,
                incomingState: incomingState,
                outgoingState: closesFence ? .normal : .inCodeBlock,
                blocks: [block],
                textHash: textHash,
                containsUnresolvedSyntax: false
            )
        }

        if trimmed.isEmpty {
            return makeLineState(
                line: line,
                incomingState: incomingState,
                outgoingState: .normal,
                blocks: [],
                textHash: textHash,
                containsUnresolvedSyntax: false
            )
        }

        if fenceRegex.firstMatch(in: line.text, range: fullRange) != nil {
            let block = makeBlock(kind: .codeBlock, line: line, markerRange: nil, contentRange: line.range, inlines: [])
            return makeLineState(
                line: line,
                incomingState: incomingState,
                outgoingState: .inCodeBlock,
                blocks: [block],
                textHash: textHash,
                containsUnresolvedSyntax: false
            )
        }

        if let match = headingRegex.firstMatch(in: line.text, range: fullRange) {
            let markerLocal = match.range(at: 2)
            let contentLocal = match.range(at: 3)
            let block = makeBlock(
                kind: .heading(level: markerLocal.length),
                line: line,
                markerRange: absoluteRange(markerLocal, base: line.range.location),
                contentRange: contentLocal.length > 0 ? absoluteRange(contentLocal, base: line.range.location) : nil,
                inlines: []
            )
            return makeLineState(
                line: line,
                incomingState: incomingState,
                outgoingState: .normal,
                blocks: [block],
                textHash: textHash,
                containsUnresolvedSyntax: false
            )
        }

        if let match = checklistRegex.firstMatch(in: line.text, range: fullRange) {
            let markerLocal = match.range(at: 1)
            let markerValue = match.range(at: 2)
            let contentLocal = match.range(at: 3)
            let markerChar = markerValue.location != NSNotFound ? nsText.substring(with: markerValue) : " "
            let checklistMarker: ChecklistMarker = markerChar.lowercased() == "x" ? .checked : .unchecked
            let contentRange = absoluteRange(contentLocal, base: line.range.location)
            let contentText = nsText.substring(with: contentLocal)
            let block = makeBlock(
                kind: .checklist(marker: checklistMarker),
                line: line,
                markerRange: absoluteRange(markerLocal, base: line.range.location),
                contentRange: contentRange,
                inlines: parseInlines(in: contentText, baseOffset: contentRange.location)
            )
            return makeLineState(
                line: line,
                incomingState: incomingState,
                outgoingState: .inList(indent: leadingIndent(in: line.text)),
                blocks: [block],
                textHash: textHash,
                containsUnresolvedSyntax: containsUnresolvedInlineSyntax(in: contentText)
            )
        }

        if let match = blockquoteRegex.firstMatch(in: line.text, range: fullRange) {
            let markerLocal = match.range(at: 1)
            let contentLocal = match.range(at: 2)
            let contentRange = absoluteRange(contentLocal, base: line.range.location)
            let contentText = nsText.substring(with: contentLocal)
            let block = makeBlock(
                kind: .blockquote,
                line: line,
                markerRange: absoluteRange(markerLocal, base: line.range.location),
                contentRange: contentRange,
                inlines: parseInlines(in: contentText, baseOffset: contentRange.location)
            )
            return makeLineState(
                line: line,
                incomingState: incomingState,
                outgoingState: .inBlockquote,
                blocks: [block],
                textHash: textHash,
                containsUnresolvedSyntax: containsUnresolvedInlineSyntax(in: contentText)
            )
        }

        if let match = orderedListRegex.firstMatch(in: line.text, range: fullRange) {
            let leading = match.range(at: 1)
            let digits = match.range(at: 2)
            let contentLocal = match.range(at: 3)
            let index = Int(nsText.substring(with: digits)) ?? 1
            let markerLocal = NSRange(location: 0, length: contentLocal.location)
            let contentRange = absoluteRange(contentLocal, base: line.range.location)
            let contentText = nsText.substring(with: contentLocal)
            let block = makeBlock(
                kind: .orderedList(index: index),
                line: line,
                markerRange: absoluteRange(markerLocal, base: line.range.location),
                contentRange: contentRange,
                inlines: parseInlines(in: contentText, baseOffset: contentRange.location)
            )
            return makeLineState(
                line: line,
                incomingState: incomingState,
                outgoingState: .inList(indent: leading.length),
                blocks: [block],
                textHash: textHash,
                containsUnresolvedSyntax: containsUnresolvedInlineSyntax(in: contentText)
            )
        }

        if let match = unorderedListRegex.firstMatch(in: line.text, range: fullRange) {
            let markerLocal = match.range(at: 1)
            let contentLocal = match.range(at: 2)
            let contentRange = absoluteRange(contentLocal, base: line.range.location)
            let contentText = nsText.substring(with: contentLocal)
            let block = makeBlock(
                kind: .bulletList,
                line: line,
                markerRange: absoluteRange(markerLocal, base: line.range.location),
                contentRange: contentRange,
                inlines: parseInlines(in: contentText, baseOffset: contentRange.location)
            )
            return makeLineState(
                line: line,
                incomingState: incomingState,
                outgoingState: .inList(indent: leadingIndent(in: line.text)),
                blocks: [block],
                textHash: textHash,
                containsUnresolvedSyntax: containsUnresolvedInlineSyntax(in: contentText)
            )
        }

        if let match = imageRegex.firstMatch(in: line.text, range: fullRange) {
            let alt = nsText.substring(with: match.range(at: 1))
            let path = nsText.substring(with: match.range(at: 2))
            let block = makeBlock(
                kind: .image(alt: alt, path: path),
                line: line,
                markerRange: nil,
                contentRange: line.range,
                inlines: []
            )
            return makeLineState(
                line: line,
                incomingState: incomingState,
                outgoingState: .normal,
                blocks: [block],
                textHash: textHash,
                containsUnresolvedSyntax: false
            )
        }

        if case let .inList(indent) = incomingState,
           leadingIndent(in: line.text) > indent {
            let block = makeBlock(
                kind: .paragraph,
                line: line,
                markerRange: nil,
                contentRange: line.range,
                inlines: parseInlines(in: line.text, baseOffset: line.range.location)
            )
            return makeLineState(
                line: line,
                incomingState: incomingState,
                outgoingState: .inList(indent: indent),
                blocks: [block],
                textHash: textHash,
                containsUnresolvedSyntax: containsUnresolvedInlineSyntax(in: line.text)
            )
        }

        let block = makeBlock(
            kind: .paragraph,
            line: line,
            markerRange: nil,
            contentRange: line.range,
            inlines: parseInlines(in: line.text, baseOffset: line.range.location)
        )
        return makeLineState(
            line: line,
            incomingState: incomingState,
            outgoingState: .normal,
            blocks: [block],
            textHash: textHash,
            containsUnresolvedSyntax: containsUnresolvedInlineSyntax(in: line.text)
        )
    }

    private func makeLineState(
        line: SourceLine,
        incomingState: ParserState,
        outgoingState: ParserState,
        blocks: [MarkdownBlock],
        textHash: UInt64,
        containsUnresolvedSyntax: Bool
    ) -> LineState {
        let stateHash = MarkdownStableHash.hash(
            [incomingState.stableKey, outgoingState.stableKey, String(textHash), containsUnresolvedSyntax ? "1" : "0"]
                + blocks.map { String($0.id) }
        )

        return LineState(
            lineIndex: line.index,
            lineRange: line.range,
            textHash: textHash,
            stateHash: stateHash,
            incomingState: incomingState,
            outgoingState: outgoingState,
            blocks: blocks,
            containsUnresolvedSyntax: containsUnresolvedSyntax
        )
    }

    private func makeBlock(
        kind: MarkdownBlock.Kind,
        line: SourceLine,
        markerRange: NSRange?,
        contentRange: NSRange?,
        inlines: [MarkdownInline]
    ) -> MarkdownBlock {
        let identity = MarkdownStableHash.hash([
            kind.stableKey,
            line.text,
            markerRange.map { relativeDescription(for: $0, base: line.range.location) } ?? "-",
            contentRange.map { relativeDescription(for: $0, base: line.range.location) } ?? "-"
        ] + inlines.map { inlineIdentity($0, base: line.range.location) })

        return MarkdownBlock(
            id: identity,
            kind: kind,
            markerRange: markerRange,
            contentRange: contentRange,
            lineRange: line.range,
            inlines: inlines
        )
    }

    private func parseInlines(in text: String, baseOffset: Int) -> [MarkdownInline] {
        var inlines: [MarkdownInline] = []
        appendMatches(from: codeInlineRegex, in: text, baseOffset: baseOffset, kind: .code, into: &inlines)
        appendMatches(from: highlightRegex, in: text, baseOffset: baseOffset, kind: .highlight, into: &inlines)
        appendMatches(from: strikeRegex, in: text, baseOffset: baseOffset, kind: .strike, into: &inlines)
        appendMatches(from: boldAsteriskRegex, in: text, baseOffset: baseOffset, kind: .bold, into: &inlines)
        appendMatches(from: boldUnderscoreRegex, in: text, baseOffset: baseOffset, kind: .bold, into: &inlines)
        appendMatches(from: italicAsteriskRegex, in: text, baseOffset: baseOffset, kind: .italic, into: &inlines)
        appendMatches(from: italicUnderscoreRegex, in: text, baseOffset: baseOffset, kind: .italic, into: &inlines)

        return inlines.sorted {
            if $0.textRange.location == $1.textRange.location {
                return $0.textRange.length < $1.textRange.length
            }
            return $0.textRange.location < $1.textRange.location
        }
    }

    private func appendMatches(
        from regex: NSRegularExpression,
        in text: String,
        baseOffset: Int,
        kind: MarkdownInline.Kind,
        into inlines: inout [MarkdownInline]
    ) {
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        for match in regex.matches(in: text, range: range) {
            guard match.numberOfRanges >= 4 else { continue }
            let open = absoluteRange(match.range(at: 1), base: baseOffset)
            let body = absoluteRange(match.range(at: 2), base: baseOffset)
            let close = absoluteRange(match.range(at: 3), base: baseOffset)
            inlines.append(MarkdownInline(kind: kind, markerOpen: open, textRange: body, markerClose: close))
        }
    }

    private func containsUnresolvedInlineSyntax(in text: String) -> Bool {
        var scalarIndex = text.startIndex
        var singleAsterisk = 0
        var singleUnderscore = 0
        var doubleAsterisk = 0
        var doubleUnderscore = 0
        var doubleTilde = 0
        var doubleEquals = 0
        var backticks = 0

        while scalarIndex < text.endIndex {
            let current = text[scalarIndex]
            let nextIndex = text.index(after: scalarIndex)

            if current == "\\" {
                scalarIndex = nextIndex < text.endIndex ? text.index(after: nextIndex) : nextIndex
                continue
            }

            if nextIndex < text.endIndex {
                let pair = String(text[scalarIndex...nextIndex])
                switch pair {
                case "**":
                    doubleAsterisk.toggleBit()
                    scalarIndex = text.index(after: nextIndex)
                    continue
                case "__":
                    doubleUnderscore.toggleBit()
                    scalarIndex = text.index(after: nextIndex)
                    continue
                case "~~":
                    doubleTilde.toggleBit()
                    scalarIndex = text.index(after: nextIndex)
                    continue
                case "==":
                    doubleEquals.toggleBit()
                    scalarIndex = text.index(after: nextIndex)
                    continue
                default:
                    break
                }
            }

            switch current {
            case "*":
                singleAsterisk.toggleBit()
            case "_":
                singleUnderscore.toggleBit()
            case "`":
                backticks.toggleBit()
            default:
                break
            }

            scalarIndex = nextIndex
        }

        return singleAsterisk != 0 || singleUnderscore != 0 || doubleAsterisk != 0 || doubleUnderscore != 0 || doubleTilde != 0 || doubleEquals != 0 || backticks != 0
    }

    private func absoluteRange(_ range: NSRange, base: Int) -> NSRange {
        NSRange(location: base + range.location, length: range.length)
    }

    private func relativeDescription(for range: NSRange, base: Int) -> String {
        "\(range.location - base):\(range.length)"
    }

    private func inlineIdentity(_ inline: MarkdownInline, base: Int) -> String {
        [
            inline.kind.rawValue,
            relativeDescription(for: inline.markerOpen, base: base),
            relativeDescription(for: inline.textRange, base: base),
            relativeDescription(for: inline.markerClose, base: base)
        ].joined(separator: "|")
    }

    private func hashText(_ text: String) -> UInt64 {
        MarkdownStableHash.hash(text)
    }

    private func leadingIndent(in text: String) -> Int {
        text.prefix { $0 == " " || $0 == "\t" }.count
    }

    private func trimmingNewline(_ range: NSRange, in ns: NSString) -> NSRange {
        var end = NSMaxRange(range)
        guard end > range.location, end <= ns.length else { return range }

        if ns.character(at: end - 1) == 10 {
            end -= 1
            if end > range.location, ns.character(at: end - 1) == 13 {
                end -= 1
            }
        }

        return NSRange(location: range.location, length: max(0, end - range.location))
    }

    private func union(_ lhs: NSRange?, _ rhs: NSRange) -> NSRange {
        lhs.map { NSUnionRange($0, rhs) } ?? rhs
    }
}

private extension Int {
    mutating func toggleBit() {
        self = self == 0 ? 1 : 0
    }
}
