import SwiftUI

struct MarkdownEditorView: View {
    @Binding var text: String
    var theme: AppTheme
    var fontName: String = ""
    var lineSpacing: CGFloat = 0

    var body: some View {
        MarkdownTextView(text: $text, theme: theme, fontName: fontName, lineSpacing: lineSpacing)
    }
}

struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var theme: AppTheme
    var fontName: String = ""
    var lineSpacing: CGFloat = 0

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

        textView.backgroundColor = NSColor(theme.bgNoteEditor)
        textView.insertionPointColor = NSColor(theme.textMain)
        textView.font = resolvedFont()

        context.coordinator.bind(textView: textView)
        textView.textStorage?.delegate = context.coordinator

        context.coordinator.lastRenderedTheme = theme
        context.coordinator.lastRenderedFontName = fontName
        context.coordinator.lastRenderedLineSpacing = lineSpacing
        context.coordinator.setContent(text, on: textView)

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

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: MarkdownTextView
        weak var textView: MarkdownNativeTextView?
        var lastRenderedTheme: AppTheme? = nil
        var lastRenderedFontName: String = ""
        var lastRenderedLineSpacing: CGFloat = 0

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
                renderIncremental(affectedRange: result.affectedRange, blockDiff: diff)
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

        // MARK: NSTextViewDelegate

        func textViewDidChangeSelection(_ notification: Notification) {}

        // MARK: 渲染

        private func renderIncremental(affectedRange: NSRange?, blockDiff: MarkdownBlockDiff) {
            guard let textView else { return }
            renderer.bodyFontName = parent.fontName
            renderer.lineSpacingMultiplier = parent.lineSpacing
            let document = MarkdownDocument(source: "", affectedRange: affectedRange, blockDiff: blockDiff, revision: 0)
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

            // Unordered list
            if let bulletMatch = try? NSRegularExpression(pattern: "^(\\s*[-*+])\\s*(.*)$")
                .firstMatch(in: lineText, range: NSRange(location: 0, length: (lineText as NSString).length)) {

                let marker = (lineText as NSString).substring(with: bulletMatch.range(at: 1))
                let content = (lineText as NSString).substring(with: bulletMatch.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)

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

final class MarkdownNativeTextView: NSTextView {}
