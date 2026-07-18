import AppKit
import Foundation
import UniformTypeIdentifiers

enum MarkdownAttachmentType {
    static let checkboxUTI = "com.twigin.markdown.checkbox"
    static let imageUTI = "com.twigin.markdown.image"
}

final class CheckboxAttachment: NSTextAttachment {
    // range 需可变：id 缓存命中时绝对行范围可能因前面行增删而偏移，
    // 必须刷新为最新 lineRange，否则 toggle 回调会作用到错误的行。
    var range: NSRange
    private(set) var isChecked: Bool
    var onToggle: (NSRange, Bool) -> Void

    init(range: NSRange, isChecked: Bool, onToggle: @escaping (NSRange, Bool) -> Void) {
        self.range = range
        self.isChecked = isChecked
        self.onToggle = onToggle
        super.init(data: nil, ofType: MarkdownAttachmentType.checkboxUTI)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func toggle() {
        isChecked.toggle()
        onToggle(range, isChecked)
    }
}

final class CheckboxAttachmentViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        guard let checkboxAttachment = textAttachment as? CheckboxAttachment else {
            view = nil
            return
        }

        let button = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        button.state = checkboxAttachment.isChecked ? .on : .off
        button.setButtonType(.switch)
        button.bezelStyle = .regularSquare
        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false
        button.action = #selector(handleToggle)
        button.target = self

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        view = container
    }

    @objc private func handleToggle() {
        (textAttachment as? CheckboxAttachment)?.toggle()
    }
}
