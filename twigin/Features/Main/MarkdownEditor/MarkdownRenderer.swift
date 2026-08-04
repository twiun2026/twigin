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

private struct _FontKey: Hashable, Sendable {
    let name: String       // 字体族名；空串表示系统字体
    let size: CGFloat
    let weightRaw: CGFloat // NSFont.Weight.rawValue
    let mono: Bool
}


@MainActor
final class MarkdownRenderer {
    // MARK: - 字体 Cascade 描述符缓存（@MainActor 静态，无需锁）
    //
    // 将字体创建开销从 O(段落数 × 每渲染帧) 降为 O(1) 均摊。
    // 每次 NSFont.systemFont / monospacedSystemFont / NSFontManager 调用都触发
    // CoreText 字体匹配；在 5 万字文档中累积开销显著，此缓存彻底消除该瓶颈。
    // 声明在 @MainActor 类内部，所有渲染调用均在主线程，无需额外加锁。
    private static var fontCache: [_FontKey: NSFont] = [:]
    private static var italicCache: [String: NSFont] = [:]

    /// 返回缓存的 NSFont；首次访问时创建并写入缓存。
    static func cachedFont(
        name: String = "",
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        mono: Bool = false
    ) -> NSFont {
        let key = _FontKey(name: name, size: size, weightRaw: weight.rawValue, mono: mono)
        if let hit = fontCache[key] { return hit }
        let font: NSFont
        if mono {
            font = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        } else if !name.isEmpty, let f = NSFont(name: name, size: size) {
            font = f
        } else {
            font = NSFont.systemFont(ofSize: size, weight: weight)
        }
        fontCache[key] = font
        return font
    }

    /// 通过 NSFontManager 合成斜体变体（开销高，单独缓存）。
    static func cachedItalicFont(family: String, size: CGFloat, fallback: NSFont) -> NSFont {
        let key = "\(family):\(size)"
        if let hit = italicCache[key] { return hit }
        let f = NSFontManager.shared.font(
            withFamily: family, traits: .italicFontMask, weight: 5, size: size
        ) ?? fallback
        italicCache[key] = f
        return f
    }
    var bodyFontName: String = ""
    var lineSpacingMultiplier: CGFloat = 0
    var baseFontSize: CGFloat = 14

    func bodyFont(size: CGFloat? = nil) -> NSFont {
        Self.cachedFont(name: bodyFontName, size: size ?? baseFontSize)
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

    // MARK: - 视口字符区间计算
    //
    // 核心设计：将屏幕可见矩形换算为字符区间，不强制触发全文排版。
    //
    // characterIndexForInsertion(at:) 在已排版区域为 O(1) 命中缓存；
    // 在未排版区域返回文档边界（不强制布局）。初次打开时 visibleRect.height 极小
    // 或 rawTop == rawBot，此时退化为头部固定窗口（charBuffer 个字符），
    // 保证首屏即时呈现后再由 renderViewportIfNeeded 随滚动按需补渲。
    static func viewportCharRange(
        in textView: MarkdownNativeTextView,
        charBuffer: Int = 6000
    ) -> NSRange {
        let len = (textView.string as NSString).length
        guard len > 0 else { return NSRange(location: 0, length: 0) }

        let visible = textView.visibleRect
        guard visible.height > 20 else {
            // 视图未完成首次布局 → 头部固定窗口
            return NSRange(location: 0, length: min(len, charBuffer))
        }

        let rawTop = textView.characterIndexForInsertion(at: CGPoint(x: 4, y: max(0, visible.minY)))
        let rawBot = textView.characterIndexForInsertion(at: CGPoint(x: 4, y: visible.maxY))

        guard rawBot > rawTop else {
            // 视口区域尚无布局缓存 → 退化为头部固定窗口
            return NSRange(location: 0, length: min(len, charBuffer))
        }

        let start = max(0, rawTop - charBuffer)
        let end   = min(len, rawBot + charBuffer)
        return NSRange(location: start, length: end - start)
    }

    // MARK: - 主渲染入口
    //
    // 增量路径（blockDiff != nil）和全量路径（blockDiff == nil）在此分流：
    //   • 增量：makeRenderPlan 从 blockDiff 提取受影响范围，仅对变化块做 setAttributes。
    //   • 全量：makeRenderPlan 使用 document.affectedRange 作为渲染窗口；
    //     Coordinator.renderFull 会将视口区间填入 affectedRange，
    //     因此 setAttributes 仅作用于视口，O(Viewport) 而非 O(N)。
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
        let baseAttrs = baseAttributes(theme: context.theme)
        for range in renderPlan.ranges {
            guard range.length > 0 else { continue }
            textStorage.setAttributes(baseAttrs, range: range)
        }
        for block in renderPlan.blocks {
            applyBlock(block, to: textStorage, theme: context.theme, context: context)
        }
        textStorage.endEditing()

        invalidateLayout(in: context.textView, affectedRanges: renderPlan.ranges)
    }

