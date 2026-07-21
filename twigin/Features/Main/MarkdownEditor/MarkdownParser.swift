import Foundation
import Markdown

nonisolated final class MarkdownParser {
    private struct SourceLine {
        let index: Int
        let range: NSRange     // 行内容范围（不含换行符）
        let text: String
        let fullLength: Int    // 推进长度（含换行符），用于树的前缀和
    }

    private struct ReuseFingerprint: Hashable {
        let textHash: UInt64
        let stateHash: UInt64
        let incomingState: ParserState
        let outgoingState: ParserState
    }

    private struct ParsedLineWindow {
        var lowerBound: Int
        var upperBound: Int

        mutating func include(_ lineIndex: Int) {
            lowerBound = min(lowerBound, lineIndex)
            upperBound = max(upperBound, lineIndex)
        }

        var range: Range<Int> {
            lowerBound..<(upperBound + 1)
        }
    }

    private let headingRegex = try! NSRegularExpression(pattern: "^(\\s{0,3})(#{1,6})(?:\\s+|$)(.*)$")
    private let checklistRegex = try! NSRegularExpression(pattern: "^(\\s*[-*+]\\s+\\[([ xX])\\]\\s*)(.*)$")
    private let unorderedListRegex = try! NSRegularExpression(pattern: "^(\\s*[-*+]\\s+)(.*)$")
    private let orderedListRegex = try! NSRegularExpression(pattern: "^(\\s*)(\\d+)\\.\\s+(.*)$")
    private let blockquoteRegex = try! NSRegularExpression(pattern: "^(\\s*>\\s?)(.*)$")
    private let footnoteRegex = try! NSRegularExpression(pattern: "^(\\[\\^([^\\]]+)\\]:)\\s*(.*)$")
    private let imageRegex = try! NSRegularExpression(pattern: "^!\\[([^\\]]*)\\]\\(([^\\)]+)\\)$")
    private let fenceRegex = try! NSRegularExpression(pattern: "^(\\s*)(```|~~~).*$")

    private let codeInlineRegex = try! NSRegularExpression(pattern: "(`+)([^`\\n]+?)(\\1)")
    private let highlightRegex = try! NSRegularExpression(pattern: "(==)(?=\\S)(.+?)(?<=\\S)(==)")
    private let strikeRegex = try! NSRegularExpression(pattern: "(~~)(?=\\S)(.+?)(?<=\\S)(~~)")
    private let boldAsteriskRegex = try! NSRegularExpression(pattern: "(\\*\\*)(?=\\S)(.+?)(?<=\\S)(\\*\\*)")
    private let boldUnderscoreRegex = try! NSRegularExpression(pattern: "(__)(?=\\S)(.+?)(?<=\\S)(__)")
    private let italicAsteriskRegex = try! NSRegularExpression(pattern: "(?<!\\*)(\\*)(?=\\S)(.+?)(?<=\\S)(\\*)(?!\\*)")
    private let italicUnderscoreRegex = try! NSRegularExpression(pattern: "(?<!_)(_)(?=\\S)(.+?)(?<=\\S)(_)(?!_)")
    private let footnoteDefinitionRegex = try! NSRegularExpression(pattern: "^(\\s*\\[\\^([^\\]]+)\\]:)\\s*(.*)$")
    private let footnoteReferenceRegex = try! NSRegularExpression(pattern: "\\[\\^([^\\]]+)\\]")

    func reparseAll(source: String, state: MarkdownDocumentState) -> MarkdownDocument {
        reconcile(source: source, editedRange: NSRange(location: 0, length: state.totalLength), changeInLength: (source as NSString).length - state.totalLength, state: state, forceFull: true)
    }

    func update(source: String, editedRange: NSRange, changeInLength delta: Int, state: MarkdownDocumentState) -> MarkdownDocument {
        reconcile(source: source, editedRange: editedRange, changeInLength: delta, state: state, forceFull: state.lineStore.isEmpty)
    }

    func syncTextOnly(source: String, state: MarkdownDocumentState) {
        let lines = buildLines(from: source)
        let relative = lines.map { line -> LineState in
            LineState(
                lineIndex: line.index,
                lineRange: NSRange(location: 0, length: line.range.length),
                fullLength: line.fullLength,
                textHash: hashText(line.text),
                stateHash: 0,
                incomingState: .normal,
                outgoingState: .normal,
                blocks: [],
                containsUnresolvedSyntax: true
            )
        }
        state.lineStore = LineStore(relativeLines: relative)
        state.totalLength = (source as NSString).length
    }

    private func reconcile(
        source: String,
        editedRange: NSRange,
        changeInLength delta: Int,
        state: MarkdownDocumentState,
        forceFull: Bool
    ) -> MarkdownDocument {
        let ns = source as NSString
        let totalLength = ns.length
        let oldStore = state.lineStore
        let oldCount = oldStore.count
        let startLine = forceFull ? 0 : min(oldStore.lineIndex(forOffset: editedRange.location), max(oldCount - 1, 0))
        // 前缀 [0,startLine) 不变 → startLine 的字节起点新旧一致，直接取自旧树。
        let startByte = (forceFull || startLine == 0 || oldStore.isEmpty) ? 0 : oldStore.base(ofLine: startLine)

        // 新文档行数：仅从 startByte 起做一次“无分配”的行终止符扫描（O(尾部)）。
        // 锚点的 remaining 校验必须基于真实文本行数——不能由复用点反推，否则失去正确性。
        let newLineCount = startLine + countLines(from: startByte, in: ns)
        let lineCountDelta = newLineCount - oldCount

        // 旧行绝对几何访问器：等价于原 shiftOldLines（startLine 起整体右移 delta），
        // 但按需单点计算 O(log N)，不再 O(N) 复制整条尾部。
        func shiftedOldAbsolute(_ k: Int) -> LineState? {
            guard k >= 0, k < oldCount else { return nil }
            let extra = (k >= startLine) ? delta : 0
            return oldStore.absoluteLine(at: k).shifted(by: extra)
        }

        // reuse 指纹与绝对位置无关（textHash/stateHash/incoming/outgoing），直接用相对旧行构建，无需 shift。
        let reuseMap = buildReuseMap(oldStore: oldStore, startingAt: startLine)

        // 懒惰增量分行：仅从 startByte 起按需切分 SourceLine（O(1)/行 + 极少子串分配），
        // 不再对全文构建 SourceLine 数组，彻底消除原 buildLines 的 O(N) 分配开销。
        var splitCursor = startByte
        var splitIndex = startLine
        func nextSourceLine() -> SourceLine? {
            guard splitCursor < ns.length else { return nil }
            let raw = ns.lineRange(for: NSRange(location: splitCursor, length: 0))
            let trimmed = trimmingNewline(raw, in: ns)
            let line = SourceLine(index: splitIndex, range: trimmed, text: ns.substring(with: trimmed), fullLength: raw.length)
            splitCursor = NSMaxRange(raw)
            splitIndex += 1
            return line
        }

        var window: [LineState] = []                     // 新解析窗口（绝对几何）
        var reparsedRange: NSRange?
        var parsedWindow: ParsedLineWindow?
        var suffixReuseOldIndex: Int?                    // 命中锚点后，复用旧后缀的起始旧行下标

        let prefixOutgoing: ParserState = (startLine > 0 && startLine - 1 < oldCount)
            ? oldStore.line(at: startLine - 1).outgoingState
            : .normal

        var current = nextSourceLine()                   // startLine 行（保留一行前瞻用于锚点的“下一行”哈希校验）
        while let sourceLine = current {
            let cursor = sourceLine.index
            let incomingState = window.last?.outgoingState ?? prefixOutgoing
            let parsedLine = parseLine(sourceLine, incomingState: incomingState)
            window.append(parsedLine)
            reparsedRange = union(reparsedRange, parsedLine.lineRange)
            if var w = parsedWindow {
                w.include(cursor)
                parsedWindow = w
            } else {
                parsedWindow = ParsedLineWindow(lowerBound: cursor, upperBound: cursor)
            }

            let lookahead = nextSourceLine()             // cursor+1 行（可能为 nil）

            // 提前终止一：Stable Propagation Anchor（逻辑不变，比较仍为绝对几何）。
            if let anchor = stablePropagationAnchor(
                for: parsedLine,
                newLineIndex: cursor,
                nextLineText: lookahead?.text,
                lineCountDelta: lineCountDelta,
                oldStore: oldStore,
                oldCount: oldCount,
                shiftedOldAbsolute: shiftedOldAbsolute
            ) {
                suffixReuseOldIndex = anchor + 1
                break
            }

            // 提前终止二：Reusable Suffix Anchor（逻辑不变）。
            if let candidate = reusableSuffixAnchor(
                for: parsedLine,
                newLineIndex: cursor,
                nextLineText: lookahead?.text,
                lineCountDelta: lineCountDelta,
                oldStore: oldStore,
                oldCount: oldCount,
                reuseMap: reuseMap,
                minimumOldIndex: startLine,
                shiftedOldAbsolute: shiftedOldAbsolute
            ) {
                suffixReuseOldIndex = candidate + 1
                break
            }

            current = lookahead
        }

        // === O(log N) 结构拼接：共享前缀子树 + 新窗口子树 + 共享后缀子树 ===
        // 因叶子几何为相对坐标，后缀子树无需任何 shift 即可直接复用，绝对偏移由前缀和自动重算。
        let prefixTree = forceFull ? LineStore.empty : oldStore.prefix(startLine)
        let windowTree = LineStore(relativeLines: window.map { $0.madeRelative() })
        let suffixTree: LineStore
        if let s = suffixReuseOldIndex, s < oldCount {
            suffixTree = oldStore.suffix(from: s)
        } else {
            suffixTree = .empty
        }
        state.lineStore = prefixTree.concat(windowTree).concat(suffixTree)
        state.totalLength = totalLength
        state.revision += 1

        // 仅对改动窗口构建 blockDiff（按同下标比较，语义与原实现一致）。
        let blockDiff: MarkdownBlockDiff?
        if let parsedWindow {
            var operations: [MarkdownBlockDiff.Operation] = []
            for i in parsedWindow.range {
                let oldBlocks = shiftedOldAbsolute(i)?.blocks ?? []
                let windowOffset = i - startLine
                let newBlocks = (windowOffset >= 0 && windowOffset < window.count) ? window[windowOffset].blocks : []
                operations.append(contentsOf: diffBlocks(old: oldBlocks, new: newBlocks))
            }
            blockDiff = operations.isEmpty ? nil : MarkdownBlockDiff(operations: operations)
        } else {
            blockDiff = nil
        }

        return state.makeDocument(source: source, affectedRange: reparsedRange, blockDiff: blockDiff)
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
            lines.append(SourceLine(index: index, range: trimmedRange, text: ns.substring(with: trimmedRange), fullLength: rawRange.length))
            cursor = NSMaxRange(rawRange)
            index += 1
        }

        return lines
    }

    // 从 startByte 起统计行数（与 buildLines 同语义：以 NSString.lineRange 断行），
    // 只推进游标、不分配子串，故是廉价的 O(尾部) 扫描。
    private func countLines(from startByte: Int, in ns: NSString) -> Int {
        guard startByte < ns.length else { return 0 }
        var cursor = startByte
        var count = 0
        while cursor < ns.length {
            let raw = ns.lineRange(for: NSRange(location: cursor, length: 0))
            count += 1
            cursor = NSMaxRange(raw)
        }
        return count
    }

    private func buildReuseMap(oldStore: LineStore, startingAt startLine: Int) -> [ReuseFingerprint: [Int]] {
        var lookup: [ReuseFingerprint: [Int]] = [:]
        oldStore.forEachRelative(from: startLine) { index, line in
            guard !line.containsUnresolvedSyntax else { return }
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

    // 锚点改为“流式”接口：不再依赖全量 allNewLines 数组。
    // - remaining 校验用 lineCountDelta（= 新总行数 - 旧总行数）等价改写：
    //     stable:  remainingNew == remainingOld  ⟺  lineCountDelta == 0
    //     reuse:   remainingNew == remainingOld  ⟺  lineCountDelta == newLineIndex - candidate
    // - “下一行文本哈希”校验用一行前瞻 nextLineText（nil 表示已是最后一行）。
    private func reusableSuffixAnchor(
        for line: LineState,
        newLineIndex: Int,
        nextLineText: String?,
        lineCountDelta: Int,
        oldStore: LineStore,
        oldCount: Int,
        reuseMap: [ReuseFingerprint: [Int]],
        minimumOldIndex: Int,
        shiftedOldAbsolute: (Int) -> LineState?
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
            guard candidate < oldCount, let candidateAbsolute = shiftedOldAbsolute(candidate) else { continue }
            guard candidateAbsolute.lineRange == line.lineRange else { continue }

            guard lineCountDelta == newLineIndex - candidate else { continue }

            if let nextLineText, candidate + 1 < oldCount {
                guard hashText(nextLineText) == oldStore.line(at: candidate + 1).textHash else { continue }
            }

            return candidate
        }

        return nil
    }

    private func stablePropagationAnchor(
        for line: LineState,
        newLineIndex: Int,
        nextLineText: String?,
        lineCountDelta: Int,
        oldStore: LineStore,
        oldCount: Int,
        shiftedOldAbsolute: (Int) -> LineState?
    ) -> Int? {
        guard newLineIndex < oldCount, let previousLine = shiftedOldAbsolute(newLineIndex) else { return nil }
        guard previousLine.lineRange == line.lineRange else { return nil }
        guard line.isPropagationStable(comparedTo: previousLine) else { return nil }

        guard lineCountDelta == 0 else { return nil }

        if let nextLineText, newLineIndex + 1 < oldCount {
            guard hashText(nextLineText) == oldStore.line(at: newLineIndex + 1).textHash else { return nil }
        }

        return newLineIndex
    }

    private func diffBlocks(old: [MarkdownBlock], new: [MarkdownBlock]) -> [MarkdownBlockDiff.Operation] {
        if old.isEmpty {
            return new.map { .insert($0) }
        }

        if new.isEmpty {
            return old.map { .delete($0) }
        }

        var operations: [MarkdownBlockDiff.Operation] = []
        let pairedCount = min(old.count, new.count)

        for index in 0..<pairedCount {
            let oldBlock = old[index]
            let newBlock = new[index]
            if oldBlock != newBlock {
                operations.append(.modify(old: oldBlock, new: newBlock))
            }
        }

        if old.count > pairedCount {
            operations.append(contentsOf: old[pairedCount...].map { .delete($0) })
        }

        if new.count > pairedCount {
            operations.append(contentsOf: new[pairedCount...].map { .insert($0) })
        }

        return operations
    }

    private func parseLine(_ line: SourceLine, incomingState: ParserState) -> LineState {
        let textHash = hashText(line.text)
        let nsText = line.text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let trimmed = line.text.trimmingCharacters(in: .whitespaces)

        if incomingState.isInCodeFence {
            // 栏内行与闭栏行均属容器体（.containerBody）：与开栏行连成多行容器。
            let closesFence = fenceRegex.firstMatch(in: line.text, range: fullRange) != nil
            let outgoingState = closesFence ? incomingState.settingCodeFence(nil) : incomingState
            let block = makeBlock(kind: .codeBlock, line: line, markerRange: nil, contentRange: line.range, inlines: [], containerRole: .containerBody)
            return makeLineState(
                line: line,
                incomingState: incomingState,
                outgoingState: outgoingState,
                blocks: [block],
                textHash: textHash,
                containsUnresolvedSyntax: false
            )
        }

        if trimmed.isEmpty {
            return makeLineState(
                line: line,
                incomingState: incomingState,
                outgoingState: incomingState
                    .settingCodeFence(nil)
                    .settingQuoteDepth(0)
                    .settingListStack([]),
                blocks: [],
                textHash: textHash,
                containsUnresolvedSyntax: false
            )
        }

        if fenceRegex.firstMatch(in: line.text, range: fullRange) != nil {
            // 开栏行：多行代码容器的起始（.containerStart），后续 containers 聚合以此切分。
            let fenceState = ParserState.CodeFenceState(fenceToken: fenceToken(in: line.text))
            let block = makeBlock(kind: .codeBlock, line: line, markerRange: nil, contentRange: line.range, inlines: [], containerRole: .containerStart)
            return makeLineState(
                line: line,
                incomingState: incomingState,
                outgoingState: incomingState.settingCodeFence(fenceState),
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
                outgoingState: incomingState.settingQuoteDepth(0).settingListStack([]),
                blocks: [block],
                textHash: textHash,
                containsUnresolvedSyntax: false
            )
        }
        if let match = footnoteRegex.firstMatch(in: line.text, range: fullRange) {
            let markerLocal = match.range(at: 1) // "[^1]:"
            let labelLocal = match.range(at: 2)  // "1"
            let contentLocal = match.range(at: 3)// "解释内容"
            
            let label = nsText.substring(with: labelLocal)
            let contentRange = absoluteRange(contentLocal, base: line.range.location)
            let contentText = nsText.substring(with: contentLocal)
            
            let block = makeBlock(
                kind: .footnote(label: label),
                line: line,
                markerRange: absoluteRange(markerLocal, base: line.range.location),
                contentRange: contentRange,
                // 脚注定义后面通常也可以包含粗体等普通行内样式
                inlines: parseInlines(in: contentText, baseOffset: contentRange.location)
            )
            
            return makeLineState(
                line: line,
                incomingState: incomingState,
                // 解析到脚注定义后，更新状态机的 footnote 状态（这里设置为激活，或者保持常规）
                outgoingState: incomingState.settingQuoteDepth(0).settingListStack([]),
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
                outgoingState: incomingState.settingQuoteDepth(leadingQuoteDepth(in: line.text)),
                blocks: [block],
                textHash: textHash,
                containsUnresolvedSyntax: containsUnresolvedInlineSyntax(in: contentText)
            )
        }
        if let match = checklistRegex.firstMatch(in: line.text, range: fullRange) {
            let markerLocal = match.range(at: 1)
            let markerValue = match.range(at: 2)
            let contentLocal = match.range(at: 3)
            
            let markerChar = (markerValue.location != NSNotFound && markerValue.length > 0)
                ? nsText.substring(with: markerValue)
                : " "
            let checklistMarker: ChecklistMarker = markerChar.lowercased() == "x" ? .checked : .unchecked

            let contentRange: NSRange
            let contentText: String
            if contentLocal.location != NSNotFound && contentLocal.length > 0 {
                contentRange = absoluteRange(contentLocal, base: line.range.location)
                contentText = nsText.substring(with: contentLocal)
            } else {
                let absoluteMarkerEnd = line.range.location + markerLocal.length
                contentRange = NSRange(location: absoluteMarkerEnd, length: 0)
                contentText = ""
            }
            
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
                outgoingState: incomingState.settingListStack([
                    ParserState.ListContext(kind: .checklist, indent: leadingIndent(in: line.text))
                ]),
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
                outgoingState: incomingState.settingListStack([
                    ParserState.ListContext(kind: .ordered, indent: leading.length)
                ]),
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
                outgoingState: incomingState.settingListStack([
                    ParserState.ListContext(kind: .bullet, indent: leadingIndent(in: line.text))
                ]),
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
                outgoingState: incomingState.settingQuoteDepth(0).settingListStack([]),
                blocks: [block],
                textHash: textHash,
                containsUnresolvedSyntax: false
            )
        }
        
        if let indent = incomingState.listIndent,
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
                outgoingState: incomingState,
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
            outgoingState: incomingState.settingQuoteDepth(0).settingListStack([]),
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
            fullLength: line.fullLength,
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
        inlines: [MarkdownInline],
        containerRole: ContainerRole = .none
    ) -> MarkdownBlock {
        // containerRole 纳入 id 哈希：区分文本相同的开栏/闭栏行（均为 ``` + .codeBlock），
        // 消除旧实现中开栏与闭栏 block.id 碰撞的问题。
        let identity = MarkdownStableHash.hash([
            kind.stableKey,
            "role:\(containerRole)",
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
            inlines: inlines,
            containerRole: containerRole
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
        
        let nsText = text as NSString
            let range = NSRange(location: 0, length: nsText.length)
            for match in footnoteReferenceRegex.matches(in: text, range: range) {
                // match.range(at: 0) 是完整的 "[^1]"
                let fullInlineRange = absoluteRange(match.range(at: 0), base: baseOffset)
                
                // 为了配合未来的“移入显示/移出隐藏”功能，我们将：
                // 开头和结尾包裹符号作为 markerOpen/Close，中间的数字作为 textRange
                // 这样当你隐藏标记时，可以只隐藏 "[^" 和 "]"，把数字保留并上标显示。
                let openRange = NSRange(location: fullInlineRange.location, length: 2) // "[^"
                let bodyRange = NSRange(location: fullInlineRange.location + 2, length: fullInlineRange.length - 3) // "1"
                let closeRange = NSRange(location: fullInlineRange.upperBound - 1, length: 1) // "]"
                
                inlines.append(MarkdownInline(
                    kind: .footnote,
                    markerOpen: openRange,
                    textRange: bodyRange,
                    markerClose: closeRange
                ))
            }

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

    private func leadingQuoteDepth(in text: String) -> Int {
        let characters = Array(text)
        var cursor = 0
        var depth = 0

        while cursor < characters.count {
            while cursor < characters.count, characters[cursor] == " " {
                cursor += 1
            }

            guard cursor < characters.count, characters[cursor] == ">" else {
                break
            }

            depth += 1
            cursor += 1

            if cursor < characters.count, characters[cursor] == " " {
                cursor += 1
            }
        }

        return depth
    }

    private func fenceToken(in text: String) -> String {
        if text.contains("~~~") {
            return "~~~"
        }
        return "```"
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

private nonisolated extension Int {
    mutating func toggleBit() {
        self = self == 0 ? 1 : 0
    }
}
