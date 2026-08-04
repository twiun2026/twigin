import AppKit
import SwiftUI

extension MarkdownTextView.Coordinator {
    
    @MainActor
    func textViewDidChangeSelection(_ notification: Notification) {
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
    
    @MainActor
    private func renderSelectionChange(affectedRanges: [NSRange]) {
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
}
