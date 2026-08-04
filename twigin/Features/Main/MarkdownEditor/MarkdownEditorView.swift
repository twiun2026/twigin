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

        if let contentStorage = textView.textLayoutManager?.textContentManager as? NSTextContentStorage {
            contentStorage.delegate = context.coordinator
        }
        textView.onCheckboxClick = { [weak coordinator = context.coordinator] index in
            coordinator?.handleCheckboxClick(at: index) ?? false
        }

        textView.backgroundColor = NSColor(theme.bgNoteEditor)
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
            if context.coordinator.lastRenderedFontName != fontName
               || context.coordinator.lastRenderedFontSize != fontSize {
                textView.font = Self.resolvedFont(for: fontName, size: fontSize)
            }
            context.coordinator.lastRenderedTheme = theme
            context.coordinator.lastRenderedFontName = fontName
            context.coordinator.lastRenderedFontSize = fontSize
            context.coordinator.lastRenderedLineSpacing = lineSpacing
            context.coordinator.rerenderFull()
        }

        context.coordinator.consumeFocusRequestIfNeeded(focusRequest)
    }

    nonisolated static func resolvedFont(for fontName: String, size: CGFloat = 14) -> NSFont {
        let primaryFont: NSFont

        if !fontName.isEmpty, let font = NSFont(name: fontName, size: size) {
            primaryFont = font
        } else {
            primaryFont = NSFont.systemFont(ofSize: size)
        }

        let chineseFontNames = ["PingFangSC-Regular", "Heiti SC", "Microsoft YaHei"]
        let fallbackDescriptors = chineseFontNames.compactMap { name -> NSFontDescriptor? in
            return NSFontDescriptor(name: name, size: size)
        }

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
        private var editSerial: UInt64 = 0
        private var needsFullCatchup = false
        private var isLoadingContent = false
        var suppressStringSync = false
        private var hasPendingEdit = false
        
        private let aiParser = AICommandParser()
        let aiAppleService = AIService(provider: AppleFoundationProvider())
        let aiQWenService = AIService(provider: QWenProvider())
        private var aiTask: Task<Void, Never>?
        var contextMenuAITask: Task<Void, Never>?
        var aiPopoverController: AiPopoverController?
        
        private var lastSelectedRange: NSRange? = nil
        private var cachedBlocks: [MarkdownBlock] = []
        private var isInsertingText = false
        
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

        // MARK: 内容装载

        @MainActor func setContent(_ text: String, on textView: MarkdownNativeTextView) {
            isLoadingContent = true
            textView.string = text
            isLoadingContent = false
            load(text: text)
        }

        private func load(text: String) {
            editSerial &+= 1
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

        // MARK: 重渲染

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
            guard !isLoadingContent else { return }
            hasPendingEdit = true
            aiPopoverController?.adjustAnchor(editedRange: editedRange, delta: delta)

            let inserted = textStorage.attributedSubstring(from: editedRange).string
            editSerial &+= 1
            let serial = editSerial

            engine.apply(editedRange: editedRange, delta: delta, inserted: inserted, serial: serial) { [weak self] result in
                DispatchQueue.main.async { self?.onEditResult(result) }
            }
        }

        @MainActor private func onEditResult(_ result: MarkdownEditResult) {
            guard let textView, let storage = textView.textStorage else { return }

            let isLatest = (result.serial == editSerial) && (storage.length == result.textLength)
            guard isLatest else {
                needsFullCatchup = true
                return
            }

            suppressStringSync = true
            parent.text = result.source

            guard !textView.hasMarkedText() else {
                hasPendingEdit = false
                return
            }

            if needsFullCatchup {
                needsFullCatchup = false
                catchUpFullRender(expectedSerial: result.serial)
            } else if let diff = result.blockDiff, !diff.isEmpty {
                renderIncremental(affectedRange: result.affectedRange, blockDiff: diff, allBlocks: result.allBlocks)
            } else {
                hasPendingEdit = false
            }

            if let tlm = textView.textLayoutManager, let cm = tlm.textContentManager {
                tlm.invalidateLayout(for: cm.documentRange)
            }
            textView.needsDisplay = true
        }

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
            if isInsertingText { return }
            
            guard let textView = textView, let storage = textView.textStorage else { return }
            let currentSelectedRange = textView.selectedRange()
            
            if lastSelectedRange == currentSelectedRange { return }
            
            let oldRange = lastSelectedRange
            lastSelectedRange = currentSelectedRange
            
            let storageLength = storage.length
            guard storageLength > 0 else { return }
            
            let safeLocation = min(max(0, currentSelectedRange.location), storageLength)
            let safeLength = min(currentSelectedRange.length, storageLength - safeLocation)
            let safeSelectedRange = NSRange(location: safeLocation, length: safeLength)
            
            let nsString = storage.string as NSString
            guard NSMaxRange(safeSelectedRange) <= nsString.length else { return }
            
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
            
            if let oldLine = oldFullLineRange, oldLine == newFullLineRange {
                let lineBlocks = cachedBlocks.filter { $0.lineRange.overlaps(newFullLineRange) }
                let hasInlines = lineBlocks.contains { !$0.inlines.isEmpty || $0.markerRange != nil }
                if !hasInlines { return }
            }
            
            var affectedRanges: [NSRange] = [newFullLineRange]
            if let oldLine = oldFullLineRange, oldLine != newFullLineRange {
                affectedRanges.append(oldLine)
            }
            
            renderSelectionChange(affectedRanges: affectedRanges)
        }
        
        @MainActor private func renderSelectionChange(affectedRanges: [NSRange]) {
            if isInsertingText || isLoadingContent || hasPendingEdit { return }
            guard let textView = textView, let storage = textView.textStorage else { return }
            guard !cachedBlocks.isEmpty else { return }
            
            renderer.bodyFontName = parent.fontName
            renderer.baseFontSize = parent.fontSize
            renderer.lineSpacingMultiplier = parent.lineSpacing

            let context = makeContext(textView: textView, document: MarkdownDocument(source: "", revision: 0))
            
            let affectedBlocks = cachedBlocks.filter { block in
                affectedRanges.contains { $0.overlaps(block.lineRange) }
            }
            
            storage.beginEditing()
            for range in affectedRanges {
                for key in [.foregroundColor, .font, .strikethroughStyle, .backgroundColor, .paragraphStyle] as [NSAttributedString.Key] {
                    storage.removeAttribute(key, range: range)
                }
                storage.addAttributes([
                    .foregroundColor: NSColor(parent.theme.textMain),
                    .font: renderer.bodyFont(),
                    .paragraphStyle: NSParagraphStyle.default
                ], range: range)
            }
            
            for block in affectedBlocks {
                renderer.applyBlock(block, to: storage, theme: parent.theme, context: context)
            }
            storage.endEditing()
            
            renderer.invalidateLayout(in: textView, affectedRanges: affectedRanges)
            textView.needsDisplay = true
        }

        // MARK: 渲染

        @MainActor private func renderIncremental(affectedRange: NSRange?, blockDiff: MarkdownBlockDiff, allBlocks: [MarkdownBlock]) {
            guard let textView else { return }
            hasPendingEdit = false
            self.cachedBlocks = allBlocks
            renderer.bodyFontName = parent.fontName
            renderer.baseFontSize = parent.fontSize
            renderer.lineSpacingMultiplier = parent.lineSpacing
            let document = MarkdownDocument(source: "", affectedRange: affectedRange, blockDiff: blockDiff, revision: 0, explicitBlocks: allBlocks)
            renderer.render(makeContext(textView: textView, document: document))
        }

        @MainActor private func renderFull(blocks: [MarkdownBlock]) {
            guard let textView else { return }
            hasPendingEdit = false
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
                selectedRange: textView.selectedRange(),
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
            if commandSelector == #selector(NSResponder.deleteBackward(_:)),
               let selectedRange = textView.selectedRanges.first?.rangeValue,
               selectedRange.length == 0 {
                
                let nsString = textView.string as NSString
                let lineRange = nsString.lineRange(for: selectedRange)
                let lineText = nsString.substring(with: lineRange)

                // 调用 Handler 处理删除逻辑
                if MarkdownBlockquote.handleDeleteBackward(in: lineText, lineRange: lineRange, textView: textView) {
                    return true
                }
        
                let trimmedLine = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedLine.isEmpty, let storage = textView.textStorage, lineRange.location < storage.length {
                    var hasTextBlock = false
                    storage.enumerateAttribute(.paragraphStyle, in: lineRange, options: []) { value, _, stop in
                        if let style = value as? NSParagraphStyle, !style.textBlocks.isEmpty {
                            hasTextBlock = true
                            stop.pointee = true
                        }
                    }
                    
                    if hasTextBlock {
                        storage.removeAttribute(.paragraphStyle, range: lineRange)
                        storage.addAttribute(.paragraphStyle, value: NSParagraphStyle.default, range: lineRange)
                        textView.didChangeText()
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
                        return true
                    }
                }
            }
            
            // MARK: - 2. 处理 回车键 (Insert Newline)
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  let selectedRange = textView.selectedRanges.first?.rangeValue else { return false }

            let nsString = textView.string as NSString
            let lineRange = nsString.lineRange(for: selectedRange)
            let lineText = nsString.substring(with: lineRange)
            
            if let aiRequest = aiParser.parse(lineText) {
                var lineEndLocation = NSMaxRange(lineRange)
                if lineEndLocation > lineRange.location {
                    let lastCharIndex = lineEndLocation - 1
                    let lastChar = nsString.character(at: lastCharIndex)
                    if lastChar == 0x000A || lastChar == 0x000D {
                        lineEndLocation -= 1
                    }
                }
                
                if selectedRange.location == lineEndLocation {
                    let formattedH5Text = "##### \(aiRequest.prompt)?"
                    let targetTextRange = NSRange(location: lineRange.location, length: lineEndLocation - lineRange.location)
                    
                    if textView.shouldChangeText(in: targetTextRange, replacementString: formattedH5Text) {
                        textView.replaceCharacters(in: targetTextRange, with: formattedH5Text)
                        textView.didChangeText()
                    }

                    let currentSelectedRange = textView.selectedRange()
                    let autoInsertText = "\n"
                    if textView.shouldChangeText(in: currentSelectedRange, replacementString: autoInsertText) {
                        textView.insertText(autoInsertText, replacementRange: currentSelectedRange)
                        textView.didChangeText()
                    }
                    
                    handleAIRequest(aiRequest, targetTextView: textView)

                    return true
                }
            }
            if handleCheckboxNewline(in: lineText, lineRange: lineRange, selectedRange: selectedRange, textView: textView) {
                    return true
            }
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
                    let autoInsertText = "\n\(markerAndSpace)"
                    if textView.shouldChangeText(in: selectedRange, replacementString: autoInsertText) {
                        textView.insertText(autoInsertText, replacementRange: selectedRange)
                        textView.didChangeText()
                        return true
                    }
                }
            }
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

            //在此处调用 Handler 处理引用块的回车逻辑（自动续行 / 连续回车退出）
            if MarkdownBlockquote.handleInsertNewline(in: lineText, lineRange: lineRange, selectedRange: selectedRange, textView: textView) {
                return true
            }
            
            return false
        }
        
        // MARK: - AI Handling
        private func handleAIRequest(_ request: AIRequest, targetTextView: NSTextView) {
            aiTask?.cancel()
            print("[AI] 正在请求 AI 生成 Markdown", request)
            
            aiTask = Task { @MainActor [weak self, weak targetTextView] in
                guard let self = self, let textView = targetTextView else { return }
                
                guard let layoutManager = textView.textLayoutManager,
                      let contentManager = layoutManager.textContentManager as? NSTextContentStorage,
                      let storage = textView.textStorage else { return }
                
                let initialIndex = textView.selectedRange().location
                let docRange = contentManager.documentRange
                
                guard var currentLocation: NSTextLocation = contentManager.location(docRange.location, offsetBy: initialIndex) else { return }
                
                let eventStream = await self.aiAppleService.execute(request: request)
                
                do {
                    for try await event in eventStream {
                        switch event {
                        case .started:
                            break
                            
                        case .chunk(let textChunk):
                            let targetIndex = contentManager.offset(from: contentManager.documentRange.location, to: currentLocation)
                            guard targetIndex >= 0 && targetIndex <= storage.length else { continue }
                            
                            let targetRange = NSRange(location: targetIndex, length: 0)
                            let chunkLength = (textChunk as NSString).length
                            
                            textView.undoManager?.disableUndoRegistration()
                            
                            if textView.shouldChangeText(in: targetRange, replacementString: textChunk) {
                                storage.replaceCharacters(in: targetRange, with: textChunk)
                                if let nextLocation = contentManager.location(currentLocation, offsetBy: chunkLength) {
                                    currentLocation = nextLocation
                                }
                                textView.didChangeText()
                            }
                            
                            textView.undoManager?.enableUndoRegistration()
                            
                        case .completed, .cancelled:
                            break
                            
                        case .failed(let error):
                            print("AI 执行失败: \(error.localizedDescription)")
                        }
                    }
                } catch {
                    print("流读取异常: \(error)")
                }
            }
        }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            return buildContextMenu(menu, for: view)
        }

        func routeContextMenuAI(commandIndex: Int, selectedText: String, tokenCount: Int) -> (AIService, String) {
            let wordLimit = 4000 - tokenCount
            print("tokenCount=", tokenCount, "wordLimit=", wordLimit)
            switch commandIndex {
            case 0:
                let prompt = """
                        Translate the following text into Chinese. Maintain the EXACT same number of paragraphs as the source text, separated by empty lines. Output ONLY the translated text:

                        \(selectedText)
                        """
                return (tokenCount <= 1900 ? aiAppleService : aiQWenService, prompt)
                
            case 1:
                let prompt = """
                        Summarize each paragraph of the following text individually. 
                        Maintain the EXACT same number of paragraphs as the source text, separated by empty lines.
                        Output ONLY the summary paragraphs without markdown formatting:

                        \(selectedText)
                        """
                return (tokenCount <= 2500 ? aiAppleService : aiQWenService, prompt)
                
            case 2:
                let prompt = """
                        Extract key points from the following text as a bullet list.
                        Provide EXACTLY ONE bullet point per paragraph corresponding to the source text.
                        Format each line starting with a dash (e.g. - Key point).
                        Output ONLY the bullet list:

                        \(selectedText)
                        """
                return (tokenCount <= 3000 ? aiAppleService : aiQWenService, prompt)
                
            case 3:
                let prompt = """
                        Rewrite the following text more concisely while preserving meaning.
                        Maintain the EXACT same number of paragraphs as the source text, separated by empty lines.
                        Output ONLY the rewritten text:

                        \(selectedText)
                        """
                return (tokenCount <= 2000 ? aiAppleService : aiQWenService, prompt)
                
            default:
                return (aiAppleService, selectedText)
            }
        }
        
        @MainActor func showAIPopover(title: String, anchorCharOffset: Int) {
            guard let textView = self.textView else { return }
            
            let targetRange = textView.selectedRange()
            
            aiPopoverController?.dismiss()
            let controller = AiPopoverController(title: title)
            self.aiPopoverController = controller
            
            controller.show(
                anchorCharOffset: anchorCharOffset,
                in: textView,
                theme: parent.theme,
                onInsert: { [weak self, weak textView] resultText in
                    guard let self = self, let textView = textView else { return }
                    self.insertInterleavedText(resultText, targetRange: targetRange, in: textView)
                },
                onReplace: { [weak self, weak textView] replacedText in
                    guard let self = self, let textView = textView else { return }
                    self.replaceSelectedText(with: replacedText, targetRange: targetRange, in: textView)
                },
                onNewNote: { newNoteText in
                    NotificationCenter.default.post(
                        name: .aiPopoverNewNote,
                        object: nil,
                        userInfo: ["content": newNoteText]
                    )
                }
            )
        }
        
        @MainActor func replaceSelectedText(with text: String, targetRange: NSRange, in textView: MarkdownNativeTextView) {
            isInsertingText = true
            
            let replacementLength = (text as NSString).length
            let newSelection = NSRange(location: targetRange.location + replacementLength, length: 0)
            
            if textView.shouldChangeText(in: targetRange, replacementString: text) {
                textView.textStorage?.replaceCharacters(in: targetRange, with: text)
                textView.setSelectedRange(newSelection)
                textView.didChangeText()
            }
            DispatchQueue.main.async { [weak self] in
                self?.isInsertingText = false
            }
        }

        @MainActor private func insertTextAtAnchor(_ text: String, in textView: MarkdownNativeTextView) {
            let range = NSRange(location: textView.selectedRange().location, length: 0)
            if textView.shouldChangeText(in: range, replacementString: text) {
                textView.textStorage?.replaceCharacters(in: range, with: text)
                textView.didChangeText()
            }
        }
        
        @MainActor func insertInterleavedText(_ translationText: String, targetRange: NSRange, in textView: MarkdownNativeTextView) {
            let fullText = textView.string as NSString
            guard targetRange.location != NSNotFound,
                  NSMaxRange(targetRange) <= fullText.length else { return }
            
            let originalText = fullText.substring(with: targetRange)
            let endsWithNewline = originalText.hasSuffix("\n") || originalText.hasSuffix("\r\n")
            
            let originalList = originalText
                .replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                
            let translationList = translationText
                .replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            
            var finalString = ""
            var aiTextRanges: [NSRange] = []
            
            let maxCount = max(originalList.count, translationList.count)
            
            for index in 0..<maxCount {
                if index < originalList.count {
                    if !finalString.isEmpty {
                        finalString += "\n\n"
                    }
                    finalString += originalList[index]
                }
                
                if index < translationList.count {
                    if !finalString.isEmpty {
                        finalString += "\n\n"
                    }
                    let aiSegment = translationList[index]
                    let segmentStart = (finalString as NSString).length
                    let segmentLength = (aiSegment as NSString).length
                    
                    finalString += aiSegment
                    aiTextRanges.append(NSRange(location: segmentStart, length: segmentLength))
                }
            }
            
            if endsWithNewline && !finalString.hasSuffix("\n") {
                finalString += "\n"
            }
            
            let insertedLength = (finalString as NSString).length
            guard let storage = textView.textStorage else { return }
            
            isInsertingText = true
            isLoadingContent = true
            editSerial &+= 1
            let expectedSerial = editSerial
            
            if textView.shouldChangeText(in: targetRange, replacementString: finalString) {
                storage.beginEditing()
                
                textView.undoManager?.disableUndoRegistration()
                storage.replaceCharacters(in: targetRange, with: finalString)
                textView.undoManager?.enableUndoRegistration()
                
                let baseLocation = targetRange.location
                let citationColor = NSColor(parent.theme.textCitation)
                
                for relativeRange in aiTextRanges {
                    let absoluteRange = NSRange(
                        location: baseLocation + relativeRange.location,
                        length: relativeRange.length
                    )
                    if NSMaxRange(absoluteRange) <= storage.length {
                        storage.addAttribute(.isAICitation, value: true, range: absoluteRange)
                        storage.addAttribute(.foregroundColor, value: citationColor, range: absoluteRange)
                    }
                }
                
                storage.endEditing()
                
                let newLocation = targetRange.location + insertedLength
                let newSelection = NSRange(location: newLocation, length: 0)
                textView.setSelectedRange(newSelection)
                
                isLoadingContent = false
                textView.didChangeText()
                
                let newSource = textView.string
                engine.load(text: newSource) { [weak self, aiTextRanges] snapshot in
                    DispatchQueue.main.async {
                        guard let self = self,
                              self.editSerial == expectedSerial,
                              let currentTextView = self.textView,
                              let currentStorage = currentTextView.textStorage,
                              currentStorage.length == snapshot.textLength else { return }
                        
                        self.renderFull(blocks: snapshot.blocks)
                        
                        currentStorage.beginEditing()
                        for relativeRange in aiTextRanges {
                            let absoluteRange = NSRange(
                                location: baseLocation + relativeRange.location,
                                length: relativeRange.length
                            )
                            if NSMaxRange(absoluteRange) <= currentStorage.length {
                                currentStorage.addAttribute(.isAICitation, value: true, range: absoluteRange)
                                currentStorage.addAttribute(.foregroundColor, value: citationColor, range: absoluteRange)
                            }
                        }
                        currentStorage.endEditing()
                    }
                }
            } else {
                isLoadingContent = false
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.isInsertingText = false
            }
        }
        
        private func buildInterleavedText(original: String, translation: String) -> String {
            let originalParagraphs = original
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            
            let translationParagraphs = translation
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            
            var combined: [String] = []
            let maxCount = max(originalParagraphs.count, translationParagraphs.count)
            
            for i in 0..<maxCount {
                if i < originalParagraphs.count {
                    combined.append(originalParagraphs[i])
                }
                if i < translationParagraphs.count {
                    combined.append(translationParagraphs[i])
                }
            }
            
            return combined.joined(separator: "\n\n")
        }
        
        @MainActor func handleContextMenuAIAction(commandIndex: Int) {
            guard let textView = self.textView else { return }
            
            let selectedRange = textView.selectedRange()
            let nsString = textView.string as NSString
            
            guard selectedRange.location != NSNotFound,
                  NSMaxRange(selectedRange) <= nsString.length,
                  selectedRange.length > 0 else { return }
            
            let selectedText = nsString.substring(with: selectedRange)
            let tokenCount = selectedText.count
            
            let (service, prompt) = routeContextMenuAI(
                commandIndex: commandIndex,
                selectedText: selectedText,
                tokenCount: tokenCount
            )
            
            let titles = ["Translate", "Summarize", "Key Points", "Concise"]
            let title = commandIndex < titles.count ? titles[commandIndex] : "AI Action"
            
            showAIPopover(title: title, anchorCharOffset: selectedRange.location)
            
            let request = AIRequest(command: .ask, prompt: prompt)
            aiPopoverController?.startStreaming(service: service, request: request)
        }
    }
}

// 💥 恢复历史版本干净标准的 TextView 类，去除冗余的 drawBackground 重写
final class MarkdownNativeTextView: NSTextView {
    var onCheckboxClick: ((Int) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        
        if let handler = onCheckboxClick, handler(index) {
            return
        }
        
        let targetRange = NSRange(location: index, length: 0)
        if self.selectedRange() != targetRange {
            self.setSelectedRange(targetRange)
            
            if let delegate = self.delegate as? MarkdownTextView.Coordinator {
                let notification = Notification(name: NSTextView.didChangeSelectionNotification, object: self)
                delegate.textViewDidChangeSelection(notification)
            }
        }

        super.mouseDown(with: event)
    }
}
