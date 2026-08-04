import AppKit
import Foundation
import SwiftUI

// MARK: - Checkbox Logic Extension

extension MarkdownTextView.Coordinator {
    
    // 1. Checklist 正则表达与缓存（如果只有 Checkbox 使用，建议放在这里）
    static let checklistDisplayRegex = try! NSRegularExpression(pattern: "^(\\s*[-*+]\\s+\\[([ xX])\\]\\s*)(.*)$")

    // 2. 生成/缓存 Checkbox 图片附件
    func checkboxAttachment(isChecked: Bool, font: NSFont) -> NSTextAttachment {
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

    // 3. 点击响应逻辑
    @MainActor
    func handleCheckboxClick(at index: Int) -> Bool {
        guard let textView else { return false }
        let ns = textView.string as NSString
        guard ns.length > 0 else { return false }

        let probe = min(max(index, 0), ns.length - 1)
        let lineRange = ns.lineRange(for: NSRange(location: probe, length: 0))
        let lineText = ns.substring(with: lineRange)
        let lineNS = lineText as NSString

        guard let match = Self.checklistDisplayRegex.firstMatch(
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

    // 4. 文本状态切换 toggle 逻辑
    @MainActor
    func toggleChecklist(in lineRange: NSRange, to isChecked: Bool) {
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

    /// 处理 Checkbox 的回车续行与自动清空逻辑
    /// - Returns: Bool - 若成功拦截并处理了 Checkbox 回车逻辑则返回 true，否则返回 false
    @MainActor
    func handleCheckboxNewline(in lineText: String, lineRange: NSRange, selectedRange: NSRange, textView: NSTextView) -> Bool {
        // 使用正则匹配任务列表
        guard let checklistMatch = try? NSRegularExpression(pattern: "^(\\s*[-*+]\\s+\\[[ xX]\\]\\s*)(.*)$")
            .firstMatch(in: lineText, range: NSRange(location: 0, length: (lineText as NSString).length)) else {
            return false
        }
        
        let indentAndPrefix = (lineText as NSString).substring(with: checklistMatch.range(at: 1))
        let content = (lineText as NSString).substring(with: checklistMatch.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)

        // 场景 A：如果本行任务列表无内容，再按回车则取消任务列表格式（清空该行）
        if content.isEmpty {
            if textView.shouldChangeText(in: lineRange, replacementString: "") {
                textView.textStorage?.replaceCharacters(in: lineRange, with: "")
                textView.didChangeText()
                return true
            }
        } else {
            // 场景 B：提取缩进，自动在新行补全未勾选的 `- [ ] `
            let leadingSpaces = indentAndPrefix.prefix { $0 == " " || $0 == "\t" }
            let autoInsertText = "\n\(leadingSpaces)- [ ] "
            if textView.shouldChangeText(in: selectedRange, replacementString: autoInsertText) {
                textView.insertText(autoInsertText, replacementRange: selectedRange)
                textView.didChangeText()
                return true
            }
        }
        
        return false
    }
    
    /// 处理 Checklist 段落的绘制转换
    func processChecklistParagraph(
        _ paragraph: NSAttributedString,
        range: NSRange,
        nsString: NSString
    ) -> NSTextParagraph? {
        let fullRange = NSRange(location: 0, length: nsString.length)
        
        // 修复 1：将 Coordinator 改为 Self
        guard let match = Self.checklistDisplayRegex.firstMatch(in: paragraph.string, range: fullRange) else {
            return nil
        }

        let markerRange = match.range(at: 1)
        guard markerRange.length >= 1 else { return nil }
        let checkChar = nsString.substring(with: match.range(at: 2))
        let isChecked = checkChar.lowercased() == "x"

        let display = NSMutableAttributedString(attributedString: paragraph)
        let bodyFont = MarkdownTextView.resolvedFont(for: parent.fontName)
        let attachment = checkboxAttachment(isChecked: isChecked, font: bodyFont)

        let firstCharRange = NSRange(location: markerRange.location, length: 1)
        var firstAttrs = paragraph.attributes(at: firstCharRange.location, effectiveRange: nil)
        
        // 修复 2：显式指定 NSAttributedString.Key 的完整属性类型
        firstAttrs[.attachment] = attachment
        firstAttrs[.foregroundColor] = NSColor.clear
        firstAttrs[.font] = bodyFont
        
        display.replaceCharacters(in: firstCharRange, with: NSAttributedString(string: "\u{FFFC}", attributes: firstAttrs))

        if markerRange.length > 1 {
            let hideRange = NSRange(location: markerRange.location + 1, length: markerRange.length - 1)
            display.addAttributes([
                NSAttributedString.Key.foregroundColor: NSColor.clear,
                NSAttributedString.Key.font: NSFont.systemFont(ofSize: 1)
            ], range: hideRange)
        }
        return NSTextParagraph(attributedString: display)
    }
    
}
