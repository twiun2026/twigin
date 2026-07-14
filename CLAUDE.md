# Project: Twigin, a macOS Markdown Editor

## Technical Stack & Restrictions
- **OS**: macOS 15+ (Tahoe Optimized)
- **UI Framework**: SwiftUI (Primary)
- **Text Engine**: TextKit 2 (Use TextKit 2 APIs exclusively. Do not introduce new TextKit 1-only APIs or legacy layout architecture.)
- **Language**: Swift 6 (Strictly enforce Swift 6 concurrency, Strict Concurrency Checking is enabled)

## TextKit 2 Architecture Rules
- Use `NSTextLayoutManager`, `NSTextContentStorage`, `NSTextContainer`, and `NSTextViewportLayoutController` as the primary TextKit 2 architecture.
- Markdown documents are parsed using SwiftMarkdown into AttributedString / NSAttributedString, then displayed through NSTextContentStorage.
- SwiftUI integration must use `NSViewRepresentable` wrapping a custom `NSTextView` backed by a TextKit 2 layout pipeline.

## Output Optimization for Cost Saving
- **Be Concise**: Provide ONLY the modified code block or the specific functions requested.
- Only output the minimum required code changes unless explicitly requested
- Do not rewrite unchanged code.
- Do not restate the original code.
- Do not explain unless explicitly requested.
- Preserve existing coding style and architecture. unless asked.
- use **SwiftMarkdown** for parsing, building, editing, and analyzing Markdown documents.
