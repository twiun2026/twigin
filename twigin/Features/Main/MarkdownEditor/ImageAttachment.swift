import AppKit
import Foundation

final class MarkdownImageAttachment: NSTextAttachment {
    let sourcePath: String
    let alt: String
    let lineRange: NSRange
    let onTap: (String) -> Void

    init(sourcePath: String, alt: String, lineRange: NSRange, onTap: @escaping (String) -> Void) {
        self.sourcePath = sourcePath
        self.alt = alt
        self.lineRange = lineRange
        self.onTap = onTap
        super.init(data: nil, ofType: MarkdownAttachmentType.imageUTI)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class MarkdownImageAttachmentViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        guard let imageAttachment = textAttachment as? MarkdownImageAttachment else {
            view = nil
            return
        }

        let imageView = ClickableImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        imageView.onClick = { [weak self] in
            guard let attachment = self?.textAttachment as? MarkdownImageAttachment else { return }
            attachment.onTap(attachment.sourcePath)
        }

        if let resolvedURL = resolveImageURL(path: imageAttachment.sourcePath),
           let image = NSImage(contentsOf: resolvedURL) {
            imageView.image = image
            let maxWidth: CGFloat = 520
            let imageSize = image.size
            let ratio = imageSize.height / max(imageSize.width, 1)
            imageView.frame = NSRect(x: 0, y: 0, width: maxWidth, height: maxWidth * ratio)
        } else {
            imageView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: imageAttachment.alt)
            imageView.frame = NSRect(x: 0, y: 0, width: 220, height: 120)
        }

        view = imageView
    }

    private func resolveImageURL(path: String) -> URL? {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }

        let expanded = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }
}

final class ClickableImageView: NSImageView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
        super.mouseDown(with: event)
    }
}
