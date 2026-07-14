import AppKit
import Foundation
import SwiftUI

struct MarkdownRenderContext {
    let textView: MarkdownNativeTextView
    let theme: AppTheme
    let document: MarkdownDocument
    let editedRange: NSRange?
    let onToggleChecklist: (NSRange, Bool) -> Void
    let onTapImage: (String) -> Void
}

final class MarkdownRenderer {
    private let parser = MarkdownParser()

    private func baseAttributes(theme: AppTheme) -> [NSAttributedString.Key: Any] {
        [
            .foregroundColor: NSColor(theme.textMain),
            .font: NSFont.systemFont(ofSize: 14, weight: .regular)
        ]
    }

    init() {
        NSTextAttachment.registerViewProviderClass(
            CheckboxAttachmentViewProvider.self,
            forFileType: MarkdownAttachmentType.checkboxUTI
        )
        NSTextAttachment.registerViewProviderClass(
            MarkdownImageAttachmentViewProvider.self,
            forFileType: MarkdownAttachmentType.imageUTI
        )
    }

    func parse(source: String) -> MarkdownDocument {
        parser.parse(source)
    }

    func render(_ context: MarkdownRenderContext) {
        guard let textStorage = context.textView.textStorage else { return }

        let source = context.textView.string
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        let selected = context.textView.selectedRanges

        let mutable = NSMutableAttributedString(string: source)
        mutable.setAttributes(baseAttributes(theme: context.theme), range: fullRange)

        for block in context.document.blocks {
            applyBlock(block, to: mutable, theme: context.theme, context: context)
        }

        textStorage.beginEditing()
        textStorage.setAttributedString(mutable)
        textStorage.endEditing()

        context.textView.selectedRanges = selected
    }

    private func applyBlock(_ block: MarkdownBlock, to attributed: NSMutableAttributedString, theme: AppTheme, context: MarkdownRenderContext) {
        switch block {
        case let .heading(level, markerRange, contentRange, lineRange):
            applyHeading(
                level: level,
                markerRange: markerRange,
                contentRange: contentRange,
                lineRange: lineRange,
                to: attributed,
                theme: theme
            )

        case let .paragraph(lineRange, inlines):
            applyParagraph(lineRange: lineRange, inlines: inlines, to: attributed, theme: theme)

        case let .checklist(marker, markerRange, contentRange, lineRange, inlines):
            applyChecklist(
                marker: marker,
                markerRange: markerRange,
                contentRange: contentRange,
                lineRange: lineRange,
                inlines: inlines,
                to: attributed,
                theme: theme,
                context: context
            )

        case let .image(_, path, lineRange):
            applyImageLine(path: path, lineRange: lineRange, to: attributed, theme: theme)
            
        case let .bulletList(markerRange, contentRange, lineRange, inlines):
            applyListBlock(
                markerRange: markerRange,
                contentRange: contentRange,
                lineRange: lineRange,
                inlines: inlines,
                to: attributed,
                theme: theme,
                indent: 20 // 无序列表缩进距离
            )

        case let .orderedList(_, markerRange, contentRange, lineRange, inlines):
            applyListBlock(
                markerRange: markerRange,
                contentRange: contentRange,
                lineRange: lineRange,
                inlines: inlines,
                to: attributed,
                theme: theme,
                indent: 24 // 有序列表由于含有数字，缩进略微设宽一些
            )
            
        case let .blockquote(markerRange, contentRange, lineRange, inlines):
            applyBlockquote(
                markerRange: markerRange,
                contentRange: contentRange,
                lineRange: lineRange,
                inlines: inlines,
                to: attributed,
                theme: theme
            )
        }
    }

