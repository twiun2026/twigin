import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MarkdownEditorView: View {
    @Binding var text: String
    var theme: AppTheme
    var fontName: String = ""
    var lineSpacing: CGFloat = 0
    var focusRequest: UUID? = nil

    var body: some View {
        MarkdownTextView(
            text: $text,
            theme: theme,
            fontName: fontName,
            lineSpacing: lineSpacing,
            focusRequest: focusRequest
        )
    }
}

struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var theme: AppTheme
    var fontName: String = ""
    var lineSpacing: CGFloat = 0
    var focusRequest: UUID? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownNativeTextView(usingTextLayoutManager: true)
        textView.isRichText = false
        textView.usesAdaptiveColorMappingForDarkAppearance = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.delegate = context.coordinator

        // 显示层附件桥接：见 Coordinator 的 NSTextContentStorageDelegate 实现。
        if let contentStorage = textView.textLayoutManager?.textContentManager as? NSTextContentStorage {
            contentStorage.delegate = context.coordinator
        }
        textView.onCheckboxClick = { [weak coordinator = context.coordinator] index in
            coordinator?.handleCheckboxClick(at: index) ?? false
        }

        textView.backgroundColor = NSColor(theme.bgNoteEditor)
        textView.insertionPointColor = NSColor(theme.textMain)
    textView.selectedTextAttributes = selectedTextAttributes(for: theme)
        textView.font = resolvedFont()

        context.coordinator.bind(textView: textView)
        textView.textStorage?.delegate = context.coordinator

        context.coordinator.lastRenderedTheme = theme
        context.coordinator.lastRenderedFontName = fontName
        context.coordinator.lastRenderedLineSpacing = lineSpacing
        context.coordinator.setContent(text, on: textView)
        context.coordinator.consumeFocusRequestIfNeeded(focusRequest)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(theme.bgNoteEditor)
        scrollView.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        textView.autoresizingMask = [.width, .height]
        scrollView.documentView = textView

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self

        guard let textView = nsView.documentView as? MarkdownNativeTextView else { return }

        textView.insertionPointColor = NSColor(theme.textMain)
        textView.selectedTextAttributes = selectedTextAttributes(for: theme)

        let bgColor = NSColor(theme.bgNoteEditor)
        if textView.backgroundColor != bgColor {
            textView.backgroundColor = bgColor
            nsView.backgroundColor = bgColor
        }

        // suppressStringSync：本次 updateNSView 由自身编辑回写绑定触发，文本已同步，
        // 跳过 textView.string != text 的 O(N) 比较（避免每次按键在主线程扫全文）。
        if context.coordinator.suppressStringSync {
            context.coordinator.suppressStringSync = false
        } else if textView.string != text {
            context.coordinator.lastRenderedTheme = theme
            context.coordinator.lastRenderedFontName = fontName
            context.coordinator.lastRenderedLineSpacing = lineSpacing
            context.coordinator.setContent(text, on: textView)
            return
        }

        if context.coordinator.lastRenderedTheme != theme
           || context.coordinator.lastRenderedFontName != fontName
           || context.coordinator.lastRenderedLineSpacing != lineSpacing {
            // 仅在字体真正变化时重置 textView.font（该 setter 会覆盖全文 font 属性），
            // 随后 rerenderFull 逐段重新涂抹标题/粗体/斜体字体。
            if context.coordinator.lastRenderedFontName != fontName {
                textView.font = resolvedFont()
            }
            context.coordinator.lastRenderedTheme = theme
            context.coordinator.lastRenderedFontName = fontName
            context.coordinator.lastRenderedLineSpacing = lineSpacing
            context.coordinator.rerenderFull()
        }

        context.coordinator.consumeFocusRequestIfNeeded(focusRequest)
    }

    private func resolvedFont() -> NSFont {
        let size: CGFloat = 14
        let primaryFont: NSFont
        
        // 1. 设置主字体（通常在设置中用户选中的英文/等宽字体，即 fontName）
        if !fontName.isEmpty, let font = NSFont(name: fontName, size: size) {
            primaryFont = font
        } else {
            primaryFont = NSFont.systemFont(ofSize: size)
        }
        
        // 2. 指定中文默认字体的 Fallback 链（优先使用“苹方-简”）
        let chineseFontNames = ["PingFangSC-Regular", "Heiti SC", "Microsoft YaHei"]
        let fallbackDescriptors = chineseFontNames.compactMap { name -> NSFontDescriptor? in
            return NSFontDescriptor(name: name, size: size)
        }
        
        // 3. 将中文 fallback 链绑定到主字体描述符中
        let cascadedDescriptor = primaryFont.fontDescriptor.addingAttributes([
            .cascadeList: fallbackDescriptors
        ])
        
        return NSFont(descriptor: cascadedDescriptor, size: size) ?? primaryFont
    }

    private func selectedTextAttributes(for theme: AppTheme) -> [NSAttributedString.Key: Any] {
        [
            .backgroundColor: NSColor(theme.bgSelected)
        ]
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate, NSTextContentStorageDelegate {
        var parent: MarkdownTextView
        weak var textView: MarkdownNativeTextView?
        var lastRenderedTheme: AppTheme? = nil
        var lastRenderedFontName: String = ""
        var lastRenderedLineSpacing: CGFloat = 0
        private var lastConsumedFocusRequest: UUID?

        private let renderer = MarkdownRenderer()
        // 解析栈全部下沉到后台引擎，Coordinator（主线程）不再持有 parser / documentState。
        private let engine = MarkdownParsingEngine()

        // 主线程侧的极简状态：编辑序号 + 跳帧赶齐标记 + 绑定回写抑制标记。
        private var editSerial: UInt64 = 0
        private var needsFullCatchup = false
        private var isLoadingContent = false
        var suppressStringSync = false

        init(parent: MarkdownTextView) {
            self.parent = parent
        }

        func bind(textView: MarkdownNativeTextView) {
            self.textView = textView
        }

        func consumeFocusRequestIfNeeded(_ focusRequest: UUID?) {
            guard let focusRequest, focusRequest != lastConsumedFocusRequest else { return }
            lastConsumedFocusRequest = focusRequest
            focusEditorAtStart()
        }

        private func focusEditorAtStart() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let textView = self.textView else { return }
                let insertionPoint = NSRange(location: 0, length: 0)
                textView.setSelectedRange(insertionPoint)
                textView.scrollRangeToVisible(insertionPoint)
                textView.window?.makeFirstResponder(textView)
            }
        }

        // MARK: 内容装载（初次 / 笔记切换）——走全量解析，不经增量管线

        func setContent(_ text: String, on textView: MarkdownNativeTextView) {
            // 置位屏蔽：programmatic 的整篇 setString 会同步触发 willProcessEditing，
            // 此处跳过增量入队，改由 load() 做一次干净的全量解析 + 全量渲染（含缓存清理）。
            isLoadingContent = true
            textView.string = text
            isLoadingContent = false
            load(text: text)
        }

        private func load(text: String) {
            editSerial &+= 1                 // 作废所有在途的旧编辑结果
            needsFullCatchup = false
            let expected = editSerial
            engine.load(text: text) { [weak self] snapshot in
                DispatchQueue.main.async {
                    guard let self,
                          self.editSerial == expected,
                          let textView = self.textView,
                          let storage = textView.textStorage,
                          storage.length == snapshot.textLength else { return }
                    self.renderFull(blocks: snapshot.blocks)
                }
            }
        }

        // MARK: 主题/字体变化——仅整篇重渲染，不重解析

        func rerenderFull() {
            let expected = editSerial
            engine.snapshot { [weak self] snapshot in
                DispatchQueue.main.async {
                    guard let self,
                          self.editSerial == expected,
                          let textView = self.textView,
                          let storage = textView.textStorage,
                          storage.length == snapshot.textLength else { return }
                    self.renderFull(blocks: snapshot.blocks)
                }
            }
        }

        // MARK: NSTextStorageDelegate

        func textStorage(
            _ textStorage: NSTextStorage,
            willProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }
            guard !isLoadingContent else { return }   // 整篇装载由 load() 负责，跳过增量入队

            // 主线程仅做极简记录：读取“极小的插入子串”（O(编辑量)），绝不读取全量字符串。
            let inserted = textStorage.attributedSubstring(from: editedRange).string
            editSerial &+= 1
            let serial = editSerial

            // 重型解析投递到后台高优先级串行队列；主线程立即返回，不阻塞输入。
            engine.apply(editedRange: editedRange, delta: delta, inserted: inserted, serial: serial) { [weak self] result in
                DispatchQueue.main.async { self?.onEditResult(result) }
            }
        }

        // MARK: 后台解析结果回到主线程（coalescing + 最小化原子刷新）

        private func onEditResult(_ result: MarkdownEditResult) {
            guard let textView, let storage = textView.textStorage else { return }

            // 陈旧结果丢弃：有更新的编辑在途或文本长度已变，则本次结果作废，
            // 记账 needsFullCatchup，待最新一帧统一赶齐（避免漏渲染跳过的中间态）。
            let isLatest = (result.serial == editSerial) && (storage.length == result.textLength)
            guard isLatest else {
                needsFullCatchup = true
                return
            }

            // 回写 SwiftUI 绑定：全文已在后台物化，主线程仅做 O(1) 的 CoW 赋值。
            suppressStringSync = true
            parent.text = result.source

            guard !textView.hasMarkedText() else { return }   // IME 组字过程中不渲染

            if needsFullCatchup {
                needsFullCatchup = false
                catchUpFullRender(expectedSerial: result.serial)
            } else if let diff = result.blockDiff, !diff.isEmpty {
                renderIncremental(affectedRange: result.affectedRange, blockDiff: diff, allBlocks: result.allBlocks)
            }
        }

        // 跳帧后赶齐：让后台物化最新全量块，主线程一次性整篇刷新。
        private func catchUpFullRender(expectedSerial: UInt64) {
            engine.snapshot { [weak self] snapshot in
                DispatchQueue.main.async {
                    guard let self,
                          let textView = self.textView,
                          let storage = textView.textStorage,
                          self.editSerial == expectedSerial,
                          storage.length == snapshot.textLength else {
                        self?.needsFullCatchup = true
                        return
                    }
                    self.renderFull(blocks: snapshot.blocks)
                }
            }
        }

        // MARK: NSTextContentStorageDelegate

        // TextKit2 只为“附件字符 U+FFFC”预留版面。这里在“显示层”按正则识别 checklist 行，
        // 把标记首字符等长替换为携带图片附件的 U+FFFC，其余标记字符隐藏；后端 markdown
        // 源与偏移保持 1:1 不变。直接由“当前显示文本”驱动，不依赖后台异步渲染时序，
        // 也不使用 view provider（其 loadView 在委托替换段落里不会被可靠触发），
        // 改用图片附件由布局直接绘制，保证复选框稳定可见。
                static let checklistDisplayRegex = try! NSRegularExpression(pattern: "^(\\s*[-*+]\\s+\\[([ xX])\\]\\s*)(.*)$")
        static let imageDisplayRegex = try! NSRegularExpression(pattern: "^!\\[([^\\]]*)\\]\\(([^\\)]+)\\)$")

        private var checkboxAttachmentCache: [Bool: NSTextAttachment] = [:]
        private var checkboxThemeKey: AppTheme?
        private var checkboxFontKey: String = ""
        private func checkboxAttachment(isChecked: Bool, font: NSFont) -> NSTextAttachment {
            let fontKey = "\(font.fontName):\(font.pointSize)"
            if checkboxThemeKey != parent.theme || checkboxFontKey != fontKey {
                checkboxAttachmentCache.removeAll()
                checkboxThemeKey = parent.theme
                checkboxFontKey = fontKey
            }
            if let cached = checkboxAttachmentCache[isChecked] { return cached }
            let color = NSColor(isChecked ? parent.theme.textMain : parent.theme.textMuted)
            let attachment = NSTextAttachment()
            attachment.image = CheckboxImageFactory.make(isChecked: isChecked, color: color)
            let inset: CGFloat = 1
            let top = font.ascender - inset
            let bottom = font.descender + inset
            let side = max(1, top - bottom)
            attachment.bounds = CGRect(x: 0, y: bottom, width: side, height: side)
            checkboxAttachmentCache[isChecked] = attachment
            return attachment
        }
        func textContentStorage(_ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
            guard let backing = textContentStorage.textStorage else { return nil }
            let paragraph = backing.attributedSubstring(from: range)
            let ns = paragraph.string as NSString
            let fullRange = NSRange(location: 0, length: ns.length)

            if let match = Coordinator.checklistDisplayRegex.firstMatch(in: paragraph.string, range: fullRange) {
                let markerRange = match.range(at: 1)
                guard markerRange.length >= 1 else { return nil }
                let checkChar = ns.substring(with: match.range(at: 2))
                let isChecked = checkChar.lowercased() == "x"

                let display = NSMutableAttributedString(attributedString: paragraph)
                let bodyFont = (textView?.font) ?? NSFont.systemFont(ofSize: 14)
                let attachment = checkboxAttachment(isChecked: isChecked, font: bodyFont)

                let firstCharRange = NSRange(location: markerRange.location, length: 1)
                var firstAttrs = paragraph.attributes(at: firstCharRange.location, effectiveRange: nil)
                firstAttrs[.attachment] = attachment
                firstAttrs[.foregroundColor] = NSColor.clear
                firstAttrs[.font] = bodyFont
                display.replaceCharacters(in: firstCharRange, with: NSAttributedString(string: "\u{FFFC}", attributes: firstAttrs))

                if markerRange.length > 1 {
                    let hideRange = NSRange(location: markerRange.location + 1, length: markerRange.length - 1)
                    display.addAttributes([
                        .foregroundColor: NSColor.clear,
                        .font: NSFont.systemFont(ofSize: 1)
                    ], range: hideRange)
                }
                return NSTextParagraph(attributedString: display)
            }
            
            if let match = Coordinator.imageDisplayRegex.firstMatch(in: paragraph.string, range: fullRange) {
                let alt = ns.substring(with: match.range(at: 1))
                let path = ns.substring(with: match.range(at: 2))
                
                let display = NSMutableAttributedString(attributedString: paragraph)
                let bodyFont = (textView?.font) ?? NSFont.systemFont(ofSize: 14)
                
                let attachment = MarkdownImageAttachment(
                    sourcePath: path,
                    alt: alt,
                    lineRange: range,
                    onTap: { [weak self] p in
                        let fileURL = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
                        NSWorkspace.shared.open(fileURL)
                    }
                )
                
                // 关键点 5：把整个匹配到的 ![image](path) 范围彻底替换为单个 \u{FFFC} 占位符
                let matchRange = match.range(at: 0)
                
                let attachmentString = NSMutableAttributedString(attachment: attachment)
                // 赋予段落基本样式，防止行高测量失效
                attachmentString.addAttribute(.font, value: bodyFont, range: NSRange(location: 0, length: attachmentString.length))
                
                display.replaceCharacters(in: matchRange, with: attachmentString)
                
                return NSTextParagraph(attributedString: display)
            }

            return nil
        }

        // 点击命中：把点击处的字符下标映射到 markdown 源行，若为 checklist 且点在标记区内则切换。
        func handleCheckboxClick(at index: Int) -> Bool {
            guard let textView else { return false }
            let ns = textView.string as NSString
            guard ns.length > 0 else { return false }

            let probe = min(max(index, 0), ns.length - 1)
            let lineRange = ns.lineRange(for: NSRange(location: probe, length: 0))
            let lineText = ns.substring(with: lineRange)
            let lineNS = lineText as NSString

            guard let match = Coordinator.checklistDisplayRegex.firstMatch(
                in: lineText,
                range: NSRange(location: 0, length: lineNS.length)
            ) else { return false }

            let markerRange = match.range(at: 1)
            let markerEnd = lineRange.location + markerRange.length
            guard index >= lineRange.location, index <= markerEnd else { return false }

            let checkChar = lineNS.substring(with: match.range(at: 2))
            let newChecked = checkChar.lowercased() != "x"
            toggleChecklist(in: lineRange, to: newChecked)
            return true
        }

        // MARK: NSTextViewDelegate

        func textViewDidChangeSelection(_ notification: Notification) {}

        // MARK: 渲染

        private func renderIncremental(affectedRange: NSRange?, blockDiff: MarkdownBlockDiff, allBlocks: [MarkdownBlock]) {
            guard let textView else { return }
            renderer.bodyFontName = parent.fontName
            renderer.lineSpacingMultiplier = parent.lineSpacing
            let document = MarkdownDocument(source: "", affectedRange: affectedRange, blockDiff: blockDiff, revision: 0, explicitBlocks: allBlocks)
            renderer.render(makeContext(textView: textView, document: document))
        }

        private func renderFull(blocks: [MarkdownBlock]) {
            guard let textView else { return }
            renderer.bodyFontName = parent.fontName
            renderer.lineSpacingMultiplier = parent.lineSpacing
            let document = MarkdownDocument(source: "", affectedRange: nil, blockDiff: nil, revision: 0, explicitBlocks: blocks)
            renderer.render(makeContext(textView: textView, document: document))
            lastRenderedTheme = parent.theme
            lastRenderedFontName = parent.fontName
            lastRenderedLineSpacing = parent.lineSpacing
        }

        private func makeContext(textView: MarkdownNativeTextView, document: MarkdownDocument) -> MarkdownRenderContext {
            MarkdownRenderContext(
                textView: textView,
                theme: parent.theme,
                document: document,
                onToggleChecklist: { [weak self] range, isChecked in
                    self?.toggleChecklist(in: range, to: isChecked)
                },
                onTapImage: { path in
                    let fileURL = URL(fileURLWithPath: path)
                    NSWorkspace.shared.open(fileURL)
                }
            )
        }

        // MARK: Checklist toggle

        private func toggleChecklist(in lineRange: NSRange, to isChecked: Bool) {
            guard let textView else { return }
            let ns = textView.string as NSString
            guard NSMaxRange(lineRange) <= ns.length else { return }

            let line = ns.substring(with: lineRange)
            guard let regex = try? NSRegularExpression(pattern: "^\\s*[-*]\\s+\\[( |x|X)\\]", options: []),
                  let match = regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: (line as NSString).length)) else {
                return
            }

            let markerRange = match.range
            let replacement = isChecked ? "- [x]" : "- [ ]"
            let lineNS = line as NSString
            let updatedLine = lineNS.replacingCharacters(in: markerRange, with: replacement)

            textView.shouldChangeText(in: lineRange, replacementString: updatedLine)
            textView.textStorage?.replaceCharacters(in: lineRange, with: updatedLine)
            textView.didChangeText()
        }

        // MARK: Return key continuation

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  let selectedRange = textView.selectedRanges.first?.rangeValue else { return false }

            let nsString = textView.string as NSString
            let lineRange = nsString.lineRange(for: selectedRange)
            let lineText = nsString.substring(with: lineRange)
            // Checkbox
            if let checklistMatch = try? NSRegularExpression(pattern: "^(\\s*[-*+]\\s+\\[[ xX]\\]\\s*)(.*)$")
                    .firstMatch(in: lineText, range: NSRange(location: 0, length: (lineText as NSString).length)) {
                    
                    let indentAndPrefix = (lineText as NSString).substring(with: checklistMatch.range(at: 1))
                    let content = (lineText as NSString).substring(with: checklistMatch.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)

                    // 如果本行任务列表无内容，回车则取消任务列表格式
                    if content.isEmpty {
                        textView.shouldChangeText(in: lineRange, replacementString: "")
                        textView.textStorage?.replaceCharacters(in: lineRange, with: "")
                        textView.didChangeText()
                        return true
                    } else {
                        // 提取缩进并补全未勾选的 `- [ ] `
                        let leadingSpaces = indentAndPrefix.prefix { $0 == " " || $0 == "\t" }
                        let autoInsertText = "\n\(leadingSpaces)- [ ] "
                        if textView.shouldChangeText(in: selectedRange, replacementString: autoInsertText) {
                            textView.insertText(autoInsertText, replacementRange: selectedRange)
                            textView.didChangeText()
                            return true
                        }
                    }
                }
            // Unordered list
            // (必须要求 [-*+] 后面跟随至少一个空格或 Tab，符合 CommonMark 列表规范)
            if let bulletMatch = try? NSRegularExpression(pattern: "^(\\s*[-*+][ \t]+)(.*)$")
                .firstMatch(in: lineText, range: NSRange(location: 0, length: (lineText as NSString).length)) {

                let markerAndSpace = (lineText as NSString).substring(with: bulletMatch.range(at: 1))
                let content = (lineText as NSString).substring(with: bulletMatch.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)

                if content.isEmpty {
                    textView.shouldChangeText(in: lineRange, replacementString: "")
                    textView.textStorage?.replaceCharacters(in: lineRange, with: "")
                    textView.didChangeText()
                    return true
                } else {
                    // 提取前缀标记（如 "* " 或 "  - "）
                    let autoInsertText = "\n\(markerAndSpace)"
                    if textView.shouldChangeText(in: selectedRange, replacementString: autoInsertText) {
                        textView.insertText(autoInsertText, replacementRange: selectedRange)
                        textView.didChangeText()
                        return true
                    }
                }
            }
            // Ordered list
            if let orderedMatch = try? NSRegularExpression(pattern: "^(\\s*)(\\d+)\\.\\s*(.*)$")
                .firstMatch(in: lineText, range: NSRange(location: 0, length: (lineText as NSString).length)) {

                let spaces = (lineText as NSString).substring(with: orderedMatch.range(at: 1))
                let numStr = (lineText as NSString).substring(with: orderedMatch.range(at: 2))
                let content = (lineText as NSString).substring(with: orderedMatch.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)

                if content.isEmpty {
                    textView.shouldChangeText(in: lineRange, replacementString: "")
                    textView.textStorage?.replaceCharacters(in: lineRange, with: "")
                    textView.didChangeText()
                    return true
                } else if let currentNum = Int(numStr) {
                    let autoInsertText = "\n\(spaces)\(currentNum + 1). "
                    if textView.shouldChangeText(in: selectedRange, replacementString: autoInsertText) {
                        textView.insertText(autoInsertText, replacementRange: selectedRange)
                        textView.didChangeText()
                        return true
                    }
                }
            }
            // Blockquote
            if let blockquoteMatch = try? NSRegularExpression(pattern: "^(\\s*>)\\s*(.*)$")
                .firstMatch(in: lineText, range: NSRange(location: 0, length: (lineText as NSString).length)) {

                let marker = (lineText as NSString).substring(with: blockquoteMatch.range(at: 1))
                let content = (lineText as NSString).substring(with: blockquoteMatch.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)

                if content.isEmpty {
                    textView.shouldChangeText(in: lineRange, replacementString: "")
                    textView.textStorage?.replaceCharacters(in: lineRange, with: "")
                    textView.didChangeText()
                    return true
                } else {
                    let autoInsertText = "\n\(marker) "
                    if textView.shouldChangeText(in: selectedRange, replacementString: autoInsertText) {
                        textView.insertText(autoInsertText, replacementRange: selectedRange)
                        textView.didChangeText()
                        return true
                    }
                }
            }

            return false
        }
    }
}

