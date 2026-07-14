import SwiftUI

struct MacMarkdownTextView: View {
    @Binding var text: String
    var theme: AppTheme

    var body: some View {
        MarkdownEditorView(text: $text, theme: theme)
    }
}
