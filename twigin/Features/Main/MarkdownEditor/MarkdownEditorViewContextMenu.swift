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
                ("Translate", "translate"),
                ("Summarize", "doc.text"),
                ("Key Points", "list.bullet.indent"),
                ("Concise", "arrow.triangle.pull")
            ]
            
            menu.addItem(.separator())
            
            for (index, config) in aiMenuItems.enumerated() {
                let item = NSMenuItem(
                    title: config.title,
                    action: #selector(handleContextMenuAI(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = AIMenuAction(index, selectedText, at: insertionPoint)
                item.target = self
                
                if let symbolImage = NSImage(systemSymbolName: config.symbolName, accessibilityDescription: config.title) {
                    item.image = symbolImage
                }
                
                menu.addItem(item)
            }
            return menu
        }
        
        private func filterMenu(_ menu: NSMenu, actionsToRemove: Set<String>, titleKeywordsToRemove: [String]) {
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
                        if title.localizedCaseInsensitiveContains(keyword) {
                            shouldRemove = true
                            break
                        }
                    }
                }
                
                if !shouldRemove, let submenu = item.submenu {
                    filterMenu(submenu, actionsToRemove: actionsToRemove, titleKeywordsToRemove: titleKeywordsToRemove)
                    if submenu.items.isEmpty { shouldRemove = true }
                }
                
                if !shouldRemove {
                    itemsToKeep.append(item)
                }
            }
            menu.items = itemsToKeep
        }
        
        @objc func handleContextMenuAI(_ sender: NSMenuItem) {
            guard let action = sender.representedObject as? AIMenuAction,
                  let textView = textView else { return }
            contextMenuAITask?.cancel()
            contextMenuAITask = Task { @MainActor [weak self, weak textView] in
                guard let self, let textView else { return }
                await self.executeContextMenuAI(action: action, textView: textView)
            }
        }
        
        func executeContextMenuAI(action: AIMenuAction, textView: NSTextView) async {
            // Step 1: Accurate token count via Foundation Models tokenizer (macOS 26.4+).
            let tokenCount: Int
            if #available(macOS 26.4, *) {
                do {
                    tokenCount = try await SystemLanguageModel.default.tokenCount(for: action.selectedText)
                } catch {
                    tokenCount = max(1, action.selectedText.count / 4)
                }
            } else {
                // Fallback: ~4 chars per token for Latin text.
                tokenCount = max(1, action.selectedText.count / 4)
            }
            
            // Step 2: Route to Apple or Qwen and build the complete prompt.
            let (service, prompt) = routeContextMenuAI(
                commandIndex: action.commandIndex,
                selectedText: action.selectedText,
                tokenCount: tokenCount
            )
            
            // Step 3: Insert a blank separator after the selection, then stream.
            let insertRange = NSRange(location: action.insertionPoint, length: 0)
            let separator = "\n\n"
            if textView.shouldChangeText(in: insertRange, replacementString: separator) {
                textView.textStorage?.replaceCharacters(in: insertRange, with: separator)
                textView.didChangeText()
            }
            let streamStart = NSRange(location: action.insertionPoint + (separator as NSString).length, length: 0)
            textView.setSelectedRange(streamStart)
            
            let request = AIRequest(command: .ask, prompt: prompt)
            let eventStream = await service.execute(request: request)
            do {
                for try await event in eventStream {
                    guard !Task.isCancelled else { break }
                    if case .chunk(let chunk) = event {
                        let cur = textView.selectedRange()
                        if textView.shouldChangeText(in: cur, replacementString: chunk) {
                            textView.textStorage?.replaceCharacters(in: cur, with: chunk)
                            textView.setSelectedRange(NSRange(location: cur.location + (chunk as NSString).length, length: 0))
                            textView.didChangeText()
                        }
                    }
                }
            } catch {
                print("[AI Context Menu] Stream error: \(error)")
            }
        }
    }

// MARK: - AIMenuAction
final class AIMenuAction: NSObject {
    let commandIndex: Int
    let selectedText: String
    let insertionPoint: Int
    init(_ commandIndex: Int, _ selectedText: String, at insertionPoint: Int) {
        self.commandIndex = commandIndex
        self.selectedText = selectedText
        self.insertionPoint = insertionPoint
        super.init()
    }
}
