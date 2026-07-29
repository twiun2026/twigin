import AppKit
import Foundation
import UniformTypeIdentifiers

extension MarkdownTextView.Coordinator {
    static let imageDisplayRegex = try! NSRegularExpression(pattern: "^!\\[([^\\]]*)\\]\\(([^\\)]+)\\)$")
    
    func processImageParagraph(
        in paragraph: NSAttributedString,
        range: NSRange,
        nsString: NSString
    ) -> NSTextParagraph? {
        let fullRange = NSRange(location: 0, length: nsString.length)
        
        guard let match = Self.imageDisplayRegex.firstMatch(in: paragraph.string, range: fullRange) else {
            return nil
        }
        
        let alt = nsString.substring(with: match.range(at: 1))
        let path = nsString.substring(with: match.range(at: 2))
        
        let display = NSMutableAttributedString(attributedString: paragraph)
        let bodyFont = MarkdownTextView.resolvedFont(for: parent.fontName)
        
        let attachment = MarkdownImageAttachment(
            sourcePath: path,
            alt: alt,
            lineRange: range,
            onTap: { p in
                let fileURL = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
                NSWorkspace.shared.open(fileURL)
            }
        )
        
        let matchRange = match.range(at: 0)
        let attachmentString = NSMutableAttributedString(attachment: attachment)
        
        // 修复：显式指定 NSAttributedString.Key.font
        attachmentString.addAttribute(.font, value: bodyFont, range: NSRange(location: 0, length: attachmentString.length))
        
        display.replaceCharacters(in: matchRange, with: attachmentString)
        
        return NSTextParagraph(attributedString: display)
    }
}

// MARK: - Image Drag & Paste Handler (MarkdownNativeTextView Extension)

extension MarkdownNativeTextView {

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pboard = sender.draggingPasteboard
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            var imageMarkdown = ""
            for url in urls {
                if isImageURL(url) {
                    imageMarkdown += "![image](\(url.path))\n"
                }
            }
            if !imageMarkdown.isEmpty {
                let point = convert(sender.draggingLocation, from: nil)
                let index = characterIndexForInsertion(at: point)
                if shouldChangeText(in: NSRange(location: index, length: 0), replacementString: imageMarkdown) {
                    textStorage?.replaceCharacters(in: NSRange(location: index, length: 0), with: imageMarkdown)
                    didChangeText()
                    print(" 拖拽生成 Markdown 图片语法:\n\(imageMarkdown)")
                }
                return true
            }
        }
        return super.performDragOperation(sender)
    }

    override func paste(_ sender: Any?) {
        let pboard = NSPasteboard.general
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            var imageMarkdown = ""
            for url in urls {
                if isImageURL(url) {
                    imageMarkdown += "![image](\(url.path))\n"
                }
            }
            if !imageMarkdown.isEmpty {
                let range = selectedRange()
                if shouldChangeText(in: range, replacementString: imageMarkdown) {
                    textStorage?.replaceCharacters(in: range, with: imageMarkdown)
                    didChangeText()
                }
                return
            }
        }
        super.paste(sender)
    }
    
    func handleImageDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pboard = sender.draggingPasteboard
        guard let urls = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return false
        }
        
        let imageMarkdown = buildMarkdownImageString(from: urls)
        guard !imageMarkdown.isEmpty else { return false }
        
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        let targetRange = NSRange(location: index, length: 0)
        
        if shouldChangeText(in: targetRange, replacementString: imageMarkdown) {
            textStorage?.replaceCharacters(in: targetRange, with: imageMarkdown)
            didChangeText()
            print("拖拽生成 Markdown 图片语法:\n\(imageMarkdown)")
            return true
        }
        return false
    }

    func handleImagePaste() -> Bool {
        let pboard = NSPasteboard.general
        guard let urls = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return false
        }
        
        let imageMarkdown = buildMarkdownImageString(from: urls)
        guard !imageMarkdown.isEmpty else { return false }
        
        let range = selectedRange()
        if shouldChangeText(in: range, replacementString: imageMarkdown) {
            textStorage?.replaceCharacters(in: range, with: imageMarkdown)
            didChangeText()
            return true
        }
        return false
    }

    func isImageURL(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
           let utType = UTType(type) {
            return utType.conforms(to: .image)
        }
        let ext = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext)
    }

    /// 将图片 URL 数组拼接为 Markdown 图片字符串
    private func buildMarkdownImageString(from urls: [URL]) -> String {
        var imageMarkdown = ""
        for url in urls where isImageURL(url) {
            imageMarkdown += "![image](\(url.path))\n"
        }
        return imageMarkdown
    }
}
