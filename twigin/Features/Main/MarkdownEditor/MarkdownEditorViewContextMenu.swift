import AppKit
import FoundationModels

// MARK: - Context Menu & AI Extensions
extension MarkdownTextView.Coordinator {

    @MainActor
    func buildContextMenu(_ menu: NSMenu, for view: NSTextView) -> NSMenu? {
        let actionsToRemove: Set<String> = [
            "ignoreSpelling:", "ignoreSpelling",
            "learnSpelling:", "learnSpelling",
            "orderFrontWritingTools:", "toggleLayoutOrientation:",
            "makeBaseWritingDirectionLeftToRight:", "makeBaseWritingDirectionRightToLeft:",
            "orderFrontFontPanel:", "showGuessPanel:", "orderFrontStylesPanel:"
        ]

        let titleKeywordsToRemove = [
            "Ignore Spelling", "忽略拼写", "Learn Spelling", "记住拼写",
            "Look Up", "查找", "Translate", "翻译",
            "Show Writing Tools", "显示写作工具", "Writing Tools", "写作工具",
            "Proofread", "校对", "Rewrite", "重写",
            "Spelling and Grammar", "拼写和语法", "Spelling",
            "Layout Orientation", "布局方向", "Font", "字体", "Share", "分享"
        ]

        filterMenu(menu, actionsToRemove: actionsToRemove, titleKeywordsToRemove: titleKeywordsToRemove)

        let sel = view.selectedRange()
        guard sel.length > 0 else { return menu }
        let ns = view.string as NSString
        guard NSMaxRange(sel) <= ns.length else { return menu }
        let selectedText = ns.substring(with: sel)
        guard !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return menu }

        let insertionPoint = NSMaxRange(sel)
        if let firstItem = menu.items.first, firstItem.isSeparatorItem {
            menu.removeItem(at: 0)
        }

        let aiMenuItems: [(title: String, symbolName: String)] = [
            ("Translate",  "translate"),
            ("Summarize",  "doc.text"),
            ("Key Points", "list.bullet.indent"),
            ("Concise",    "arrow.triangle.pull")
        ]

        menu.addItem(.separator())

        for (index, config) in aiMenuItems.enumerated() {
            let item = NSMenuItem(
                title: config.title,
                action: #selector(handleContextMenuAI(_:)),
                keyEquivalent: ""
            )
            item.representedObject = AIMenuAction(
                index,
                title: config.title,
                selectedText,
                selectionRange: sel,
                at: insertionPoint
            )
            item.target = self
            if let symbolImage = NSImage(systemSymbolName: config.symbolName,
                                         accessibilityDescription: config.title) {
                item.image = symbolImage
            }
            menu.addItem(item)
        }
        return menu
    }

    private func filterMenu(_ menu: NSMenu,
                             actionsToRemove: Set<String>,
                             titleKeywordsToRemove: [String]) {
        var itemsToKeep: [NSMenuItem] = []
        for item in menu.items {
            var shouldRemove = false
            if let action = item.action {
                let actionName = NSStringFromSelector(action)
                if actionsToRemove.contains(actionName) { shouldRemove = true }
            }
            if !shouldRemove {
                let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                for keyword in titleKeywordsToRemove {
                    if title.localizedCaseInsensitiveContains(keyword) { shouldRemove = true; break }
                }
            }
            if !shouldRemove, let submenu = item.submenu {
                filterMenu(submenu, actionsToRemove: actionsToRemove, titleKeywordsToRemove: titleKeywordsToRemove)
                if submenu.items.isEmpty { shouldRemove = true }
            }
            if !shouldRemove { itemsToKeep.append(item) }
        }
        menu.items = itemsToKeep
    }

    // MARK: - Context Menu AI handler

    // MARK: - Context Menu AI handler

        @objc private func handleContextMenuAI(_ sender: NSMenuItem) {
            guard let action = sender.representedObject as? AIMenuAction,
                  let textView else { return }

            // Cancel and dismiss any existing popover/task.
            contextMenuAITask?.cancel()
            aiPopoverController?.dismiss()
            aiPopoverController = nil

            let controller = AiPopoverController(title: action.title)
            aiPopoverController = controller

            // Anchor = start of the line that contains the end of the selection.
            let nsString = textView.string as NSString
            let anchorLoc = max(0, action.insertionPoint == 0 ? 0 : action.insertionPoint - 1)
            let anchorLineStart = nsString.lineRange(for: NSRange(location: anchorLoc, length: 0)).location

            let selRange = action.selectionRange
            
            // 【关键改动】：在这里传入你的 insertInterleavedTranslation 方法和 targetRange
            controller.show(
                anchorCharOffset: anchorLineStart,
                in: textView,
                theme: parent.theme,
                onInsert: { [weak self, weak textView] translatedText in
                    guard let self, let textView else { return }
                    self.insertInterleavedText(translatedText, targetRange: selRange, in: textView)
                },
                onReplace: { [weak self, weak textView] replacedText in
                    guard let self, let textView else { return }
                    self.replaceSelectedText(with: replacedText, targetRange: selRange, in: textView)
                },
                onNewNote: { content in
                    NotificationCenter.default.post(name: .aiPopoverNewNote, object: content)
                }
            )

            contextMenuAITask = Task { @MainActor [weak self, weak controller] in
                guard let self, let controller else { return }

                // Accurate token count for provider routing.
                let tokenCount: Int
                if #available(macOS 26.4, *) {
                    do {
                        tokenCount = try await SystemLanguageModel.default.tokenCount(for: action.selectedText)
                    } catch {
                        tokenCount = max(1, action.selectedText.count / 4)
                    }
                } else {
                    tokenCount = max(1, action.selectedText.count / 4)
                }

                let (service, prompt) = self.routeContextMenuAI(
                    commandIndex: action.commandIndex,
                    selectedText: action.selectedText,
                    tokenCount: tokenCount
                )
                let request = AIRequest(command: .ask, prompt: prompt)
                controller.startStreaming(service: service, request: request)
            }
        }

    // MARK: - Insert / Replace helpers

    private func insertInEditor(_ content: String) {
        guard let textView else { return }
        let range = textView.selectedRange()
        if textView.shouldChangeText(in: range, replacementString: content) {
            textView.textStorage?.replaceCharacters(in: range, with: content)
            textView.didChangeText()
        }
    }

    private func replaceInEditor(_ content: String, selectionRange: NSRange) {
        guard let textView, let storage = textView.textStorage else { return }
        let maxLen = storage.length
        let loc = min(selectionRange.location, maxLen)
        let len = min(selectionRange.length, maxLen - loc)
        let safeRange = NSRange(location: loc, length: len)
        if textView.shouldChangeText(in: safeRange, replacementString: content) {
            storage.replaceCharacters(in: safeRange, with: content)
            textView.didChangeText()
        }
    }

}

// MARK: - AIMenuAction

final class AIMenuAction: NSObject {
    let commandIndex: Int
    let title: String
    let selectedText: String
    let selectionRange: NSRange
    let insertionPoint: Int

    init(_ commandIndex: Int, title: String, _ selectedText: String,
         selectionRange: NSRange, at insertionPoint: Int) {
        self.commandIndex = commandIndex
        self.title = title
        self.selectedText = selectedText
        self.selectionRange = selectionRange
        self.insertionPoint = insertionPoint
        super.init()
    }
}
