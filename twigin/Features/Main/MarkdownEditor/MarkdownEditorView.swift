import AppKit
import FoundationModels
import SwiftUI
import UniformTypeIdentifiers

struct MarkdownEditorView: View {
    @Binding var text: String
    var theme: AppTheme
    var fontName: String = ""
    var fontSize: CGFloat = 14
    var lineSpacing: CGFloat = 0
    var focusRequest: UUID? = nil

    var body: some View {
        MarkdownTextView(
            text: $text,
            theme: theme,
            fontName: fontName,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            focusRequest: focusRequest
        )
    }
}

struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var theme: AppTheme
    var fontName: String = ""
    var fontSize: CGFloat = 14
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
        textView.blockquoteBackgroundColor = NSColor(theme.bgCitation)
        textView.blockquoteBarColor = NSColor(theme.textCitation)
        textView.insertionPointColor = NSColor(theme.textMain)
        textView.selectedTextAttributes = selectedTextAttributes(for: theme)
        textView.font = Self.resolvedFont(for: fontName, size: fontSize)

        context.coordinator.bind(textView: textView)
        textView.textStorage?.delegate = context.coordinator

        context.coordinator.lastRenderedTheme = theme
        context.coordinator.lastRenderedFontName = fontName
        context.coordinator.lastRenderedFontSize = fontSize
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
            context.coordinator.lastRenderedFontSize = fontSize
            context.coordinator.lastRenderedLineSpacing = lineSpacing
            context.coordinator.setContent(text, on: textView)
            return
        }

        if context.coordinator.lastRenderedTheme != theme
           || context.coordinator.lastRenderedFontName != fontName
           || context.coordinator.lastRenderedFontSize != fontSize
           || context.coordinator.lastRenderedLineSpacing != lineSpacing {
            // 仅在字体真正变化时重置 textView.font（该 setter 会覆盖全文 font 属性），
            // 随后 rerenderFull 逐段重新涂抹标题/粗体/斜体字体。
            if context.coordinator.lastRenderedFontName != fontName
               || context.coordinator.lastRenderedFontSize != fontSize {
                textView.font = Self.resolvedFont(for: fontName, size: fontSize)
            }
            context.coordinator.lastRenderedTheme = theme
            context.coordinator.lastRenderedFontName = fontName
            context.coordinator.lastRenderedFontSize = fontSize
            context.coordinator.lastRenderedLineSpacing = lineSpacing
            textView.blockquoteBackgroundColor = NSColor(theme.bgCitation)
            textView.blockquoteBarColor = NSColor(theme.textCitation)
            context.coordinator.rerenderFull()
        }

        context.coordinator.consumeFocusRequestIfNeeded(focusRequest)
    }

    nonisolated static func resolvedFont(for fontName: String, size: CGFloat = 14) -> NSFont {
        let primaryFont: NSFont

        // 1. 设置主字体（通常在设置中用户选中的英文/等宽字体，即 fontName）
        if !fontName.isEmpty, let font = NSFont(name: fontName, size: size) {
            primaryFont = font
        } else {
            primaryFont = NSFont.systemFont(ofSize: size)
        }

        // 2. 指定中文默认字体的 Fallback 链（优先使用"苹方-简"）
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

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate, NSTextContentStorageDelegate, @unchecked Sendable {
        var parent: MarkdownTextView
        weak var textView: MarkdownNativeTextView?
        var lastRenderedTheme: AppTheme? = nil
        var lastRenderedFontName: String = ""
        var lastRenderedFontSize: CGFloat = 14
        var lastRenderedLineSpacing: CGFloat = 0
        private var lastConsumedFocusRequest: UUID?

        private let renderer: MarkdownRenderer
        private let engine = MarkdownParsingEngine()
        private var editSerial: UInt64 = 0// 主线程侧的极简状态：编辑序号 + 跳帧赶齐标记 + 绑定回写抑制标记。
        private var needsFullCatchup = false
        private var isLoadingContent = false
        var suppressStringSync = false
        
        private let aiParser = AICommandParser()
        private let aiAppleService = AIService(provider: AppleFoundationProvider())
        private let aiQWenService = AIService(provider: QWenProvider())
        private var aiTask: Task<Void, Never>?
        var contextMenuAITask: Task<Void, Never>?
        
        // 在 Coordinator 内部新增/更新状态变量
        private var lastSelectedRange: NSRange? = nil
        private var cachedBlocks: [MarkdownBlock] = [] // 缓存最新的物化块，供光标移动时瞬时查找
        
        init(parent: MarkdownTextView) {
            self.parent = parent
            self.renderer = MarkdownRenderer()
            super.init()
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

        @MainActor func setContent(_ text: String, on textView: MarkdownNativeTextView) {
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

            // 主线程仅做极简记录：读取"极小的插入子串"（O(编辑量)），绝不读取全量字符串。
            let inserted = textStorage.attributedSubstring(from: editedRange).string
            editSerial &+= 1
            let serial = editSerial

            // 重型解析投递到后台高优先级串行队列；主线程立即返回，不阻塞输入。
            engine.apply(editedRange: editedRange, delta: delta, inserted: inserted, serial: serial) { [weak self] result in
                DispatchQueue.main.async { self?.onEditResult(result) }
            }
        }

        // MARK: 后台解析结果回到主线程（coalescing + 最小化原子刷新）@MainActor 

        @MainActor private func onEditResult(_ result: MarkdownEditResult) {
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

        // TextKit2 只为"附件字符 U+FFFC"预留版面。这里在"显示层"按正则识别 checklist 行，
        // 把标记首字符等长替换为携带图片附件的 U+FFFC，其余标记字符隐藏；后端 markdown
        // 源与偏移保持 1:1 不变。直接由"当前显示文本"驱动，不依赖后台异步渲染时序，
        // 也不使用 view provider（其 loadView 在委托替换段落里不会被可靠触发），
        // 改用图片附件由布局直接绘制，保证复选框稳定可见。

        var checkboxAttachmentCache: [Bool: NSTextAttachment] = [:]
        var checkboxThemeKey: AppTheme?
        var checkboxFontKey: String = ""
        
        func textContentStorage(_ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
            guard let backing = textContentStorage.textStorage else { return nil }
            let paragraph = backing.attributedSubstring(from: range)
            let ns = paragraph.string as NSString

            if let checklistParagraph = processChecklistParagraph(paragraph, range: range, nsString: ns) {
                return checklistParagraph
            }
            if let imageParagraph = processImageParagraph(in: paragraph, range: range, nsString: ns) {
                return imageParagraph
            }

            return NSTextParagraph(attributedString: paragraph)
        }

        // MARK: NSTextViewDelegate

        @MainActor func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = textView, let storage = textView.textStorage else { return }
            let currentSelectedRange = textView.selectedRange()
            
            // 1. 如果光标选区完全未变，直接丢弃
            if lastSelectedRange == currentSelectedRange { return }
            
            let oldRange = lastSelectedRange
            lastSelectedRange = currentSelectedRange
            
            let storageLength = storage.length
            guard storageLength > 0 else { return }
            
            // 对当前选区进行边界防护，防止按 Backspace 删除字符时 Range 超过最新文本长度
            let safeLocation = min(max(0, currentSelectedRange.location), storageLength)
            let safeLength = min(currentSelectedRange.length, storageLength - safeLocation)
            let safeSelectedRange = NSRange(location: safeLocation, length: safeLength)
            
            let nsString = storage.string as NSString
            guard NSMaxRange(safeSelectedRange) <= nsString.length else { return }
            
            // 2. 仅计算安全的旧光标行与新光标行
            let newFullLineRange = nsString.lineRange(for: safeSelectedRange)
            
            var oldFullLineRange: NSRange? = nil
            if let old = oldRange {
                let safeOldLoc = min(max(0, old.location), storageLength)
                let safeOldLen = min(old.length, storageLength - safeOldLoc)
                let safeOldRange = NSRange(location: safeOldLoc, length: safeOldLen)
                if NSMaxRange(safeOldRange) <= nsString.length {
                    oldFullLineRange = nsString.lineRange(for: safeOldRange)
                }
            }
            
            // 3. 如果旧行和新行是同一行，判断该行内是否存在 Markdown 标签，无标签则跳过重绘
            if let oldLine = oldFullLineRange, oldLine == newFullLineRange {
                let lineBlocks = cachedBlocks.filter { $0.lineRange.overlaps(newFullLineRange) }
                let hasInlines = lineBlocks.contains { !$0.inlines.isEmpty || $0.markerRange != nil }
                if !hasInlines { return }
            }
            
            // 4. 合并受影响的局部 Ranges
            var affectedRanges: [NSRange] = [newFullLineRange]
            if let oldLine = oldFullLineRange, oldLine != newFullLineRange {
                affectedRanges.append(oldLine)
            }
            
            // 5. 执行安全局域增量重绘
            renderSelectionChange(affectedRanges: affectedRanges)
        }
        
        /// 专门用于处理"光标移动"的纯局域增量重涂方法
        @MainActor private func renderSelectionChange(affectedRanges: [NSRange]) {
            guard let textView = textView, let storage = textView.textStorage else { return }
            guard !cachedBlocks.isEmpty else { return }
            
            renderer.bodyFontName = parent.fontName
            renderer.baseFontSize = parent.fontSize
            renderer.lineSpacingMultiplier = parent.lineSpacing

            let context = makeContext(textView: textView, document: MarkdownDocument(source: "", revision: 0))
            
            // 从缓存的 AST Blocks 中提取受到影响的 Blocks
            let affectedBlocks = cachedBlocks.filter { block in
                affectedRanges.contains { $0.overlaps(block.lineRange) }
            }
            
            // 利用现有架构中的清空与重新涂抹逻辑
            storage.beginEditing()
            for range in affectedRanges {
                // 清理受影响范围属性
                for key in [.foregroundColor, .font, .strikethroughStyle, .backgroundColor, .isBlockquote] as [NSAttributedString.Key] {                    storage.removeAttribute(key, range: range)
                }
                // 涂抹基础属性
                storage.addAttributes([
                    .foregroundColor: NSColor(parent.theme.textMain),
                    .font: renderer.bodyFont()
                ], range: range)
            }
            
            // 仅重新 apply 受到影响的 1~2 个 Block
            for block in affectedBlocks {
                renderer.applyBlock(block, to: storage, theme: parent.theme, context: context)
            }
            storage.endEditing()
            
            // 仅使受影响的 fragment 几何失效（触发 TextKit2 局部绘制）
            renderer.invalidateLayout(in: textView, affectedRanges: affectedRanges)
        }

        // MARK: 渲染

        @MainActor private func renderIncremental(affectedRange: NSRange?, blockDiff: MarkdownBlockDiff, allBlocks: [MarkdownBlock]) {
            guard let textView else { return }
            self.cachedBlocks = allBlocks
            renderer.bodyFontName = parent.fontName
            renderer.baseFontSize = parent.fontSize
            renderer.lineSpacingMultiplier = parent.lineSpacing
            let document = MarkdownDocument(source: "", affectedRange: affectedRange, blockDiff: blockDiff, revision: 0, explicitBlocks: allBlocks)
            renderer.render(makeContext(textView: textView, document: document))
        }

        @MainActor private func renderFull(blocks: [MarkdownBlock]) {
            guard let textView else { return }
            self.cachedBlocks = blocks
            renderer.bodyFontName = parent.fontName
            renderer.baseFontSize = parent.fontSize
            renderer.lineSpacingMultiplier = parent.lineSpacing
            let document = MarkdownDocument(source: "", affectedRange: nil, blockDiff: nil, revision: 0, explicitBlocks: blocks)
            renderer.render(makeContext(textView: textView, document: document))
            lastRenderedTheme = parent.theme
            lastRenderedFontName = parent.fontName
            lastRenderedFontSize = parent.fontSize
            lastRenderedLineSpacing = parent.lineSpacing
        }

        @MainActor private func makeContext(textView: MarkdownNativeTextView, document: MarkdownDocument) -> MarkdownRenderContext {
            MarkdownRenderContext(
                textView: textView,
                theme: parent.theme,
                document: document,
                selectedRange: textView.selectedRange(), // 实时获取 TextView 的选中/光标位置
                onToggleChecklist: { [weak self] range, isChecked in
                    self?.toggleChecklist(in: range, to: isChecked)
                },
                onTapImage: { path in
                    let fileURL = URL(fileURLWithPath: path)
                    NSWorkspace.shared.open(fileURL)
                }
            )
        }

        // MARK: Return key continuation

        @MainActor func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            //拦截 Backspace (deleteBackward:) 键
            if commandSelector == #selector(NSResponder.deleteBackward(_:)),
               let selectedRange = textView.selectedRanges.first?.rangeValue,
               selectedRange.length == 0 { // 仅在光标点选状态（非选中一段文本）下处理
                
                let nsString = textView.string as NSString
                let lineRange = nsString.lineRange(for: selectedRange)
                let lineText = nsString.substring(with: lineRange)
                
                // 判断当前行是否刚好是仅包含引用符号（例如 "> "、">" 或带缩进的 ">"）的行
                let trimmedLine = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedLine == ">" || (trimmedLine.isEmpty && lineText.contains(">")) {
                    // 检查光标位置：只有当光标已经退到了 > 后面或行首时才触发整行删除
                    if textView.shouldChangeText(in: lineRange, replacementString: "") {
                        // 1. 计算【上一行末尾】的准确位置（前移 1 个字符跨过上一行的 \n）
                        let previousLineEndLocation = max(0, lineRange.location - 1)
                        // 2. 从 textStorage 中彻底删除整行（包含换行符）
                        textView.textStorage?.replaceCharacters(in: lineRange, with: "")
                        // 3. 通知系统文本已变更，触发 AST 解析器更新
                        textView.didChangeText()
                        // 4. 在下一个 RunLoop 主线程队列中设置光标，防止被渲染器的刷新覆盖
                        DispatchQueue.main.async { [weak textView] in
                            guard let textView = textView else { return }
                            let safeLocation = min(previousLineEndLocation, (textView.string as NSString).length)
                            let newRange = NSRange(location: safeLocation, length: 0)
                            textView.setSelectedRange(newRange)
                            textView.scrollRangeToVisible(newRange)
                        }
                        
                        return true // 返回 true 表示已完全接管该 Backspace 事件
                    }
                }
                // 场景 B：> 已被删掉，当前行仅剩换行符，但依然残留着 Blockquote 的段落样式 (textBlocks)
                if trimmedLine.isEmpty, let storage = textView.textStorage, lineRange.location < storage.length {
                    var hasTextBlock = false
                    storage.enumerateAttribute(.paragraphStyle, in: lineRange, options: []) { value, _, stop in
                        if let style = value as? NSParagraphStyle, !style.textBlocks.isEmpty {
                            hasTextBlock = true
                            stop.pointee = true
                        }
                    }
                    
                    if hasTextBlock {
                        // 1. 清除当前行（包括 \n）上的所有 paragraphStyle，恢复为默认样式
                        storage.removeAttribute(.paragraphStyle, range: lineRange)
                        storage.addAttribute(.paragraphStyle, value: NSParagraphStyle.default, range: lineRange)
                        
                        // 2. 触发 AST 更新与 Viewport 布局重刷
                        textView.didChangeText()
                        
                        // 3. 异步重刷新 Fragment，确保 Blockquote 灰色背景瞬间消失
                        DispatchQueue.main.async { [weak textView] in
                            guard let textView = textView,
                                  let textLayoutManager = textView.textLayoutManager,
                                  let textContentManager = textLayoutManager.textContentManager else { return }
                            let docRange = textContentManager.documentRange
                            if let start = textContentManager.location(docRange.location, offsetBy: lineRange.location),
                               let end = textContentManager.location(start, offsetBy: lineRange.length),
                               let textRange = NSTextRange(location: start, end: end) {
                                textLayoutManager.invalidateLayout(for: textRange)
                            }
                            textView.needsLayout = true
                            textView.needsDisplay = true
                        }
                        return true // 拦截成功，彻底清除 Blockquote 退出引用编辑
                    }
                }
            }
        
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  let selectedRange = textView.selectedRanges.first?.rangeValue else { return false }

            let nsString = textView.string as NSString
            let lineRange = nsString.lineRange(for: selectedRange)
            let lineText = nsString.substring(with: lineRange)
            
            // 用户输入了 ai::xxx 并按回车
            if let aiRequest = aiParser.parse(lineText) {
                var lineEndLocation = NSMaxRange(lineRange)
                if lineEndLocation > lineRange.location {
                    let lastCharIndex = lineEndLocation - 1
                    let lastChar = nsString.character(at: lastCharIndex)
                    if lastChar == 0x000A || lastChar == 0x000D { // \n 或 \r
                        lineEndLocation -= 1
                    }
                }
                // 只有当光标精确位于行末时才触发 AI
                if selectedRange.location == lineEndLocation {
                    let autoInsertText = "\n\n"
                    if textView.shouldChangeText(in: selectedRange, replacementString: autoInsertText) {
                        textView.insertText(autoInsertText, replacementRange: selectedRange)
                        textView.didChangeText()
                    }
                    
                    // 将解析出来的 AIRequest 提交给 AIService 异步执行
                    handleAIRequest(aiRequest, targetTextView: textView)
                    
                    // 返回 true 告诉系统我们已自行处理该 Return 事件，防止插入多余的换行
                    return true
                }
            }
            // Checkbox
            if handleCheckboxNewline(in: lineText, lineRange: lineRange, selectedRange: selectedRange, textView: textView) {
                    return true
            }
            // Unordered list,[-*+] 后面跟随至少一个空格或 Tab，符合 CommonMark 列表规范)
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
                    // 获取 marker 占据的字符范围（即 > 和后面的空格）
                    let markerRangeInLine = blockquoteMatch.range(at: 1)
                    let absoluteMarkerRange = NSRange(location: lineRange.location + markerRangeInLine.location, length: markerRangeInLine.length)
                    // 仅删除 marker（如 "> "），保留行尾的 \n，这样这一行就退化为了普通的空行，而不是把整行删掉去污染下一行
                    if textView.shouldChangeText(in: absoluteMarkerRange, replacementString: "") {
                        textView.textStorage?.replaceCharacters(in: absoluteMarkerRange, with: "")
                        textView.didChangeText()
                        return true
                    }
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
        
        // MARK: - AI Handling
        private func handleAIRequest(_ request: AIRequest, targetTextView: NSTextView) {
            aiTask?.cancel()
            print("[AI] 正在请求 AI 生成 Markdown",request)
            aiTask = Task { @MainActor [weak self, weak targetTextView] in
                guard let self = self, let textView = targetTextView else { return }
                
                // 调用 AIService 拿到流式事件流
                let eventStream = await self.aiAppleService.execute(request: request)
                
                do {
                    for try await event in eventStream {
                        switch event {
                        case .started:
                            // 可在此处更新 UI 状态，例如显示 "AI 思考中..." 占位符
                            break
                            
                        case .chunk(let textChunk):
                            // 接收到 incremental Markdown text，实时插入到当前光标位置
                            let currentInsertionPoint = textView.selectedRange()
                            if textView.shouldChangeText(in: currentInsertionPoint, replacementString: textChunk) {
                                textView.textStorage?.replaceCharacters(in: currentInsertionPoint, with: textChunk)
                                
                                // 将光标移到新插入文本的末尾
                                let newLocation = currentInsertionPoint.location + (textChunk as NSString).length
                                textView.setSelectedRange(NSRange(location: newLocation, length: 0))
                                
                                textView.didChangeText()
                            }
                            
                        case .completed:
                            // 流处理完成
                            break
                            
                        case .cancelled:
                            // 请求被取消
                            break
                            
                        case .failed(let error):
                            // 弹出提示或在编辑器中输出错误信息
                            print("AI 执行失败: \(error.localizedDescription)")
                        }
                    }
                } catch {
                    print("流读取异常: \(error)")
                }
            }
        }

        // MARK: - Context Menu AI

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            return buildContextMenu(menu, for: view)
        }

        func routeContextMenuAI(commandIndex: Int, selectedText: String, tokenCount: Int) -> (AIService, String) {
            let wordLimit = 4000 - tokenCount
            switch commandIndex {
            case 0: // Translate
                if tokenCount <= 1900 {
                    return (aiAppleService, "Translate the following text into Chinese. MUST reply in no more than \(wordLimit) words:\n\n\(selectedText)")
                }
                return (aiQWenService, "Translate the following text to Chinese. Output only the translation:\n\n\(selectedText)")
            case 1: // Summarize
                if tokenCount <= 2500 {
                    return (aiAppleService, "Summarize the following text concisely. MUST reply in no more than \(wordLimit) words:\n\n\(selectedText)")
                }
                return (aiQWenService, "Summarize the following text concisely:\n\n\(selectedText)")
            case 2: // Key Points
                if tokenCount <= 3000 {
                    return (aiAppleService, "Extract key points as a bullet list. MUST reply in no more than \(wordLimit) words:\n\n\(selectedText)")
                }
                return (aiQWenService, "Extract the key points from the following text as a bullet list:\n\n\(selectedText)")
            case 3: // Concise
                if tokenCount <= 2000 {
                    return (aiAppleService, "Rewrite the following text more concisely. MUST reply in no more than \(wordLimit) words:\n\n\(selectedText)")
                }
                return (aiQWenService, "Rewrite the following text more concisely while preserving meaning:\n\n\(selectedText)")
            default:
                return (aiAppleService, selectedText)
            }
        }

    }
}

