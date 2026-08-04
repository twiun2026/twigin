import AppKit
import Foundation
import SwiftUI

struct MarkdownRenderContext {
    let textView: MarkdownNativeTextView
    let theme: AppTheme
    let document: MarkdownDocument
    let selectedRange: NSRange?
    let onToggleChecklist: (NSRange, Bool) -> Void
    let onTapImage: (String) -> Void
}

@MainActor
final class MarkdownRenderer {
    var bodyFontName: String = ""
    var lineSpacingMultiplier: CGFloat = 0
    var baseFontSize: CGFloat = 14

    private let attributesToClear: [NSAttributedString.Key] = [
        .foregroundColor,
        .backgroundColor,
        .font,
        .strikethroughStyle,
        .strikethroughColor,
        .underlineStyle,
        .underlineColor,
        .link,
        .attachment,
        .paragraphStyle
    ]

    func bodyFont(size: CGFloat? = nil) -> NSFont {
        let s = size ?? baseFontSize
        if !bodyFontName.isEmpty, let font = NSFont(name: bodyFontName, size: s) {
            return font
        }
        return NSFont.systemFont(ofSize: s, weight: .regular)
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
            .font: bodyFont(),
            .paragraphStyle: NSParagraphStyle.default
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

        if storageLength == 0 {
            if let tlm = context.textView.textLayoutManager,
               let cm = tlm.textContentManager {
                tlm.invalidateLayout(for: cm.documentRange)
            }
            context.textView.needsDisplay = true
            return
        }

        let text = textStorage.string as NSString
        let renderPlan = makeRenderPlan(document: context.document, storageLength: storageLength, text: text)
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

    private func paragraphEnd(after pos: Int, in text: NSString, upTo limit: Int) -> Int {
        guard pos < limit else { return limit }
        let paraRange = text.paragraphRange(for: NSRange(location: pos, length: 0))
        return min(NSMaxRange(paraRange), limit)
    }

    private func makeRenderPlan(document: MarkdownDocument, storageLength: Int, text: NSString? = nil) -> RenderPlan {
        if let blockDiff = document.blockDiff, !blockDiff.isEmpty {
            var ranges: [NSRange] = []
            var diffBlocks: [MarkdownBlock] = []

            for operation in blockDiff.operations {
                switch operation {
                case let .insert(block):
                    ranges.append(clamp(range: block.lineRange, storageLength: storageLength))
                    diffBlocks.append(block)
                case let .modify(_, new):
                    ranges.append(clamp(range: new.lineRange, storageLength: storageLength))
                    diffBlocks.append(new)
                case let .delete(block):
                    ranges.append(clamp(range: block.lineRange, storageLength: storageLength))
                }
            }

            if let affected = document.affectedRange {
                ranges.append(clamp(range: affected, storageLength: storageLength))
            }
    
            let extendedRanges = ranges.map { r -> NSRange in
                let loc = r.location
                let end = NSMaxRange(r)
                let nextParaEnd: Int
                if let text = text {
                    nextParaEnd = paragraphEnd(after: end, in: text, upTo: storageLength)
                } else {
                    nextParaEnd = min(end + 2, storageLength)
                }
                return NSRange(location: loc, length: max(nextParaEnd - loc, r.length))
            }

            let mergedRanges = mergeRanges(extendedRanges)
            let latestMaterializedBlocks = document.blocks
            
            var allAffectedBlocks = diffBlocks
            for range in mergedRanges {
                let overlappingBlocks = latestMaterializedBlocks.filter { $0.lineRange.overlaps(range) }
                for block in overlappingBlocks {
                    if !allAffectedBlocks.contains(where: { $0.id == block.id }) {
                        allAffectedBlocks.append(block)
                    }
                }
            }

            return RenderPlan(ranges: mergedRanges, blocks: allAffectedBlocks)
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

    func invalidateLayout(in textView: MarkdownNativeTextView, affectedRanges: [NSRange]) {
        guard let textLayoutManager = textView.textLayoutManager,
              let textContentManager = textLayoutManager.textContentManager else {
            return
        }

        guard !affectedRanges.isEmpty else { return }
        let documentRange = textContentManager.documentRange
        let storageLength = (textView.string as NSString).length
        let text = textView.string as NSString

        for affectedRange in affectedRanges {
            guard affectedRange.length > 0 else { continue }
            let end = NSMaxRange(affectedRange)
            let nextParaEnd = paragraphEnd(after: end, in: text, upTo: storageLength)
            let safeLength = max(nextParaEnd - affectedRange.location, affectedRange.length)
            let safeRange = NSRange(location: affectedRange.location, length: safeLength)

            guard let start = textContentManager.location(documentRange.location, offsetBy: safeRange.location),
                  let endLoc = textContentManager.location(start, offsetBy: safeRange.length),
                  let textRange = NSTextRange(location: start, end: endLoc) else { continue }

            textLayoutManager.invalidateLayout(for: textRange)
        }

        if affectedRanges.contains(where: { $0.location == 0 }) {
            textLayoutManager.invalidateLayout(for: documentRange)
        }
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

    func shouldShowMarker(_ targetRange: NSRange, selectedRange: NSRange?) -> Bool {
        guard let selected = selectedRange else { return false }
        
        if selected.length > 0 {
            return false
        }
        
        let location = selected.location
        return location >= targetRange.location && location <= NSMaxRange(targetRange)
    }
    
    func applyBlock(_ block: MarkdownBlock, to attributed: NSMutableAttributedString, theme: AppTheme, context: MarkdownRenderContext) {
        switch block.kind {
        case let .heading(level):
            guard let markerRange = block.markerRange,
                  let contentRange = block.contentRange else { return }
            applyHeading(level: level, markerRange: markerRange, contentRange: contentRange, lineRange: block.lineRange, to: attributed, context: context, theme: theme)

        case .paragraph:
            applyParagraph(lineRange: block.lineRange, inlines: block.inlines, to: attributed, context: context, theme: theme)

        case let .checklist(marker):
            guard let markerRange = block.markerRange,
                  let contentRange = block.contentRange else { return }
            applyChecklist(marker: marker, markerRange: markerRange, contentRange: contentRange, lineRange: block.lineRange, inlines: block.inlines, to: attributed, theme: theme, context: context)

        case let .image(_, path):
            applyImageAttachment(path: path, lineRange: block.lineRange, to: attributed, theme: theme, context: context)

        case .bulletList:
            guard let markerRange = block.markerRange,
                  let contentRange = block.contentRange else { return }
            applyListBlock(markerRange: markerRange, contentRange: contentRange, lineRange: block.lineRange, inlines: block.inlines, to: attributed, context: context, theme: theme, indent: 20)

        case .orderedList:
            guard let markerRange = block.markerRange,
                  let contentRange = block.contentRange else { return }
            applyListBlock(markerRange: markerRange, contentRange: contentRange, lineRange: block.lineRange, inlines: block.inlines, to: attributed, context: context, theme: theme, indent: 24)

        case .blockquote:
            guard let markerRange = block.markerRange,
                  let contentRange = block.contentRange else { return }
            MarkdownBlockquote.apply(
                    markerRange: markerRange,
                    contentRange: contentRange,
                    lineRange: block.lineRange,
                    inlines: block.inlines,
                    to: attributed,
                    context: context,
                    theme: theme,
                    renderer: self
                )

        case .footnote(label: _):
            guard let markerRange = block.markerRange,
                  let _ = block.contentRange else { return }
            attributed.addAttributes([
                .foregroundColor: NSColor(theme.textSecondary)
            ], range: markerRange)
            applyInline(block.inlines, to: attributed, theme: theme, context: context)
        case .codeBlock:
            break
        }
    }

    private func applyHeading(
        level: Int,
        markerRange: NSRange,
        contentRange: NSRange,
        lineRange: NSRange,
        to attributed: NSMutableAttributedString,
        context: MarkdownRenderContext,
        theme: AppTheme
    ) {
        guard let content = safeRange(contentRange, in: attributed),
              let line = safeRange(lineRange, in: attributed) else { return }

        let fullMarkerRange: NSRange
        if markerRange.location < contentRange.location {
            let length = contentRange.location - markerRange.location
            fullMarkerRange = NSRange(location: markerRange.location, length: length)
        } else {
            fullMarkerRange = markerRange
        }

        guard let marker = safeRange(fullMarkerRange, in: attributed) else { return }

        let showMarker = shouldShowMarkerForHeading(lineRange: lineRange, selectedRange: context.selectedRange)
        
        let markerColor = showMarker ? NSColor(theme.textMuted) : NSColor.clear
        let markerFont = showMarker
            ? NSFont.systemFont(ofSize: headingSize(for: level), weight: .bold)
            : NSFont.systemFont(ofSize: 0.01)

        attributed.addAttributes([
            .foregroundColor: markerColor,
            .font: markerFont
        ], range: marker)

        attributed.addAttributes([
            .foregroundColor: NSColor(theme.textHeader),
            .font: NSFont.systemFont(ofSize: headingSize(for: level), weight: .bold)
        ], range: content)

        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 0
        paragraph.headIndent = 0
        paragraph.paragraphSpacing = 6
        applySpacing(to: paragraph, default: 2)
        applyParagraphStyle(paragraph, lineRange: line, to: attributed)
    }

    private func applyParagraph(
        lineRange: NSRange,
        inlines: [MarkdownInline],
        to attributed: NSMutableAttributedString,
        context: MarkdownRenderContext,
        theme: AppTheme
    ) {
        guard let line = safeRange(lineRange, in: attributed) else { return }

        attributed.addAttribute(.font, value: bodyFont(), range: line)

        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 4
        applySpacing(to: paragraph, default: 2)
        applyParagraphStyle(paragraph, lineRange: line, to: attributed)

        attributed.enumerateAttribute(.isAICitation, in: line, options: []) { value, range, _ in
            if let isAI = value as? Bool, isAI {
                attributed.addAttribute(.foregroundColor, value: NSColor(theme.textCitation), range: range)
            }
        }
        
        applyInline(inlines, to: attributed, theme: theme, context: context)
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
            .foregroundColor: NSColor.clear,
            .font: NSFont.systemFont(ofSize: 1)
        ], range: markerTextRange)

        var contentAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(theme.textMain),
            .font: NSFont.systemFont(ofSize: baseFontSize, weight: .regular)
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
        applyParagraphStyle(paragraph, lineRange: line, to: attributed)

        applyInline(inlines, to: attributed, theme: theme, context: context)
    }

    private func applyImageAttachment(
        path: String,
        lineRange: NSRange,
        to attributed: NSMutableAttributedString,
        theme: AppTheme,
        context: MarkdownRenderContext
    ) {
        guard let line = safeRange(lineRange, in: attributed) else { return }
        
        attributed.enumerateAttribute(.attachment, in: line, options: []) { value, range, _ in
            if let attachment = value as? MarkdownImageAttachment {
                if attachment.bounds == .zero {
                    attachment.bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
                }
            }
        }
        
        attributed.addAttributes([
            .foregroundColor: NSColor.clear,
            .font: NSFont.systemFont(ofSize: 1)
        ], range: line)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        applySpacing(to: paragraph, default: 2)
        applyParagraphStyle(paragraph, lineRange: line, to: attributed)
    }

    private func applyListBlock(
        markerRange: NSRange,
        contentRange: NSRange,
        lineRange: NSRange,
        inlines: [MarkdownInline],
        to attributed: NSMutableAttributedString,
        context: MarkdownRenderContext,
        theme: AppTheme,
        indent: CGFloat
    ) {
        guard let marker = safeRange(markerRange, in: attributed),
              let content = safeRange(contentRange, in: attributed),
              let line = safeRange(lineRange, in: attributed) else { return }

        attributed.addAttributes([
            .foregroundColor: NSColor(theme.textMuted),
            .font: NSFont.monospacedSystemFont(ofSize: baseFontSize, weight: .regular)
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
        applyParagraphStyle(paragraph, lineRange: line, to: attributed)

        applyInline(inlines, to: attributed, theme: theme, context: context)
    }

    func applyParagraphStyle(_ paragraph: NSParagraphStyle, lineRange: NSRange, to attributed: NSMutableAttributedString) {
        guard let line = safeRange(lineRange, in: attributed) else { return }
        let needsExtend = (line.location + line.length < attributed.length)
        let length = needsExtend ? line.length + 1 : line.length
        let fullRange = NSRange(location: line.location, length: length)
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)
    }

    func applyInline(_ inlines: [MarkdownInline], to attributed: NSMutableAttributedString, theme: AppTheme, context: MarkdownRenderContext) {
        for inline in inlines {
            let fullInlineRange = NSRange(
                location: inline.markerOpen.location,
                length: NSMaxRange(inline.markerClose) - inline.markerOpen.location
            )
            
            let showMarker = shouldShowMarker(fullInlineRange, selectedRange: context.selectedRange)
            let markerColor = showMarker ? NSColor(theme.textMuted) : NSColor.clear
            let markerFont = showMarker ? NSFont.monospacedSystemFont(ofSize: max(10, baseFontSize - 1), weight: .regular) : NSFont.systemFont(ofSize: 0.01)

            let markers = inline.markerRanges.compactMap { safeRange($0, in: attributed) }
            for markerRange in markers {
                attributed.addAttributes([
                    .foregroundColor: markerColor,
                    .font: markerFont
                ], range: markerRange)
            }

            guard let contentRange = safeRange(inline.contentRange, in: attributed) else { continue }

            switch inline.kind {
            case .bold:
                attributed.addAttributes([
                    .foregroundColor: NSColor(theme.textMain),
                    .font: NSFont.systemFont(ofSize: baseFontSize, weight: .bold)
                ], range: contentRange)

            case .italic:
                let base = bodyFont()
                let italicFont = NSFontManager.shared.font(withFamily: base.familyName ?? base.fontName, traits: .italicFontMask, weight: 5, size: baseFontSize) ?? base
                attributed.addAttributes([
                    .foregroundColor: NSColor(theme.textItalic),
                    .font: italicFont
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
                    .font: NSFont.monospacedSystemFont(ofSize: max(10, baseFontSize - 0.5), weight: .medium),
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
        let ratios: [CGFloat] = [2.0, 12.0/7.0, 10.0/7.0, 9.0/7.0, 8.0/7.0, 15.0/14.0]
        let idx = max(0, min(level - 1, 5))
        return (baseFontSize * ratios[idx]).rounded()
    }

    func safeRange(_ range: NSRange, in attributed: NSAttributedString) -> NSRange? {
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= attributed.length else { return nil }
        return range
    }
    
    private func shouldShowMarkerForHeading(lineRange: NSRange, selectedRange: NSRange?) -> Bool {
        guard let selected = selectedRange else { return false }
        
        if selected.length == 0 {
            let location = selected.location
            return location >= lineRange.location && location <= NSMaxRange(lineRange)
        }
        return lineRange.overlaps(selected)
    }
}

extension NSRange {
    func overlaps(_ other: NSRange) -> Bool {
        max(location, other.location) <= min(NSMaxRange(self), NSMaxRange(other))
    }
}

extension NSAttributedString.Key {
    static let isAICitation = NSAttributedString.Key("MyCustomAICitationKey")
}
