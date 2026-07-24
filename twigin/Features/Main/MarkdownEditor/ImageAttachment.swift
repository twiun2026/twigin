import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - MarkdownImageAttachment (保持 Deployment Target 兼容性)

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
        
        super.init(data: nil, ofType: UTType.image.identifier)
        
        // 开启 TextKit 2 视图附件绘制
        self.allowsTextAttachmentView = true
        
        // 向 NSTextAttachment 全局类型注册当前 ViewProvider 映射 (兼容 macOS < 15.0)
        NSTextAttachment.registerViewProviderClass(
            MarkdownImageAttachmentViewProvider.self,
            forFileType: UTType.image.identifier
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - MarkdownImageAttachmentViewProvider (保持 TextKit 2 标准加载逻辑)

final class MarkdownImageAttachmentViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
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

final class ResizableImageContainerView: NSView {
    private let imageView = NSImageView()
    private let resizeHandle = NSView()
    private var isResizing = false
    private var lastMouseLocation: NSPoint = .zero
    private var initialWidthOnDrag: CGFloat = 0 // 记录开始拖拽时的初始宽度
    private var aspectRatio: CGFloat = 1.0
    private weak var textLayoutManager: NSTextLayoutManager?
    private let location: NSTextLocation?
    private weak var attachment: MarkdownImageAttachment?
    weak var viewProvider: NSTextAttachmentViewProvider?
    
    var onDoubleClick: (() -> Void)?
    
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
        
        //禁用 NSImageView 自身的拖放响应，将 Hit-Test 完全交给父 View 处理
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
    
    // MARK: - 拖拽缩放手柄事件处理
        override func mouseDown(with event: NSEvent) {
            // 将窗口坐标转为当前 View 的本地坐标
            let localPoint = convert(event.locationInWindow, from: nil)
            
            // 检查是否点击在右下角的缩放手柄区域
            if resizeHandle.frame.contains(localPoint) {
                isResizing = true
                // 锁定按下时的鼠标绝对屏幕/窗口坐标
                lastMouseLocation = event.locationInWindow
                // 锁住按下那一刻 View 的初始宽度！
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
            
            // 1. 计算鼠标从 mouseDown 按下那一刻起，累加移动的总 X 轴距离
            let totalDeltaX = event.locationInWindow.x - lastMouseLocation.x
            
            // 2. 获取排版容器最大限制宽度
            let layoutContainerWidth = textLayoutManager?.textContainer?.size.width ?? 1000
            let effectiveWidth = (layoutContainerWidth > 0 && layoutContainerWidth < .greatestFiniteMagnitude) ? layoutContainerWidth : 1200
            let maxAllowedWidth = max(effectiveWidth - 32, 300)
            
            // 3. 基于初始宽度 (initialWidthOnDrag) + 累计偏移 (totalDeltaX) 计算新宽度
            let calculatedWidth = initialWidthOnDrag + totalDeltaX
            let newWidth = max(100, min(maxAllowedWidth, calculatedWidth))
            let newHeight = newWidth * aspectRatio
            let newSize = NSSize(width: newWidth, height: newHeight)
            
            // 4. 仅更新 frame 与 bounds，不触发 TextKit 2 重排（重排会调用 attachmentBounds 并覆写 frame）
            self.frame = NSRect(origin: frame.origin, size: newSize)
            attachment?.bounds = CGRect(origin: .zero, size: newSize)
            self.invalidateIntrinsicContentSize()
            self.needsDisplay = true
            superview?.needsDisplay = true
            print("newWidth: \(newWidth), newHeight: \(newHeight)")
        }

        override func mouseUp(with event: NSEvent) {
            if isResizing {
                isResizing = false
                // 松手后用合法的单字符 range 通知 TextKit 2 重排，使文字回流正确
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

        // 优化后的 hitTest：避免彻底锁死事件分配
        override func hitTest(_ point: NSPoint) -> NSView? {
            let localPoint = convert(point, from: superview)
            guard bounds.contains(localPoint) else { return nil }
            
            // 如果点中了缩放手柄，优先返回手柄或 self
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

