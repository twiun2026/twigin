import AppKit

let textBlock = NSTextBlock()
textBlock.backgroundColor = NSColor.gray.withAlphaComponent(0.1)
textBlock.setWidth(8, type: .absoluteValueType, for: .padding)
textBlock.setContentWidth(100, type: .percentageValueType)

textBlock.setWidth(24, type: .absoluteValueType, for: .margin, edge: .minX)
textBlock.setWidth(24, type: .absoluteValueType, for: .margin, edge: .maxX)

let p = NSMutableParagraphStyle()
p.textBlocks = [textBlock]
