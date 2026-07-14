import SwiftUI

struct MarkdownEditorView: View {
    @Binding var text: String
    var theme: AppTheme
    var fontName: String = ""
    var lineSpacing: CGFloat = 0

    var body: some View {
        MarkdownTextView(text: $text, theme: theme, fontName: fontName, lineSpacing: lineSpacing)
    }
}

struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var theme: AppTheme
    var fontName: String = ""
    var lineSpacing: CGFloat = 0

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

        textView.backgroundColor = NSColor(theme.bgNoteEditor)
        textView.insertionPointColor = NSColor(theme.textMain)
        textView.font = resolvedFont()

        // bind() and delegate must be set BEFORE string assignment so willProcessEditing
        // fires with a valid textView reference.
        context.coordinator.bind(textView: textView)
        textView.textStorage?.delegate = context.coordinator

        textView.string = text
        // willProcessEditing parses but does NOT render (no textDidChange fires for
        // programmatic string assignment). Clear the stale pendingEditedRange and do
        // an explicit full render to apply initial markdown styling.
        context.coordinator.pendingEditedRange = nil
        context.coordinator.lastRenderedTheme = theme
        context.coordinator.lastRenderedFontName = fontName
        context.coordinator.lastRenderedLineSpacing = lineSpacing
        context.coordinator.refreshFull()

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(theme.bgNoteEditor)
        scrollView.documentView = textView

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // Keep coordinator's copy of parent in sync so willProcessEditing sees the latest theme
        context.coordinator.parent = self

        guard let textView = nsView.documentView as? MarkdownNativeTextView else { return }

        textView.insertionPointColor = NSColor(theme.textMain)
        let newFont = resolvedFont()
        if textView.font != newFont { textView.font = newFont }

        let bgColor = NSColor(theme.bgNoteEditor)
        if textView.backgroundColor != bgColor {
            textView.backgroundColor = bgColor
            nsView.backgroundColor = bgColor
        }

        if textView.string != text {
            // External content change (note switch): set string, then full render.
            // textDidChange does NOT fire for programmatic string assignment, so we
            // must render explicitly. Clear any stale pendingEditedRange first.
            textView.string = text
            context.coordinator.pendingEditedRange = nil
            context.coordinator.lastRenderedTheme = theme
            context.coordinator.lastRenderedFontName = fontName
            context.coordinator.lastRenderedLineSpacing = lineSpacing
            context.coordinator.refreshFull()
        } else if context.coordinator.lastRenderedTheme != theme
               || context.coordinator.lastRenderedFontName != fontName
               || context.coordinator.lastRenderedLineSpacing != lineSpacing {
            context.coordinator.refreshFull()
        }
        // text == textView.string && theme unchanged → user typed a character.
        // willProcessEditing already applied attributes atomically. Nothing to do.
    }

    private func resolvedFont() -> NSFont {
        let size: CGFloat = 14
        if !fontName.isEmpty, let font = NSFont(name: fontName, size: size) {
            return font
        }
        return NSFont.systemFont(ofSize: size, weight: .regular)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: MarkdownTextView
        weak var textView: MarkdownNativeTextView?
        /// Tracks the theme used in the last full render; drives theme-change detection in updateNSView.
        var lastRenderedTheme: AppTheme? = nil
        var lastRenderedFontName: String = ""
        var lastRenderedLineSpacing: CGFloat = 0
        /// Set by willProcessEditing; consumed by textDidChange to render the affected blocks.
        var pendingEditedRange: NSRange? = nil

        private let renderer = MarkdownRenderer()
        private var document = MarkdownDocument(source: "", blocks: [])

        init(parent: MarkdownTextView) {
            self.parent = parent
        }

        func bind(textView: MarkdownNativeTextView) {
            self.textView = textView
        }

        // MARK: NSTextStorageDelegate

        func textStorage(
            _ textStorage: NSTextStorage,
            willProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }
            // Parse only — do NOT call setAttributes here.
            // Calling setAttributes inside willProcessEditing expands the internal
            // editedRange that NSTextView uses to reposition the cursor after
            // processEditing, which causes the cursor to jump to the paragraph end.
            document = renderer.parse(source: textStorage.string)
            pendingEditedRange = editedRange
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string

            // Render here: NSTextView has already placed the cursor at the correct
            // post-edit position. This call runs synchronously before the next screen
            // refresh, so no jitter — TextKit 2 detects unchanged attributes and skips
            // re-layout for the common case (typing in a plain paragraph).
            guard let editedRange = pendingEditedRange else { return }
            pendingEditedRange = nil
            renderer.bodyFontName = parent.fontName
            renderer.lineSpacingMultiplier = parent.lineSpacing
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
        }

        func textViewDidChangeSelection(_ notification: Notification) {}

        // MARK: Explicit full renders (theme change only — note switches handled by willProcessEditing)

        func refreshFull() {
            guard let textView else { return }
            renderer.bodyFontName = parent.fontName
            renderer.lineSpacingMultiplier = parent.lineSpacing
            document = renderer.parse(source: textView.string)
            renderer.render(
                .init(
                    textView: textView,
                    theme: parent.theme,
                    document: document,
                    editedRange: nil,
                    onToggleChecklist: { [weak self] range, isChecked in
                        self?.toggleChecklist(in: range, to: isChecked)
                    },
                    onTapImage: { path in
                        NSWorkspace.shared.openFile(path)
                    }
                )
            )
            lastRenderedTheme = parent.theme
            lastRenderedFontName = parent.fontName
            lastRenderedLineSpacing = parent.lineSpacing
        }

        // MARK: Checklist toggle

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

        // MARK: Return key continuation

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  let selectedRange = textView.selectedRanges.first?.rangeValue else { return false }

            let nsString = textView.string as NSString
            let lineRange = nsString.lineRange(for: selectedRange)
            let lineText = nsString.substring(with: lineRange)

            // Unordered list
            if let bulletMatch = try? NSRegularExpression(pattern: "^(\\s*[-*+])\\s*(.*)$")
                .firstMatch(in: lineText, range: NSRange(location: 0, length: (lineText as NSString).length)) {

                let marker = (lineText as NSString).substring(with: bulletMatch.range(at: 1))
                let content = (lineText as NSString).substring(with: bulletMatch.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)

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

            // Ordered list
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

            // Blockquote
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

            return false
        }
    }
}

// MarkdownNativeTextView: onWillReplaceText removed — rendering now uses NSTextStorageDelegate
final class MarkdownNativeTextView: NSTextView {}
