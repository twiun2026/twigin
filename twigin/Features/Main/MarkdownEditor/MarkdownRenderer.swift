import AppKit
import Foundation
import SwiftUI

struct MarkdownRenderContext {
    let textView: MarkdownNativeTextView
    let theme: AppTheme
    let document: MarkdownDocument
    let onToggleChecklist: (NSRange, Bool) -> Void
    let onTapImage: (String) -> Void
}

final class MarkdownRenderer {
    var bodyFontName: String = ""
    var lineSpacingMultiplier: CGFloat = 0

    private let attributesToClear: [NSAttributedString.Key] = [
        .foregroundColor,
        .backgroundColor,
        .font,
        .paragraphStyle,
        .strikethroughStyle,
        .strikethroughColor,
        .underlineStyle,
        .underlineColor,
        .link,
        .attachment
    ]

    private func bodyFont(size: CGFloat = 14) -> NSFont {
        if !bodyFontName.isEmpty, let font = NSFont(name: bodyFontName, size: size) {
            return font
        }
        return NSFont.systemFont(ofSize: size, weight: .regular)
    }

    private func applySpacing(to paragraph: NSMutableParagraphStyle, default defaultSpacing: CGFloat) {
        if lineSpacingMultiplier > 0 {
            paragraph.lineHeightMultiple = lineSpacingMultiplier
        } else {
            paragraph.lineSpacing = defaultSpacing
        }
    }

    private func baseAttributes(theme: AppTheme) -> [NSAttributedString.Key: Any] {
        [
            .foregroundColor: NSColor(theme.textMain),
            .font: bodyFont()
        ]
    }

    init() {
        NSTextAttachment.registerViewProviderClass(
            MarkdownImageAttachmentViewProvider.self,
            forFileType: MarkdownAttachmentType.imageUTI
        )
    }

    func render(_ context: MarkdownRenderContext) {
        guard let textStorage = context.textView.textStorage else { return }
        let storageLength = textStorage.length
        guard storageLength > 0 else { return }

        let renderPlan = makeRenderPlan(document: context.document, storageLength: storageLength)
        guard !renderPlan.ranges.isEmpty else { return }

        textStorage.beginEditing()
        for range in renderPlan.ranges {
            clearAttributes(in: range, storage: textStorage)
            textStorage.addAttributes(baseAttributes(theme: context.theme), range: range)
        }
        for block in renderPlan.blocks {
            applyBlock(block, to: textStorage, theme: context.theme, context: context)
        }
        textStorage.endEditing()

        invalidateLayout(in: context.textView, affectedRanges: renderPlan.ranges)
    }

    private struct RenderPlan {
        var ranges: [NSRange]
        var blocks: [MarkdownBlock]
    }

    private func makeRenderPlan(document: MarkdownDocument, storageLength: Int) -> RenderPlan {
        if let blockDiff = document.blockDiff, !blockDiff.isEmpty {
            var ranges: [NSRange] = []
            var blocks: [MarkdownBlock] = []

            for operation in blockDiff.operations {
                switch operation {
                case let .insert(block):
                    ranges.append(clamp(range: block.lineRange, storageLength: storageLength))
                    blocks.append(block)
                case let .modify(_, new):
                    ranges.append(clamp(range: new.lineRange, storageLength: storageLength))
                    blocks.append(new)
                case let .delete(block):
                    ranges.append(clamp(range: block.lineRange, storageLength: storageLength))
                }
            }

            return RenderPlan(ranges: mergeRanges(ranges), blocks: blocks)
        }

        let applyRange = clampedApplyRange(for: document, storageLength: storageLength)
        let affectedBlocks = document.blocks.filter { $0.lineRange.overlaps(applyRange) }
        return RenderPlan(ranges: applyRange.length > 0 ? [applyRange] : [], blocks: affectedBlocks)
    }

