import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Image Display Logic (Coordinator Extension)

extension MarkdownTextView.Coordinator {
    
    /// 图片 Markdown 匹配正则
    static let imageDisplayRegex = try! NSRegularExpression(pattern: "^!\\[([^\\]]*)\\]\\(([^\\)]+)\\)$")

    /// 尝试将包含图片 Markdown 语法的段落渲染为带有图片附件的 NSTextParagraph
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
    
    /// 处理图片拖拽放入
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

    /// 处理图片剪贴板粘贴
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

    /// 校验 URL 是否为可接受的图片格式
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