    private func applyBlockquote(
        markerRange: NSRange,
        contentRange: NSRange,
        lineRange: NSRange,
        inlines: [MarkdownInline],
        to attributed: NSMutableAttributedString,
        theme: AppTheme
    ) {
        guard let marker = safeRange(markerRange, in: attributed),
              let content = safeRange(contentRange, in: attributed),
              let line = safeRange(lineRange, in: attributed) else { return }

        attributed.addAttributes([
            .foregroundColor: NSColor(theme.textMuted),
            .font: NSFont.systemFont(ofSize: 14, weight: .regular)
        ], range: marker)

        attributed.addAttributes([
            .foregroundColor: NSColor(theme.textCitation),
            .font: NSFont.systemFont(ofSize: 14, weight: .regular)
        ], range: content)

        let paragraph = NSMutableParagraphStyle()
        
        let textBlock = NSTextBlock()
        textBlock.backgroundColor = NSColor(theme.bgCitation)
        // 8 points inner padding on all edges
        textBlock.setWidth(8, type: .absoluteValueType, for: .padding)
        // Indent the block itself from the paragraph edges
        textBlock.setWidth(16, type: .absoluteValueType, for: .margin, edge: .minX)
        textBlock.setWidth(16, type: .absoluteValueType, for: .margin, edge: .maxX)
        // Set width to 100% so it doesn't collapse
        textBlock.setContentWidth(100, type: .percentageValueType)
        
        paragraph.textBlocks = [textBlock]
        paragraph.paragraphSpacing = 4
        paragraph.lineSpacing = 2
        
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: line)

