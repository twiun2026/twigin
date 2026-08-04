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
        } else if textView.string != text && !context.coordinator.isLoadingContent  {
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
        
        //渲染状态
        var lastRenderedTheme: AppTheme? = nil
        var lastRenderedFontName: String = ""
        var lastRenderedFontSize: CGFloat = 14
        var lastRenderedLineSpacing: CGFloat = 0
        private var lastConsumedFocusRequest: UUID?
        
        //引擎与状态控制
        let renderer: MarkdownRenderer
        let engine = MarkdownParsingEngine()
        var editSerial: UInt64 = 0
        private var needsFullCatchup = false
        var isLoadingContent = false
        var suppressStringSync = false
        var hasPendingEdit = false
        
        //AI状态
        private let aiParser = AICommandParser()
        let aiAppleService = AIService(provider: AppleFoundationProvider())
        let aiQWenService = AIService(provider: QWenProvider())
        var aiTask: Task<Void, Never>?
        var contextMenuAITask: Task<Void, Never>?
        var aiPopoverController: AiPopoverController?
        
        //Selection and cached Block
        var lastSelectedRange: NSRange? = nil
        var cachedBlocks: [MarkdownBlock] = []
        var isInsertingText = false
        
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

        // MARK: 加载内容
        // 直接设置内容，触发渲染
        @MainActor func setContent(_ text: String, on textView: MarkdownNativeTextView) {
            isLoadingContent = true
            textView.string = text
            isLoadingContent = false
            load(text: text)
        }

        // MARK: 加载内容到引擎
        // 该方法会增加 editSerial，确保异步加载的结果不会覆盖后续的编辑
        // 该方法会在加载完成后触发全量渲染
        private func load(text: String) {
            editSerial &+= 1
            needsFullCatchup = false
            let expected = editSerial

            // 将 AST 语法树解析派发至后台高优先级队列，避免阻塞 Main Thread
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                
                // 调用你现有的 engine.load
                self.engine.load(text: text) { [weak self] snapshot in
                    // 解析完成后，切回主线程进行视口渲染与数据校验
                    DispatchQueue.main.async {
                        guard let self = self,
                              self.editSerial == expected,
                              let textView = self.textView,
                              let storage = textView.textStorage,
                              storage.length == snapshot.textLength else { return }
                        
                        self.renderFull(blocks: snapshot.blocks)
                    }
                }
            }
        }

        // MARK: 重渲染
        // 该方法会触发全量渲染，确保渲染结果与引擎状态一致
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

        @MainActor func renderFull(blocks: [MarkdownBlock]) {
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

        @MainActor func makeContext(textView: MarkdownNativeTextView, document: MarkdownDocument) -> MarkdownRenderContext {
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

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            return buildContextMenu(menu, for: view)
        }
    }
}

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