final class MarkdownNativeTextView: NSTextView {
    // è¿”å›ž true è¡¨ç¤ºè¯¥æ¬¡ç‚¹å‡»å‘½ä¸­å¤é€‰æ¡†å¹¶å·²å¤„çï¼Œä¸å†èµ°é»˜è®¤å…‰æ ‡å®šä½ã€‚
    var onCheckboxClick: ((Int) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if let handler = onCheckboxClick, handler(index) {
            return
        }
        super.mouseDown(with: event)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pboard = sender.draggingPasteboard
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            var imageMarkdown = ""
            for url in urls {
                if isImageURL(url) {
                    imageMarkdown += "![image](\(url.path))\n"
                }
            }
            if !imageMarkdown.isEmpty {
                let point = convert(sender.draggingLocation, from: nil)
                let index = characterIndexForInsertion(at: point)
                if shouldChangeText(in: NSRange(location: index, length: 0), replacementString: imageMarkdown) {
                    textStorage?.replaceCharacters(in: NSRange(location: index, length: 0), with: imageMarkdown)
                    didChangeText()
                    print(" 拖拽生成 Markdown 图片语法:\n\(imageMarkdown)")
                }
                return true
            }
        }
        return super.performDragOperation(sender)
    }

    override func paste(_ sender: Any?) {
        let pboard = NSPasteboard.general
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            var imageMarkdown = ""
            for url in urls {
                if isImageURL(url) {
                    imageMarkdown += "![image](\(url.path))\n"
                }
            }
            if !imageMarkdown.isEmpty {
                let range = selectedRange()
                if shouldChangeText(in: range, replacementString: imageMarkdown) {
                    textStorage?.replaceCharacters(in: range, with: imageMarkdown)
                    didChangeText()
                }
                return
            }
        }
        super.paste(sender)
    }

    private func isImageURL(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
           let utType = UTType(type) {
            return utType.conforms(to: .image)
        }
        let ext = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext)
    }
}
