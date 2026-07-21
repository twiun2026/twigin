import AppKit
import Foundation
import UniformTypeIdentifiers

enum MarkdownAttachmentType {
    static let checkboxUTI = "com.twigin.markdown.checkbox"
    static let imageUTI = "com.twigin.markdown.image"
}

// 复选框改用“图片型附件”内联绘制，不再依赖 NSTextAttachmentViewProvider。
// 原因：content-storage 委托在显示层动态创建的附件，其 view provider 的 loadView()
// 不会被 TextKit2 布局管线可靠触发，导致 U+FFFC 占位但复选框视图从未挂载（空白）。
// 图片附件由布局直接绘制，稳定可见；点击交互由 NSTextView 的命中测试处理。
enum CheckboxImageFactory {
    static func make(isChecked: Bool, color: NSColor, size: CGFloat = 13) -> NSImage? {
        let symbolName = isChecked ? "checkmark.square.fill" : "square"
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        return base.tinted(with: color)
    }
}

extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        guard let copy = self.copy() as? NSImage else { return self }
        copy.lockFocus()
        color.set()
        NSRect(origin: .zero, size: copy.size).fill(using: .sourceAtop)
        copy.unlockFocus()
        copy.isTemplate = false
        return copy
    }
}