    private func clampedApplyRange(for document: MarkdownDocument, storageLength: Int) -> NSRange {
        let raw = document.affectedRange ?? NSRange(location: 0, length: storageLength)
        let lowerBound = min(max(raw.location, 0), storageLength)
        let upperBound = min(max(NSMaxRange(raw), lowerBound), storageLength)
        return NSRange(location: lowerBound, length: upperBound - lowerBound)
    }

    private func clearAttributes(in range: NSRange, storage: NSTextStorage) {
        guard range.length > 0 else { return }
        for key in attributesToClear {
            storage.removeAttribute(key, range: range)
        }
    }

    private func invalidateLayout(in textView: MarkdownNativeTextView, affectedRanges: [NSRange]) {
        guard let textLayoutManager = textView.textLayoutManager,
              let textContentManager = textLayoutManager.textContentManager else {
            return
        }

        guard !affectedRanges.isEmpty else { return }
        let documentRange = textContentManager.documentRange

        for affectedRange in affectedRanges {
            guard affectedRange.length > 0,
                  let start = textContentManager.location(documentRange.location, offsetBy: affectedRange.location),
                  let end = textContentManager.location(start, offsetBy: affectedRange.length),
                  let textRange = NSTextRange(location: start, end: end) else {
                continue
            }

            textLayoutManager.invalidateLayout(for: textRange)
        }

        // AppKit/TextKit2 边界 bug：当失效子范围的起点恰为 documentRange.location（偏移 0），
        // invalidateLayout 不会把首个 layout fragment 标脏，viewport 复用旧几何，导致首行属性
        // 变更（如 # 标题）不刷新——这正是“第一行不渲染、第二行正常”的根因。首行受影响时，
        // 补一次整篇 documentRange 失效兜底（仅标脏，viewport 仍按需惰性布局，不遍历全文）。
        if affectedRanges.contains(where: { $0.location == 0 }) {
            textLayoutManager.invalidateLayout(for: documentRange)
        }

        // needsDisplay 只重绘既有 fragment 视图、不会重建；必须 needsLayout 触发 viewport
        // 布局控制器重新生成 fragment，属性/字号变更才会真正反映到屏幕。
        textView.needsLayout = true
        textView.needsDisplay = true
    }

    private func mergeRanges(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.filter { $0.length > 0 }.sorted { lhs, rhs in
            if lhs.location == rhs.location {
                return lhs.length < rhs.length
            }
            return lhs.location < rhs.location
        }

        guard !sorted.isEmpty else { return [] }

        var merged: [NSRange] = [sorted[0]]
        for range in sorted.dropFirst() {
            guard let last = merged.last else { continue }
            if NSMaxRange(last) >= range.location {
                let union = NSUnionRange(last, range)
                merged[merged.count - 1] = union
            } else {
                merged.append(range)
            }
        }

        return merged
    }

    private func clamp(range: NSRange, storageLength: Int) -> NSRange {
        let lowerBound = min(max(range.location, 0), storageLength)
        let upperBound = min(max(NSMaxRange(range), lowerBound), storageLength)
        return NSRange(location: lowerBound, length: upperBound - lowerBound)
    }

