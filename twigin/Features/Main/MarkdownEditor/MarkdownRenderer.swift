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

    /// Keyed by lineRange.location — reuses the same NSTextAttachment object across
    /// incremental renders so NSTextLayoutManager can skip ViewProvider re-instantiation.
    private var checkboxCache: [Int: CheckboxAttachment] = [:]

    var bodyFontName: String = ""
    var lineSpacingMultiplier: CGFloat = 0

    private func bodyFont(size: CGFloat = 14) -> NSFont {
        if !bodyFontName.isEmpty, let font = NSFont(name: bodyFontName, size: size) { return font }
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

    // MARK: - Shared Helpers (used by both render paths)

    private func computeAffected(_ blocks: [MarkdownBlock], editedRange: NSRange?) -> [MarkdownBlock] {
        guard let edited = editedRange else { return blocks }
        return blocks.filter { lineRange(of: $0).overlaps(edited) }
    }

    private func computeApplyRange(_ affected: [MarkdownBlock], storageLen: Int) -> NSRange? {
        let union = affected.map { lineRange(of: $0) }
            .reduce(nil as NSRange?) { acc, r in acc.map { NSUnionRange($0, r) } ?? r }
        guard let u = union else { return nil }
        let hi = min(NSMaxRange(u), storageLen)
        guard hi >= u.location else { return nil }
        return NSRange(location: u.location, length: hi - u.location)
    }

    private func applyRaw(
        affected: [MarkdownBlock],
        applyRange: NSRange,
        to storage: NSMutableAttributedString,
        theme: AppTheme,
        context: MarkdownRenderContext
    ) {
        storage.setAttributes(baseAttributes(theme: theme), range: applyRange)
        for block in affected {
            applyBlock(block, to: storage, theme: theme, context: context)
        }
    }

    // MARK: - render(): for full/theme/note-switch renders (outside processEditing cycle)

    func render(_ context: MarkdownRenderContext) {
        guard let textStorage = context.textView.textStorage else { return }
        let storageLen = textStorage.length
        guard storageLen > 0 else { return }

        let newBlocks = context.document.blocks
        if context.editedRange == nil {
            let liveKeys = Set(newBlocks.compactMap { checkboxKey($0) })
            checkboxCache = checkboxCache.filter { liveKeys.contains($0.key) }
        }

        let affected = computeAffected(newBlocks, editedRange: context.editedRange)
        guard !affected.isEmpty,
              let applyRange = computeApplyRange(affected, storageLen: storageLen) else { return }

        textStorage.beginEditing()
        applyRaw(affected: affected, applyRange: applyRange, to: textStorage, theme: context.theme, context: context)
        textStorage.endEditing()
    }

    // MARK: - renderInProcessingCycle(): called from NSTextStorageDelegate.willProcessEditing
    //
    // Runs INSIDE the textStorage.processEditing() cycle — NO beginEditing/endEditing.
    // Attribute changes are merged with the text change into a single layout pass,
    // eliminating the two-draw-cycle jitter caused by calling render() in textDidChange.

    func renderInProcessingCycle(
        textStorage: NSTextStorage,
        document: MarkdownDocument,
        editedRange: NSRange,
        theme: AppTheme,
        textView: MarkdownNativeTextView,
        onToggleChecklist: @escaping (NSRange, Bool) -> Void,
        onTapImage: @escaping (String) -> Void
    ) {
        let storageLen = textStorage.length
        guard storageLen > 0 else { return }

        let affected = computeAffected(document.blocks, editedRange: editedRange)
        guard !affected.isEmpty,
              let applyRange = computeApplyRange(affected, storageLen: storageLen) else { return }

        let ctx = MarkdownRenderContext(
            textView: textView,
            theme: theme,
            document: document,
            editedRange: editedRange,
            onToggleChecklist: onToggleChecklist,
            onTapImage: onTapImage
        )
        // Attribute changes here are part of the current processEditing cycle
        applyRaw(affected: affected, applyRange: applyRange, to: textStorage, theme: theme, context: ctx)
    }

    // MARK: - Block Range Helpers

    private func lineRange(of block: MarkdownBlock) -> NSRange {
        switch block {
        case let .heading(_, _, _, r): return r
        case let .paragraph(r, _): return r
        case let .checklist(_, _, _, r, _): return r
        case let .image(_, _, r): return r
        case let .bulletList(_, _, r, _): return r
        case let .orderedList(_, _, _, r, _): return r
        case let .blockquote(_, _, r, _): return r
        }
    }

    private func checkboxKey(_ block: MarkdownBlock) -> Int? {
        guard case let .checklist(_, _, _, r, _) = block else { return nil }
        return r.location
    }

    // MARK: - Block Dispatch
    // NSTextStorage IS NSMutableAttributedString — no parameter type changes required.

    private func applyBlock(_ block: MarkdownBlock, to attributed: NSMutableAttributedString, theme: AppTheme, context: MarkdownRenderContext) {
        switch block {
        case let .heading(level, markerRange, contentRange, lineRange):
            applyHeading(level: level, markerRange: markerRange, contentRange: contentRange, lineRange: lineRange, to: attributed, theme: theme)

        case let .paragraph(lineRange, inlines):
            applyParagraph(lineRange: lineRange, inlines: inlines, to: attributed, theme: theme)

        case let .checklist(marker, markerRange, contentRange, lineRange, inlines):
            applyChecklist(marker: marker, markerRange: markerRange, contentRange: contentRange, lineRange: lineRange, inlines: inlines, to: attributed, theme: theme, context: context)

        case let .image(_, path, lineRange):
            applyImageLine(path: path, lineRange: lineRange, to: attributed, theme: theme)

        case let .bulletList(markerRange, contentRange, lineRange, inlines):
            applyListBlock(markerRange: markerRange, contentRange: contentRange, lineRange: lineRange, inlines: inlines, to: attributed, theme: theme, indent: 20)

        case let .orderedList(_, markerRange, contentRange, lineRange, inlines):
            applyListBlock(markerRange: markerRange, contentRange: contentRange, lineRange: lineRange, inlines: inlines, to: attributed, theme: theme, indent: 24)

        case let .blockquote(markerRange, contentRange, lineRange, inlines):
            applyBlockquote(markerRange: markerRange, contentRange: contentRange, lineRange: lineRange, inlines: inlines, to: attributed, theme: theme)
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

    // CHANGED: reuses cached CheckboxAttachment by lineRange.location + isChecked state.
    // If the same attachment object is set on the storage, NSTextLayoutManager skips ViewProvider
    // re-instantiation, eliminating the checkbox flicker on every keystroke.
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

        let isChecked = (marker == .checked)
        let cacheKey = lineRange.location

        let attachment: CheckboxAttachment
        if let cached = checkboxCache[cacheKey], cached.isChecked == isChecked {
            // Reuse same object — ViewProvider is NOT recreated by TextKit 2
            cached.onToggle = context.onToggleChecklist
            attachment = cached
        } else {
            attachment = CheckboxAttachment(
                range: lineRange,
                isChecked: isChecked,
                onToggle: context.onToggleChecklist
            )
            checkboxCache[cacheKey] = attachment
        }

        attributed.addAttribute(.attachment, value: attachment,
                                range: NSRange(location: markerTextRange.location, length: 1))

        if markerTextRange.length > 1 {
            let remainRange = NSRange(location: markerTextRange.location + 1,
                                      length: markerTextRange.length - 1)
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
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= attributed.length else { return nil }
        return range
    }
}

// MARK: - NSRange overlap for block filtering

private extension NSRange {
    /// True when the two ranges share at least one character position.
    /// Uses `<=` to correctly handle zero-length (point) ranges produced by deletions:
    /// a point P overlaps any range [lo, hi] where lo <= P <= hi.
    func overlaps(_ other: NSRange) -> Bool {
        max(location, other.location) <= min(NSMaxRange(self), NSMaxRange(other))
    }
}