    // MARK: - RenderPlan 构建

    private struct RenderPlan {
        var ranges: [NSRange]
        var blocks: [MarkdownBlock]
    }

    private func paragraphEnd(after pos: Int, in text: NSString, upTo limit: Int) -> Int {
        guard pos < limit else { return limit }
        let paraRange = text.paragraphRange(for: NSRange(location: pos, length: 0))
        return min(NSMaxRange(paraRange), limit)
    }

    private func makeRenderPlan(
        document: MarkdownDocument,
        storageLength: Int,
        text: NSString? = nil
    ) -> RenderPlan {
        // ── 增量路径：保留完整 blockDiff 逻辑，不作任何改动 ──
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

        // ── 全量路径（初次加载 / 笔记切换 / 主题变化 / 滚动补渲）──
        //
        // document.affectedRange 由调用方控制：
        //   • renderFull → 设为 viewportCharRange（视口区间），实现视口惰性渲染
        //   • renderViewportIfNeeded → 设为新进入视口的未渲染区间联合
        //   • nil → 退化为全文（兜底，极少触发）
        //
        // setAttributes 范围 = applyRange，视口外区域的纯文本默认外观保持不变，
        // 待用户滚动到达后再由 renderViewportIfNeeded 按需补全样式。
        let applyRange = clampedApplyRange(for: document, storageLength: storageLength)
        let affectedBlocks = document.blocks.filter { $0.lineRange.overlaps(applyRange) }
        return RenderPlan(
            ranges: applyRange.length > 0 ? [applyRange] : [],
            blocks: affectedBlocks
        )
    }

    private func clampedApplyRange(for document: MarkdownDocument, storageLength: Int) -> NSRange {
        let raw = document.affectedRange ?? NSRange(location: 0, length: storageLength)
        let lo = min(max(raw.location, 0), storageLength)
        let hi = min(max(NSMaxRange(raw), lo), storageLength)
        return NSRange(location: lo, length: hi - lo)
    }

    private func resetAttributes(in range: NSRange, storage: NSTextStorage, theme: AppTheme) {
        guard range.length > 0 else { return }
        storage.setAttributes(baseAttributes(theme: theme), range: range)
    }

    func invalidateLayout(in textView: MarkdownNativeTextView, affectedRanges: [NSRange]) {
        guard let textLayoutManager = textView.textLayoutManager,
              let textContentManager = textLayoutManager.textContentManager else { return }
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

        textView.needsDisplay = true
    }