        applyInline(inlines, to: attributed, theme: theme)
    }

    private func applyHeading(
        level: Int,
        markerRange: NSRange,
        contentRange: NSRange,
        lineRange: NSRange,
        to attributed: NSMutableAttributedString,
        theme: AppTheme
    ) {
        guard let marker = safeRange(markerRange, in: attributed),
              let content = safeRange(contentRange, in: attributed),
              let line = safeRange(lineRange, in: attributed) else { return }

        let size = headingSize(for: level)
        attributed.addAttributes([
            .foregroundColor: NSColor(theme.textMuted),
            .font: NSFont.systemFont(ofSize: 14, weight: .regular)
        ], range: marker)

        attributed.addAttributes([
            .foregroundColor: NSColor(theme.textHeader),
            .font: NSFont.systemFont(ofSize: size, weight: .bold)
        ], range: content)

        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 6
        paragraph.lineSpacing = 2
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: line)
    }

    private func applyParagraph(
        lineRange: NSRange,
        inlines: [MarkdownInline],
        to attributed: NSMutableAttributedString,
        theme: AppTheme
    ) {
        guard let line = safeRange(lineRange, in: attributed) else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 4
        paragraph.lineSpacing = 2
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: line)

        applyInline(inlines, to: attributed, theme: theme)
    }

    private func applyChecklist(
        marker: ChecklistMarker,
        markerRange: NSRange,
        contentRange: NSRange,
        lineRange: NSRange,
        inlines: [MarkdownInline],
        to attributed: NSMutableAttributedString,
        theme: AppTheme,
        context: MarkdownRenderContext
        
    ) {
        guard let markerTextRange = safeRange(markerRange, in: attributed),
              let content = safeRange(contentRange, in: attributed),
              let line = safeRange(lineRange, in: attributed) else { return }

        attributed.addAttributes([
            .foregroundColor: NSColor(theme.textMuted),
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        ], range: markerTextRange)
        
        // 1. 创建原生的 Checkbox 附件（解决问题 3）
        let isChecked = (marker == .checked)
        let attachment = CheckboxAttachment(range: lineRange, isChecked: isChecked) { targetRange, checked in
            context.onToggleChecklist(targetRange, checked)
        }
        // 2. 将 Attachment 转为富文本属性
        let attachmentString = NSAttributedString(attachment: attachment)
        
        // 3. 用 Attachment 替换掉原本的 "- [ ]" 或 "- [x]" 文本从而实现可点击
        // 注意：直接 replace 改变长度会破坏后续 block 的 range。
        // 最优雅的办法是不改变长度，把 attachment 属性直接赋予 marker 区域的第一个字符，并将其他字符隐藏或用空白代替
        // 或者直接赋予整个 markerTextRange 区域：
        attributed.addAttribute(.attachment, value: attachment, range: NSRange(location: markerTextRange.location, length: 1))
        
        // 将 marker 区域剩余的字符清空或虚化，避免文字和 checkbox 重叠
        if markerTextRange.length > 1 {
            let remainRange = NSRange(location: markerTextRange.location + 1, length: markerTextRange.length - 1)
            attributed.addAttributes([
                .foregroundColor: NSColor.clear,
                .font: NSFont.systemFont(ofSize: 1)
            ], range: remainRange)
        }

        var contentAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(theme.textMain),
            .font: NSFont.systemFont(ofSize: 14, weight: .regular)
        ]

        if marker == .checked {
            contentAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            contentAttributes[.strikethroughColor] = NSColor(theme.textMuted)
            contentAttributes[.foregroundColor] = NSColor(theme.textMuted)
        }

        attributed.addAttributes(contentAttributes, range: content)

        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = 24
        paragraph.paragraphSpacing = 3
        paragraph.lineSpacing = 1
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: line)

        applyInline(inlines, to: attributed, theme: theme)
    }

    private func applyImageLine(
        path: String,
        lineRange: NSRange,
        to attributed: NSMutableAttributedString,
        theme: AppTheme
    ) {
        guard let line = safeRange(lineRange, in: attributed) else { return }

        attributed.addAttributes([
            .foregroundColor: NSColor(theme.textCitation),
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor(theme.borderLine),
            .link: path
        ], range: line)

        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 6
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: line)
    }

    private func applyListBlock(
            markerRange: NSRange,
            contentRange: NSRange,
            lineRange: NSRange,
            inlines: [MarkdownInline],
            to attributed: NSMutableAttributedString,
            theme: AppTheme,
            indent: CGFloat
        ) {
            guard let marker = safeRange(markerRange, in: attributed),
                  let content = safeRange(contentRange, in: attributed),
                  let line = safeRange(lineRange, in: attributed) else { return }

            attributed.addAttributes([
                .foregroundColor: NSColor(theme.textMuted),
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            ], range: marker)

            attributed.addAttributes([
                .foregroundColor: NSColor(theme.textMain),
                .font: NSFont.systemFont(ofSize: 14, weight: .regular)
            ], range: content)

            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = 0
            paragraph.headIndent = indent
            paragraph.paragraphSpacing = 3
            paragraph.lineSpacing = 1
            attributed.addAttribute(.paragraphStyle, value: paragraph, range: line)

            applyInline(inlines, to: attributed, theme: theme)
        }
    
    private func applyInline(_ inlines: [MarkdownInline], to attributed: NSMutableAttributedString, theme: AppTheme) {
        for inline in inlines {
            let markers = inline.markerRanges.compactMap { safeRange($0, in: attributed) }
            for markerRange in markers {
                attributed.addAttributes([
                    .foregroundColor: NSColor(theme.textMuted),
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                ], range: markerRange)
            }

            guard let contentRange = safeRange(inline.contentRange, in: attributed) else { continue }

            switch inline {
            case .bold:
                attributed.addAttributes([
                    .foregroundColor: NSColor(theme.textMain),
                    .font: NSFont.systemFont(ofSize: 14, weight: .bold)
                ], range: contentRange)

            case .italic:
                attributed.addAttributes([
                    .foregroundColor: NSColor(theme.textItalic),
                    .font: NSFontManager.shared.convert(
                        NSFont.systemFont(ofSize: 14, weight: .regular),
                        toHaveTrait: .italicFontMask
                    )
                ], range: contentRange)

            case .strike:
                attributed.addAttributes([
                    .foregroundColor: NSColor(theme.textMuted),
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: NSColor(theme.textMuted)
                ], range: contentRange)

            case .code:
                attributed.addAttributes([
                    .foregroundColor: NSColor(theme.textSecondary),
                    .font: NSFont.monospacedSystemFont(ofSize: 13.5, weight: .medium),
                    .backgroundColor: NSColor(theme.bgCitation)
                ], range: contentRange)
            case .highlight:
                attributed.addAttributes([
                    .foregroundColor: NSColor(theme.textMain),
                    .backgroundColor: NSColor(theme.markerA)
                ], range: contentRange)
            }
        }
    }

    private func headingSize(for level: Int) -> CGFloat {
        switch level {
        case 1: return 28
        case 2: return 24
        case 3: return 20
        case 4: return 18
        case 5: return 16
        default: return 15
        }
    }

    private func safeRange(_ range: NSRange, in attributed: NSAttributedString) -> NSRange? {
        let length = attributed.length
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= length else {
            return nil
        }
        return range
    }
}
