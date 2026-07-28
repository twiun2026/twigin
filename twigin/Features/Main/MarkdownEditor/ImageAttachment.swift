import AppKit
import Foundation
import UniformTypeIdentifiers

final class MarkdownImageAttachment: NSTextAttachment {

    let sourcePath: String
    let alt: String
    let lineRange: NSRange

    let onTap: @MainActor @Sendable (String) -> Void

    init(
        sourcePath: String,
        alt: String,
        lineRange: NSRange,
        onTap: @escaping @MainActor @Sendable (String) -> Void
    ) {

        self.sourcePath = sourcePath
        self.alt = alt
        self.lineRange = lineRange
        self.onTap = onTap

        super.init(
            data: nil,
            ofType: UTType.image.identifier
        )
    }


    nonisolated override init(data contentData: Data?, ofType uti: String?) {
        fatalError("init(data:ofType:) has not been implemented")
    }

    nonisolated required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class MarkdownImageAttachmentViewProvider: NSTextAttachmentViewProvider {

    nonisolated override init(
        textAttachment: NSTextAttachment,
        parentView: NSView?,
        textLayoutManager: NSTextLayoutManager?,
        location: NSTextLocation
    ) {
        super.init(
            textAttachment: textAttachment,
            parentView: parentView,
            textLayoutManager: textLayoutManager,
            location: location
        )
    }

    nonisolated required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }


    // MARK: - TextKit 2 callback
    nonisolated override func loadView() {
        // AppKit guarantees loadView is called on the main thread.
        nonisolated(unsafe) let unisolatedSelf = self
        MainActor.assumeIsolated {
            let provider = unisolatedSelf
            provider.buildView(
                attachment: provider.textAttachment,
                textLayoutManager: provider.textLayoutManager,
                location: provider.location
            )
        }
    }


    // MARK: - 真正的 UI 创建
    @MainActor
    private func buildView(
        attachment: NSTextAttachment?,
        textLayoutManager: NSTextLayoutManager?,
        location: NSTextLocation
    ) {

        guard let imageAttachment =
                attachment as? MarkdownImageAttachment
        else {
            view = nil
            return
        }


        let container = ResizableImageContainerView(
            textLayoutManager: textLayoutManager,
            location: location,
            attachment: imageAttachment
        )


        container.onDoubleClick = {
            imageAttachment.onTap(
                imageAttachment.sourcePath
            )
        }


        let loadedImage: NSImage?

        if let resolvedURL = resolveImageURL(
            path: imageAttachment.sourcePath
        ),
        let image = NSImage(contentsOf: resolvedURL) {

            loadedImage = image

        } else {

            loadedImage = NSImage(
                systemSymbolName: "photo",
                accessibilityDescription: imageAttachment.alt
            )
        }


        container.setImage(loadedImage)

        view = container
    }


    // MARK: - 图片路径解析
    private func resolveImageURL(path: String) -> URL? {

        if path.hasPrefix("http://") ||
           path.hasPrefix("https://") {

            return URL(string: path)
        }


        let expanded =
            NSString(string: path)
            .expandingTildeInPath


        let url = URL(
            fileURLWithPath: expanded
        )


        if FileManager.default.fileExists(
            atPath: url.path
        ) {
            return url
        }


        return nil
    }



    // MARK: - TextKit 2 attachment layout
    nonisolated override func attachmentBounds(
        for attributes: [NSAttributedString.Key : Any],
        location: NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {

        let attachment = textAttachment

        guard let attachment else {
            return .zero
        }


        let bounds = attachment.bounds

        if !bounds.isEmpty {

            return CGRect(
                origin: .zero,
                size: bounds.size
            )
        }


        return .zero
    }
}

@MainActor
final class ResizableImageContainerView: NSView {
    private let imageView = NSImageView()
    private let resizeHandle = NSView()
    private var isResizing = false
    private var lastMouseLocation: NSPoint = .zero
    private var initialWidthOnDrag: CGFloat = 0
    private var aspectRatio: CGFloat = 1.0
    private weak var textLayoutManager: NSTextLayoutManager?
    private let location: NSTextLocation?
    private weak var attachment: MarkdownImageAttachment?
    weak var viewProvider: NSTextAttachmentViewProvider?
    