    private func mergeRanges(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.filter { $0.length > 0 }.sorted {
            $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location
        }
        guard !sorted.isEmpty else { return [] }
        var merged: [NSRange] = [sorted[0]]
        for range in sorted.dropFirst() {
            guard let last = merged.last else { continue }
            if NSMaxRange(last) >= range.location {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private func clamp(range: NSRange, storageLength: Int) -> NSRange {
        let lo = min(max(range.location, 0), storageLength)
        let hi = min(max(NSMaxRange(range), lo), storageLength)
        return NSRange(location: lo, length: hi - lo)
    }

    func shouldShowMarker(_ targetRange: NSRange, selectedRange: NSRange?) -> Bool {
        guard let selected = selectedRange, selected.length == 0 else { return false }
        return selected.location >= targetRange.location && selected.location <= NSMaxRange(targetRange)
    }

    // MARK: - 块分派

    func applyBlock(
        _ block: MarkdownBlock,
        to attributed: NSMutableAttributedString,
        theme: AppTheme,
        context: MarkdownRenderContext
    ) {
        switch block.kind {
        case let .heading(level):
            guard let markerRange = block.markerRange,
                  let contentRange = block.contentRange else { return }
            applyHeading(
                level: level, markerRange: markerRange, contentRange: contentRange,
                lineRange: block.lineRange, to: attributed, context: context, theme: theme
            )
        case .paragraph:
            applyParagraph(
                lineRange: block.lineRange, inlines: block.inlines,
                to: attributed, context: context, theme: theme
            )
        case let .checklist(marker):
            guard let markerRange = block.markerRange,
                  let contentRange = block.contentRange else { return }
            applyChecklist(
                marker: marker, markerRange: markerRange, contentRange: contentRange,
                lineRange: block.lineRange, inlines: block.inlines,
                to: attributed, theme: theme, context: context
            )
        case let .image(_, path):
            applyImageAttachment(
                path: path, lineRange: block.lineRange,
                to: attributed, theme: theme, context: context
            )
        case .bulletList:
            guard let markerRange = block.markerRange,
                  let contentRange = block.contentRange else { return }
            applyListBlock(
                markerRange: markerRange, contentRange: contentRange,
                lineRange: block.lineRange, inlines: block.inlines,
                to: attributed, context: context, theme: theme, indent: 20
            )
        case .orderedList:
            guard let markerRange = block.markerRange,
                  let contentRange = block.contentRange else { return }
            applyListBlock(
                markerRange: markerRange, contentRange: contentRange,
                lineRange: block.lineRange, inlines: block.inlines,
                to: attributed, context: context, theme: theme, indent: 24
            )
        case .blockquote:
            guard let markerRange = block.markerRange,
                  let contentRange = block.contentRange else { return }
            MarkdownBlockquote.apply(
                markerRange: markerRange, contentRange: contentRange,
                lineRange: block.lineRange, inlines: block.inlines,
                to: attributed, context: context, theme: theme, renderer: self
            )
        case .footnote(label: _):
            guard let markerRange = block.markerRange,
                  let _ = block.contentRange else { return }
            attributed.addAttributes([.foregroundColor: NSColor(theme.textSecondary)], range: markerRange)
            applyInline(block.inlines, to: attributed, theme: theme, context: context)
        case .codeBlock:
            break
        }
    }

    // MARK: - 具体块样式

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
        let hSize = headingSize(for: level)
        // 使用缓存字体，避免每次标题渲染都触发 CoreText 匹配
        let headingFont = Self.cachedFont(size: hSize, weight: .bold)

        attributed.addAttributes([
            .foregroundColor: showMarker ? NSColor(theme.textMuted) : NSColor.clear,
            .font: showMarker ? headingFont : Self.cachedFont(size: 0.01)
        ], range: marker)

        attributed.addAttributes([
            .foregroundColor: NSColor(theme.textHeader),
            .font: headingFont
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
            .font: Self.cachedFont(size: 1)
        ], range: markerTextRange)

        var contentAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(theme.textMain),
            .font: Self.cachedFont(name: bodyFontName, size: baseFontSize)
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

        attributed.enumerateAttribute(.attachment, in: line, options: []) { value, _, _ in
            if let attachment = value as? MarkdownImageAttachment, attachment.bounds == .zero {
                attachment.bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
            }
        }

        attributed.addAttributes([
            .foregroundColor: NSColor.clear,
            .font: Self.cachedFont(size: 1)
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
            .font: Self.cachedFont(size: baseFontSize, mono: true)
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

    func applyParagraphStyle(
        _ paragraph: NSParagraphStyle,
        lineRange: NSRange,
        to attributed: NSMutableAttributedString
    ) {
        guard let line = safeRange(lineRange, in: attributed) else { return }
        let needsExtend = (line.location + line.length < attributed.length)
        let length = needsExtend ? line.length + 1 : line.length
        let fullRange = NSRange(location: line.location, length: length)
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)
    }

    func applyInline(
        _ inlines: [MarkdownInline],
        to attributed: NSMutableAttributedString,
        theme: AppTheme,
        context: MarkdownRenderContext
    ) {
        for inline in inlines {
            let fullInlineRange = NSRange(
                location: inline.markerOpen.location,
                length: NSMaxRange(inline.markerClose) - inline.markerOpen.location
            )

            let showMarker = shouldShowMarker(fullInlineRange, selectedRange: context.selectedRange)
            // 缓存 marker 字体（monospacedSystemFont 每次调用均触发 CoreText）
            let markerFont = showMarker
                ? Self.cachedFont(size: max(10, baseFontSize - 1), mono: true)
                : Self.cachedFont(size: 0.01)
            let markerColor = showMarker ? NSColor(theme.textMuted) : NSColor.clear

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
                    .font: Self.cachedFont(size: baseFontSize, weight: .bold)
                ], range: contentRange)

            case .italic:
                let base = bodyFont()
                let family = base.familyName ?? base.fontName
                let italicFont = Self.cachedItalicFont(family: family, size: baseFontSize, fallback: base)
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
                    .font: Self.cachedFont(size: max(10, baseFontSize - 0.5), weight: .medium, mono: true),
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
        let ratios: [CGFloat] = [2.0, 12.0 / 7.0, 10.0 / 7.0, 9.0 / 7.0, 8.0 / 7.0, 15.0 / 14.0]
        let idx = max(0, min(level - 1, 5))
        return (baseFontSize * ratios[idx]).rounded()
    }

    func safeRange(_ range: NSRange, in attributed: NSAttributedString) -> NSRange? {
        guard range.location >= 0, range.length >= 0,
              NSMaxRange(range) <= attributed.length else { return nil }
        return range
    }

    private func shouldShowMarkerForHeading(lineRange: NSRange, selectedRange: NSRange?) -> Bool {
        guard let selected = selectedRange else { return false }
        if selected.length == 0 {
            return selected.location >= lineRange.location && selected.location <= NSMaxRange(lineRange)
        }
        return lineRange.overlaps(selected)
    }
}

// MARK: -

extension NSRange {
    func overlaps(_ other: NSRange) -> Bool {
        max(location, other.location) <= min(NSMaxRange(self), NSMaxRange(other))
    }
}

extension NSAttributedString.Key {
    static let isAICitation = NSAttributedString.Key("MyCustomAICitationKey")
}