    private func applyBlock(_ block: MarkdownBlock, to attributed: NSMutableAttributedString, theme: AppTheme, context: MarkdownRenderContext) {
        switch block.kind {
        case let .heading(level):
            guard let markerRange = block.markerRange,
                  let contentRange = block.contentRange else { return }
            applyHeading(level: level, markerRange: markerRange, contentRange: contentRange, lineRange: block.lineRange, to: attributed, theme: theme)

        case .paragraph:
            applyParagraph(lineRange: block.lineRange, inlines: block.inlines, to: attributed, theme: theme)

        case let .checklist(marker):
            guard let markerRange = block.markerRange,
                  let contentRange = block.contentRange else { return }
            applyChecklist(marker: marker, markerRange: markerRange, contentRange: contentRange, lineRange: block.lineRange, inlines: block.inlines, to: attributed, theme: theme, context: context)

        case let .image(_, path):
            applyImageLine(path: path, lineRange: block.lineRange, to: attributed, theme: theme)

        case .bulletList:
            guard let markerRange = block.markerRange,
                  let contentRange = block.contentRange else { return }
            applyListBlock(markerRange: markerRange, contentRange: contentRange, lineRange: block.lineRange, inlines: block.inlines, to: attributed, theme: theme, indent: 20)

        case .orderedList:
            guard let markerRange = block.markerRange,
                  let contentRange = block.contentRange else { return }
            applyListBlock(markerRange: markerRange, contentRange: contentRange, lineRange: block.lineRange, inlines: block.inlines, to: attributed, theme: theme, indent: 24)

        case .blockquote:
            guard let markerRange = block.markerRange,
                  let contentRange = block.contentRange else { return }
            applyBlockquote(markerRange: markerRange, contentRange: contentRange, lineRange: block.lineRange, inlines: block.inlines, to: attributed, theme: theme)

        case .codeBlock:
            applyCodeBlock(lineRange: block.lineRange, to: attributed, theme: theme)
        case .footnote(label: _):
            guard let markerRange = block.markerRange,
                  let contentRange = block.contentRange else { return }
            attributed.addAttributes([
                .foregroundColor: NSColor(theme.textSecondary)
            ], range: markerRange)
            applyInline(block.inlines, to: attributed, theme: theme)
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
            .font: bodyFont()
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
        applySpacing(to: paragraph, default: 2)
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

        attributed.addAttributes([
            .foregroundColor: NSColor(theme.textMuted),
            .font: NSFont.systemFont(ofSize: 14, weight: .regular)
        ], range: marker)

        attributed.addAttributes([
            .foregroundColor: NSColor(theme.textHeader),
            .font: NSFont.systemFont(ofSize: headingSize(for: level), weight: .bold)
        ], range: content)

        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 6
        applySpacing(to: paragraph, default: 2)
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: line)
    }

    private func applyParagraph(
        lineRange: NSRange,
        inlines: [MarkdownInline],
        to attributed: NSMutableAttributedString,
        theme: AppTheme
    ) {
        guard let line = safeRange(lineRange, in: attributed) else { return }

        attributed.addAttribute(.font, value: bodyFont(), range: line)

        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 4
        applySpacing(to: paragraph, default: 2)
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

        // 标记（- [ ] / - [x]）在 backing 上先隐藏；显示层由 content-storage 委托把首字符
        // 替换为复选框图片附件（见 MarkdownEditorView.Coordinator）。
        attributed.addAttributes([
            .foregroundColor: NSColor.clear,
            .font: NSFont.systemFont(ofSize: 1)
        ], range: markerTextRange)

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
        applySpacing(to: paragraph, default: 1)
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
            .font: bodyFont()
        ], range: content)

        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 0
        paragraph.headIndent = indent
        paragraph.paragraphSpacing = 3
        applySpacing(to: paragraph, default: 1)
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: line)

        applyInline(inlines, to: attributed, theme: theme)
    }

    private func applyCodeBlock(
        lineRange: NSRange,
        to attributed: NSMutableAttributedString,
        theme: AppTheme
    ) {
        guard let line = safeRange(lineRange, in: attributed) else { return }

        attributed.addAttributes([
            .foregroundColor: NSColor(theme.textSecondary),
            .font: NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular),
            .backgroundColor: NSColor(theme.bgCitation)
        ], range: line)

        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 4
        applySpacing(to: paragraph, default: 1)
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: line)
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

            switch inline.kind {
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
            case .footnote:
                attributed.addAttributes([
                    .foregroundColor: NSColor(theme.textMain),
                    .superscript: 1
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
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= attributed.length else { return nil }
        return range
    }
}

private extension NSRange {
    func overlaps(_ other: NSRange) -> Bool {
        max(location, other.location) <= min(NSMaxRange(self), NSMaxRange(other))
    }
}
