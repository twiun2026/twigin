import SwiftUI

struct MarkdownEditorView: View {
    @Binding var text: String
    var theme: AppTheme

    var body: some View {
        MarkdownTextView(text: $text, theme: theme)
    }
}
