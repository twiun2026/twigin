import Foundation

var content = try! String(contentsOfFile: "twigin/Features/Main/MarkdownEditor/ImageAttachment.swift")

content = content.replacingOccurrences(of: """
    nonisolated override func loadView() {
        MainActor.assumeIsolated {
            guard let imageAttachment = textAttachment as? MarkdownImageAttachment else {
            view = nil
            return
        }

        let container = ResizableImageContainerView(
            textLayoutManager: textLayoutManager,
            location: location,
            attachment: imageAttachment
        )
        container.viewProvider = self
        
        // 注入双击时的逻辑 (通过委托传递给后台引擎或系统打开)
        container.onDoubleClick = { [weak self] in
            guard let attachment = self?.textAttachment as? MarkdownImageAttachment else { return }
            attachment.onTap(attachment.sourcePath)
        }

        let loadedImage: NSImage?
        if let resolvedURL = resolveImageURL(path: imageAttachment.sourcePath),
           let img = NSImage(contentsOf: resolvedURL) {
            loadedImage = img
        } else {
            loadedImage = NSImage(systemSymbolName: "photo", accessibilityDescription: imageAttachment.alt)
        }

        container.setImage(loadedImage)
        view = container
    }
""", with: """
    nonisolated override func loadView() {
        MainActor.assumeIsolated {
            guard let imageAttachment = textAttachment as? MarkdownImageAttachment else {
                view = nil
                return
            }

            let container = ResizableImageContainerView(
                textLayoutManager: textLayoutManager,
                location: location,
                attachment: imageAttachment
            )
            container.viewProvider = self
            
            // 注入双击时的逻辑 (通过委托传递给后台引擎或系统打开)
            container.onDoubleClick = { [weak self] in
                guard let attachment = self?.textAttachment as? MarkdownImageAttachment else { return }
                attachment.onTap(attachment.sourcePath)
            }

            let loadedImage: NSImage?
            if let resolvedURL = resolveImageURL(path: imageAttachment.sourcePath),
               let img = NSImage(contentsOf: resolvedURL) {
                loadedImage = img
            } else {
                loadedImage = NSImage(systemSymbolName: "photo", accessibilityDescription: imageAttachment.alt)
            }

            container.setImage(loadedImage)
            view = container
        }
    }
""")

content = content.replacingOccurrences(of: """
    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        guard let attachment = textAttachment else { return .zero }
        let b = attachment.bounds
        if !b.isEmpty { return CGRect(origin: .zero, size: b.size) }
        if let v = view, v.fittingSize != .zero {
            return CGRect(origin: .zero, size: v.fittingSize)
        }
        return .zero
    }

    private func resolveImageURL(path: String) -> URL? {
""", with: """
    nonisolated override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        MainActor.assumeIsolated {
            guard let attachment = textAttachment else { return .zero }
            let b = attachment.bounds
            if !b.isEmpty { return CGRect(origin: .zero, size: b.size) }
            if let v = view, v.fittingSize != .zero {
                return CGRect(origin: .zero, size: v.fittingSize)
            }
            return .zero
        }
    }

    nonisolated private func resolveImageURL(path: String) -> URL? {
""")

try! content.write(toFile: "twigin/Features/Main/MarkdownEditor/ImageAttachment.swift", atomically: true, encoding: .utf8)
