import AppKit
import SwiftUI

extension MarkdownTextView.Coordinator {
        
    func handleAIRequest(_ request: AIRequest, targetTextView: NSTextView) {
        aiTask?.cancel()
        
        aiTask = Task { @MainActor [weak self, weak targetTextView] in
            print(1)
            guard let self = self, let textView = targetTextView else { return }
            print(2)
            guard let layoutManager = textView.textLayoutManager,
                  let contentManager = layoutManager.textContentManager as? NSTextContentStorage,
                  let storage = textView.textStorage else { return }
            print(3)
            let initialIndex = textView.selectedRange().location
            let docRange = contentManager.documentRange
            
            guard var currentLocation: NSTextLocation = contentManager.location(docRange.location, offsetBy: initialIndex) else { return }
            let eventStream = await self.aiService.execute(request: request)
            
            do {
                for try await event in eventStream {
                    switch event {
                    case .chunk(let textChunk):
                        let targetIndex = contentManager.offset(from: contentManager.documentRange.location, to: currentLocation)
                        guard targetIndex >= 0 && targetIndex <= storage.length else { continue }
                        
                        let targetRange = NSRange(location: targetIndex, length: 0)
                        let chunkLength = (textChunk as NSString).length
                        
                        textView.undoManager?.disableUndoRegistration()
                        if textView.shouldChangeText(in: targetRange, replacementString: textChunk) {
                            storage.replaceCharacters(in: targetRange, with: textChunk)
                            if let nextLocation = contentManager.location(currentLocation, offsetBy: chunkLength) {
                                currentLocation = nextLocation
                            }
                            textView.didChangeText()
                        }
                        textView.undoManager?.enableUndoRegistration()
                    default:
                        break
                    }
                }
            } catch {
                print("Stream error: \(error)")
            }
        }
    }
    
    @MainActor func showAIPopover(title: String, anchorCharOffset: Int) {
        guard let textView = self.textView else { return }
        
        let targetRange = textView.selectedRange()
        
        aiPopoverController?.dismiss()
        let controller = AiPopoverController(title: title)
        self.aiPopoverController = controller
        
        controller.show(
            anchorCharOffset: anchorCharOffset,
            in: textView,
            theme: parent.theme,
            onInsert: { [weak self, weak textView] resultText in
                guard let self = self, let textView = textView else { return }
                self.insertInterleavedText(resultText, targetRange: targetRange, in: textView)
            },
            onReplace: { [weak self, weak textView] replacedText in
                guard let self = self, let textView = textView else { return }
                self.replaceSelectedText(with: replacedText, targetRange: targetRange, in: textView)
            },
            onNewNote: { newNoteText in
                NotificationCenter.default.post(
                    name: .aiPopoverNewNote,
                    object: nil,
                    userInfo: ["content": newNoteText]
                )
            }
        )
    }
    
    @MainActor func replaceSelectedText(with text: String, targetRange: NSRange, in textView: MarkdownNativeTextView) {
        isInsertingText = true
        
        let replacementLength = (text as NSString).length
        let newSelection = NSRange(location: targetRange.location + replacementLength, length: 0)
        
        if textView.shouldChangeText(in: targetRange, replacementString: text) {
            textView.textStorage?.replaceCharacters(in: targetRange, with: text)
            textView.setSelectedRange(newSelection)
            textView.didChangeText()
        }
        DispatchQueue.main.async { [weak self] in
            self?.isInsertingText = false
        }
    }

    @MainActor private func insertTextAtAnchor(_ text: String, in textView: MarkdownNativeTextView) {
        let range = NSRange(location: textView.selectedRange().location, length: 0)
        if textView.shouldChangeText(in: range, replacementString: text) {
            textView.textStorage?.replaceCharacters(in: range, with: text)
            textView.didChangeText()
        }
    }
    
