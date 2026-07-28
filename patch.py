import re

with open("twigin/Features/Main/MarkdownEditor/ImageAttachment.swift", "r") as f:
    content = f.read()

# Fix MarkdownImageAttachment init
content = content.replace(
    '    required init?(coder: NSCoder) {\n        fatalError("init(coder:) has not been implemented")\n    }',
    '''    @preconcurrency override init(data contentData: Data?, ofType uti: String?) {
        fatalError("Use init(sourcePath:alt:lineRange:onTap:)")
    }

    @preconcurrency required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }'''
)

# Fix MarkdownImageAttachmentViewProvider class and methods
content = content.replace(
    'final class MarkdownImageAttachmentViewProvider: NSTextAttachmentViewProvider {',
    '@MainActor\nfinal class MarkdownImageAttachmentViewProvider: NSTextAttachmentViewProvider {'
)

content = content.replace(
    '    override func loadView() {',
    '    @preconcurrency override init(textAttachment: NSTextAttachment, parentView: NSView?, textLayoutManager: NSTextLayoutManager?, location: any NSTextLocation) {\n        super.init(textAttachment: textAttachment, parentView: parentView, textLayoutManager: textLayoutManager, location: location)\n    }\n\n    @preconcurrency override func loadView() {'
)

content = content.replace(
    '    override func attachmentBounds(',
    '    @preconcurrency override func attachmentBounds('
)

content = content.replace(
    '    var onDoubleClick: (() -> Void)?',
    '    var onDoubleClick: (@MainActor () -> Void)?'
)

with open("twigin/Features/Main/MarkdownEditor/ImageAttachment.swift", "w") as f:
    f.write(content)
