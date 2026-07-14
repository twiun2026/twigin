import AppKit
import SwiftUI

struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var theme: AppTheme

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
        textView.onWillReplaceText = { range, replacement in
            context.coordinator.captureEditRange(range: range, replacement: replacement)
        }

        textView.backgroundColor = NSColor(theme.bgNoteEditor)
        textView.insertionPointColor = NSColor(theme.textMain)
        textView.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(theme.bgNoteEditor)
        scrollView.documentView = textView

        context.coordinator.bind(textView: textView)
        context.coordinator.refreshDocumentAndRender(forceFull: true)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? MarkdownNativeTextView else { return }

        let bgColor = NSColor(theme.bgNoteEditor)
        if textView.backgroundColor != bgColor {
            textView.backgroundColor = bgColor
            nsView.backgroundColor = bgColor
        }

        textView.insertionPointColor = NSColor(theme.textMain)

        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
            context.coordinator.pendingEditedRange = NSRange(location: 0, length: (text as NSString).length)
            context.coordinator.refreshDocumentAndRender(forceFull: true)
        } else {
            context.coordinator.refreshTheme(theme)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        weak var textView: MarkdownNativeTextView?

        private let renderer = MarkdownRenderer()
        private var document = MarkdownDocument(source: "", blocks: [])
        var pendingEditedRange: NSRange?

        init(parent: MarkdownTextView) {
            self.parent = parent
        }

        func bind(textView: MarkdownNativeTextView) {
            self.textView = textView
        }

        func captureEditRange(range: NSRange, replacement: String?) {
            let replacementLength = (replacement as NSString?)?.length ?? 0
            pendingEditedRange = NSRange(location: range.location, length: replacementLength)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            refreshDocumentAndRender(forceFull: false)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Selection updates do not trigger full reparse; rendering updates happen on text or viewport changes.
        }

        func refreshTheme(_ theme: AppTheme) {
            parent.theme = theme
            refreshDocumentAndRender(forceFull: false, sourceChanged: false)
        }

        func refreshDocumentAndRender(forceFull: Bool, sourceChanged: Bool = true) {
            guard let textView else { return }

            if sourceChanged || forceFull {
                document = renderer.parse(source: textView.string)
            }

            let sourceLength = (textView.string as NSString).length
            let editedRange: NSRange?
            if forceFull {
                editedRange = NSRange(location: 0, length: sourceLength)
            } else {
                editedRange = pendingEditedRange
            }

            renderer.render(
                .init(
                    textView: textView,
                    theme: parent.theme,
                    document: document,
                    editedRange: editedRange,
                    onToggleChecklist: { [weak self] range, isChecked in
                        self?.toggleChecklist(in: range, to: isChecked)
                    },
                    onTapImage: { path in
                        NSWorkspace.shared.openFile(path)
                    }
                )
            )

            pendingEditedRange = nil
        }

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
        
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // 检查是否是按下回车键（insertNewline: 指令）
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                guard let selectedRange = textView.selectedRanges.first?.rangeValue else { return false }
                
                let nsString = textView.string as NSString
                // 获取当前光标所在行的范围和文本
                let lineRange = nsString.lineRange(for: selectedRange)
                let lineText = nsString.substring(with: lineRange)
                
                // 1. 无序列表匹配 (例如："- text" 或 "* text" 或 "+ text")
                if let bulletMatch = try? NSRegularExpression(pattern: "^(\\s*[-*+])\\s*(.*)$")
                    .firstMatch(in: lineText, range: NSRange(location: 0, length: (lineText as NSString).length)) {
                    
                    let marker = (lineText as NSString).substring(with: bulletMatch.range(at: 1))
                    let content = (lineText as NSString).substring(with: bulletMatch.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if content.isEmpty {
                        // 【退出列表】如果当前列表行什么都没写，连续按回车时，删除前缀，退回普通行
                        textView.shouldChangeText(in: lineRange, replacementString: "")
                        textView.textStorage?.replaceCharacters(in: lineRange, with: "")
                        textView.didChangeText()
                        return true
                    } else {
                        // 【延续列表】自动在新行补上相同的符号前缀
                        let autoInsertText = "\n\(marker) "
                        if textView.shouldChangeText(in: selectedRange, replacementString: autoInsertText) {
                            textView.insertText(autoInsertText, replacementRange: selectedRange)
                            textView.didChangeText()
                            return true
                        }
                    }
                }
                
                // 2. 有序列表匹配 (例如："1. text")
                if let orderedMatch = try? NSRegularExpression(pattern: "^(\\s*)(\\d+)\\.\\s*(.*)$")
                    .firstMatch(in: lineText, range: NSRange(location: 0, length: (lineText as NSString).length)) {
                    
                    let spaces = (lineText as NSString).substring(with: orderedMatch.range(at: 1))
                    let numStr = (lineText as NSString).substring(with: orderedMatch.range(at: 2))
                    let content = (lineText as NSString).substring(with: orderedMatch.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if content.isEmpty {
                        // 【退出列表】
                        textView.shouldChangeText(in: lineRange, replacementString: "")
                        textView.textStorage?.replaceCharacters(in: lineRange, with: "")
                        textView.didChangeText()
                        return true
                    } else if let currentNum = Int(numStr) {
                        // 【延续列表】自动数字 + 1
                        let autoInsertText = "\n\(spaces)\(currentNum + 1). "
                        if textView.shouldChangeText(in: selectedRange, replacementString: autoInsertText) {
                            textView.insertText(autoInsertText, replacementRange: selectedRange)
                            textView.didChangeText()
                            return true
                        }
                    }
                }
                
                // 3. Blockquote auto-continuation
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
            }
            
            // 返回 false 让原生 NSTextView 继续处理其他默认指令
            return false
        }
    }
}

final class MarkdownNativeTextView: NSTextView {
    var onWillReplaceText: ((NSRange, String?) -> Void)?

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        onWillReplaceText?(affectedCharRange, replacementString)
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }
}