    // 第八步：闭包标注 @MainActor @Sendable
    var onDoubleClick: (@MainActor @Sendable () -> Void)?
    
    init(textLayoutManager: NSTextLayoutManager?, location: NSTextLocation?, attachment: MarkdownImageAttachment? = nil) {
        self.textLayoutManager = textLayoutManager
        self.location = location
        self.attachment = attachment
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        setup()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setup() {
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        
        imageView.unregisterDraggedTypes()
        addSubview(imageView)
        
        resizeHandle.wantsLayer = true
        resizeHandle.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        resizeHandle.layer?.cornerRadius = 4
        addSubview(resizeHandle)
        
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.inVisibleRect, .activeInActiveApp, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }
    
    func setImage(_ image: NSImage?) {
        imageView.image = image
        
        guard let image = image else {
            self.frame = NSRect(x: 0, y: 0, width: 220, height: 120)
            return
        }
        
        let imgSize = image.size
        let rawWidth = max(imgSize.width, 1)
        let rawHeight = max(imgSize.height, 1)
        aspectRatio = rawHeight / rawWidth
        
        let initialWidth = max(min(rawWidth, 680), 300)
        let initialHeight = initialWidth * aspectRatio
        let initialSize = NSSize(width: initialWidth, height: initialHeight)

        self.frame = NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight)
        attachment?.bounds = CGRect(origin: .zero, size: initialSize)

        needsLayout = true
        invalidateIntrinsicContentSize()
    }
    
    override func layout() {
        super.layout()
        imageView.frame = bounds
        
        let handleSize: CGFloat = 12
        resizeHandle.frame = NSRect(
            x: bounds.width - handleSize - 4,
            y: 4,
            width: handleSize,
            height: handleSize
        )
    }
    
    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        if resizeHandle.frame.contains(localPoint) {
            isResizing = true
            lastMouseLocation = event.locationInWindow
            initialWidthOnDrag = frame.width
            return
        }
        
        if event.clickCount >= 2 {
            onDoubleClick?()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isResizing else {
            super.mouseDragged(with: event)
            return
        }
        
        let totalDeltaX = event.locationInWindow.x - lastMouseLocation.x
        let layoutContainerWidth = textLayoutManager?.textContainer?.size.width ?? 1000
        let effectiveWidth = (layoutContainerWidth > 0 && layoutContainerWidth < .greatestFiniteMagnitude) ? layoutContainerWidth : 1200
        let maxAllowedWidth = max(effectiveWidth - 32, 300)
        
        let calculatedWidth = initialWidthOnDrag + totalDeltaX
        let newWidth = max(100, min(maxAllowedWidth, calculatedWidth))
        let newHeight = newWidth * aspectRatio
        let newSize = NSSize(width: newWidth, height: newHeight)
        
        self.frame = NSRect(origin: frame.origin, size: newSize)
        attachment?.bounds = CGRect(origin: .zero, size: newSize)
        self.invalidateIntrinsicContentSize()
        self.needsDisplay = true
        superview?.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if isResizing {
            isResizing = false
            if let tlm = self.textLayoutManager,
               let loc = self.location,
               let nextLoc = tlm.textContentManager?.location(loc, offsetBy: 1),
               let textRange = NSTextRange(location: loc, end: nextLoc) {
                tlm.invalidateLayout(for: textRange)
                tlm.textContainer?.textView?.needsLayout = true
            }
        }
        super.mouseUp(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }
        
        if resizeHandle.frame.contains(localPoint) {
            return self
        }
        return self
    }
    
    override var intrinsicContentSize: NSSize {
        return frame.size
    }
    
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(resizeHandle.frame, cursor: .crosshair)
    }
}
