import AppKit
import SwiftUI

struct MarkdownBlockquote {
    
    // MARK: - 正则与匹配
    /// 匹配引用块标记（如 `>` 或 `  >`）
    private static let blockquoteRegex = try? NSRegularExpression(pattern: "^(\\s*>)\\s*(.*)$")

    // MARK: - 1. 渲染逻辑 (从 MarkdownRenderer 抽离)
    static func apply(
        markerRange: NSRange,
        contentRange: NSRange,
        lineRange: NSRange,
        inlines: [MarkdownInline],
        to attributed: NSMutableAttributedString,
        context: MarkdownRenderContext,
        theme: AppTheme,
        renderer: MarkdownRenderer
    ) {
        guard let marker = renderer.safeRange(markerRange, in: attributed),
              let content = renderer.safeRange(contentRange, in: attributed),
              let line = renderer.safeRange(lineRange, in: attributed) else { return }

        let showMarker = renderer.shouldShowMarker(lineRange, selectedRange: context.selectedRange)
        let markerColor = showMarker ? NSColor(theme.textMuted) : NSColor.clear

        attributed.addAttributes([
            .foregroundColor: markerColor,
            .font: renderer.bodyFont()
        ], range: marker)

        attributed.addAttributes([
            .foregroundColor: NSColor(theme.textCitation),
            .font: renderer.bodyFont()
        ], range: content)

        let paragraph = NSMutableParagraphStyle()
        let textBlock = NSTextBlock()
        textBlock.backgroundColor = NSColor(theme.bgCitation)
        textBlock.setWidth(8, type: .absoluteValueType, for: .padding)
        textBlock.setWidth(16, type: .absoluteValueType, for: .margin, edge: .minX)
        textBlock.setWidth(16, type: .absoluteValueType, for: .margin, edge: .maxX)
        textBlock.setContentWidth(100, type: .percentageValueType)
        paragraph.textBlocks = [textBlock]
        paragraph.paragraphSpacing = 4
        
        // 施加 TextKit 2 所需的样式隔离
        renderer.applyParagraphStyle(paragraph, lineRange: line, to: attributed)
        // 引用块内部的 Inline 样式
        renderer.applyInline(inlines, to: attributed, theme: theme, context: context)
    }
    
    // MARK: - 2. 编辑交互：处理 Delete 键
    @MainActor
    static func handleDeleteBackward(in lineText: String, lineRange: NSRange, textView: NSTextView) -> Bool {
        let trimmedLine = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 场景 A: 当前行本身就是引用标记符 '>'
        if trimmedLine == ">" || (trimmedLine.isEmpty && lineText.contains(">")) {
            if textView.shouldChangeText(in: lineRange, replacementString: "") {
                let previousLineEndLocation = max(0, lineRange.location - 1)
                textView.textStorage?.replaceCharacters(in: lineRange, with: "")
                textView.didChangeText()
                DispatchQueue.main.async { [weak textView] in
                    guard let textView = textView else { return }
                    let safeLocation = min(previousLineEndLocation, (textView.string as NSString).length)
                    let newRange = NSRange(location: safeLocation, length: 0)
                    textView.setSelectedRange(newRange)
                    textView.scrollRangeToVisible(newRange)
                }
                return true
            }
        }
        
        // 场景 B: 清除残留的 NSTextBlock 属性 (TextKit 2 块级样式清理)
        if trimmedLine.isEmpty, let storage = textView.textStorage, lineRange.location < storage.length {
            return clearBlockStyleIfNeeded(at: lineRange, in: textView, storage: storage)
        }
        
        return false
    }
    
    // MARK: - 3. 编辑交互：处理 Return 键 (自动续行/退出引用)
    @MainActor
    static func handleInsertNewline(in lineText: String, lineRange: NSRange, selectedRange: NSRange, textView: NSTextView) -> Bool {
        let nsLineText = lineText as NSString
        guard let match = blockquoteRegex?.firstMatch(in: lineText, range: NSRange(location: 0, length: nsLineText.length)) else {
            return false
        }

        let marker = nsLineText.substring(with: match.range(at: 1))
        let content = nsLineText.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)

        if content.isEmpty {
            // 连续按下回车：清空引用标记，退出 Blockquote
            let markerRangeInLine = match.range(at: 1)
            let absoluteMarkerRange = NSRange(location: lineRange.location + markerRangeInLine.location, length: markerRangeInLine.length)
            if textView.shouldChangeText(in: absoluteMarkerRange, replacementString: "") {
                textView.textStorage?.replaceCharacters(in: absoluteMarkerRange, with: "")
                textView.didChangeText()
                return true
            }
        } else {
            // 引用块内容续行：自动在下一行补上 `> `
            let autoInsertText = "\n\(marker) "
            if textView.shouldChangeText(in: selectedRange, replacementString: autoInsertText) {
                textView.insertText(autoInsertText, replacementRange: selectedRange)
                textView.didChangeText()
                return true
            }
        }
        return false
    }
    
    // MARK: - Helper Methods
    
    /// 清除指定行包含的 TextBlock 样式并重置 TextKit 2 布局
    @MainActor
    private static func clearBlockStyleIfNeeded(at lineRange: NSRange, in textView: NSTextView, storage: NSTextStorage) -> Bool {
        var hasTextBlock = false
        storage.enumerateAttribute(.paragraphStyle, in: lineRange, options: []) { value, _, stop in
            if let style = value as? NSParagraphStyle, !style.textBlocks.isEmpty {
                hasTextBlock = true
                stop.pointee = true
            }
        }
        
        guard hasTextBlock else { return false }
        
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