    @MainActor func insertInterleavedText(_ translationText: String, targetRange: NSRange, in textView: MarkdownNativeTextView) {
        let fullText = textView.string as NSString
        guard targetRange.location != NSNotFound,
              NSMaxRange(targetRange) <= fullText.length else { return }
        
        let originalText = fullText.substring(with: targetRange)
        let endsWithNewline = originalText.hasSuffix("\n") || originalText.hasSuffix("\r\n")
        
        let originalList = originalText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            
        let translationList = translationText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        var finalString = ""
        var aiTextRanges: [NSRange] = []
        
        let maxCount = max(originalList.count, translationList.count)
        
        for index in 0..<maxCount {
            if index < originalList.count {
                if !finalString.isEmpty {
                    finalString += "\n\n"
                }
                finalString += originalList[index]
            }
            
            if index < translationList.count {
                if !finalString.isEmpty {
                    finalString += "\n\n"
                }
                let aiSegment = translationList[index]
                let segmentStart = (finalString as NSString).length
                let segmentLength = (aiSegment as NSString).length
                
                finalString += aiSegment
                aiTextRanges.append(NSRange(location: segmentStart, length: segmentLength))
            }
        }
        
        if endsWithNewline && !finalString.hasSuffix("\n") {
            finalString += "\n"
        }
        
        let insertedLength = (finalString as NSString).length
        guard let storage = textView.textStorage else { return }
        
        isInsertingText = true
        isLoadingContent = true
        editSerial &+= 1
        let expectedSerial = editSerial
        
        if textView.shouldChangeText(in: targetRange, replacementString: finalString) {
            storage.beginEditing()
            
            textView.undoManager?.disableUndoRegistration()
            storage.replaceCharacters(in: targetRange, with: finalString)
            textView.undoManager?.enableUndoRegistration()
            
            let baseLocation = targetRange.location
            let citationColor = NSColor(parent.theme.textCitation)
            
            for relativeRange in aiTextRanges {
                let absoluteRange = NSRange(
                    location: baseLocation + relativeRange.location,
                    length: relativeRange.length
                )
                if NSMaxRange(absoluteRange) <= storage.length {
                    storage.addAttribute(.isAICitation, value: true, range: absoluteRange)
                    storage.addAttribute(.foregroundColor, value: citationColor, range: absoluteRange)
                }
            }
            
            storage.endEditing()
            
            let newLocation = targetRange.location + insertedLength
            let newSelection = NSRange(location: newLocation, length: 0)
            textView.setSelectedRange(newSelection)
            
            isLoadingContent = false
            textView.didChangeText()
            
            let newSource = textView.string
            engine.load(text: newSource) { [weak self, aiTextRanges] snapshot in
                DispatchQueue.main.async {
                    guard let self = self,
                          self.editSerial == expectedSerial,
                          let currentTextView = self.textView,
                          let currentStorage = currentTextView.textStorage,
                          currentStorage.length == snapshot.textLength else { return }
                    
                    self.renderFull(blocks: snapshot.blocks)
                    
                    currentStorage.beginEditing()
                    for relativeRange in aiTextRanges {
                        let absoluteRange = NSRange(
                            location: baseLocation + relativeRange.location,
                            length: relativeRange.length
                        )
                        if NSMaxRange(absoluteRange) <= currentStorage.length {
                            currentStorage.addAttribute(.isAICitation, value: true, range: absoluteRange)
                            currentStorage.addAttribute(.foregroundColor, value: citationColor, range: absoluteRange)
                        }
                    }
                    currentStorage.endEditing()
                }
            }
        } else {
            isLoadingContent = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.isInsertingText = false
        }
    }
    
    private func buildInterleavedText(original: String, translation: String) -> String {
        let originalParagraphs = original
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        
        let translationParagraphs = translation
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        
        var combined: [String] = []
        let maxCount = max(originalParagraphs.count, translationParagraphs.count)
        
        for i in 0..<maxCount {
            if i < originalParagraphs.count {
                combined.append(originalParagraphs[i])
            }
            if i < translationParagraphs.count {
                combined.append(translationParagraphs[i])
            }
        }
        
        return combined.joined(separator: "\n\n")
    }
    
    @MainActor func handleContextMenuAIAction(commandIndex: Int) {
        guard let textView = self.textView else { return }
        
        let selectedRange = textView.selectedRange()
        let nsString = textView.string as NSString
        
        guard selectedRange.location != NSNotFound,
              NSMaxRange(selectedRange) <= nsString.length,
              selectedRange.length > 0 else { return }
        
        let selectedText = nsString.substring(with: selectedRange)
        
        // 核心改变：不再手写长 Prompt 和 token 逻辑，而是直接从 AIPromptFactory 获取结构化请求与标题
        guard let request = AIPromptFactory.makeRequest(forCommandIndex: commandIndex, selectedText: selectedText) else { return }
        let title = AIPromptFactory.title(forCommandIndex: commandIndex)
        
        showAIPopover(title: title, anchorCharOffset: selectedRange.location)
        
        // 直接丢给统一的 aiService 执行，底层自动根据路由规则选择模型
        aiPopoverController?.startStreaming(service: aiService, request: request)
    }
}