final class MarkdownNativeTextView: NSTextView {
    var onCheckboxClick: ((Int) -> Bool)?
    var blockquoteBackgroundColor: NSColor = .clear
    var blockquoteBarColor: NSColor = .clear

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard blockquoteBackgroundColor != .clear,
              let tlm = textLayoutManager,
              let cm = tlm.textContentManager else { return }

        let originX = textContainerOrigin.x
        let originY = textContainerOrigin.y
        let viewWidth = bounds.width
        let bgColor = blockquoteBackgroundColor
        let barColor = blockquoteBarColor

        // Pass 1: group consecutive blockquote fragments into unified runs.
        // Enumerating only already-laid-out fragments keeps this O(visible lines).
        var runs: [CGRect] = []
        var currentRun: CGRect? = nil

        tlm.enumerateTextLayoutFragments(from: cm.documentRange.location, options: []) { fragment in
            guard let paragraph = fragment.textElement as? NSTextParagraph else {
                if let r = currentRun { runs.append(r); currentRun = nil }
                return true
            }
            let attrStr = paragraph.attributedString
            var isBlockquote = false
            if attrStr.length > 0 {
                attrStr.enumerateAttribute(.isBlockquote, in: NSRange(location: 0, length: attrStr.length), options: []) { v, _, stop in
                    if let b = v as? Bool, b { isBlockquote = true; stop.pointee = true }
                }
            }
            let frame = fragment.layoutFragmentFrame
            let vf = CGRect(x: frame.origin.x + originX, y: frame.origin.y + originY,
                            width: frame.width, height: frame.height)
            if isBlockquote {
                if let r = currentRun { currentRun = r.union(vf) } else { currentRun = vf }
            } else {
                if let r = currentRun { runs.append(r); currentRun = nil }
            }
            return true
        }
        if let r = currentRun { runs.append(r) }

        // Pass 2: draw each run that intersects the dirty rect.
        // The CGContext clips to rect automatically, so partial runs draw correctly
        // (rounded corners only appear at the true start/end of a run).
        NSGraphicsContext.saveGraphicsState()
        for run in runs where run.intersects(rect) {
            let bgRect = CGRect(
                x: originX + 4,
                y: run.minY - 8,
                width: max(viewWidth - originX * 2 - 8, 40),
                height: max(run.height + 16, 10)
            )
            let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 6, yRadius: 6)
            bgColor.setFill()
            bgPath.fill()

            let barRect = CGRect(x: bgRect.minX + 2, y: bgRect.minY + 3, width: 3.5, height: max(bgRect.height - 6, 2))
            let barPath = NSBezierPath(roundedRect: barRect, xRadius: 1.75, yRadius: 1.75)
            barColor.setFill()
            barPath.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if let handler = onCheckboxClick, handler(index) {
            return
        }
        super.mouseDown(with: event)
    }
}

