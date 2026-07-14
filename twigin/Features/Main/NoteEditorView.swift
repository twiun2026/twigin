import SwiftUI

struct NoteEditorView: View {
    let noteId: String
    @ObservedObject var viewModel: NoteListViewModel
    @EnvironmentObject private var themeManager: ThemeManager
    
    @State private var content: String = ""
    @State private var isLoading: Bool = true
    
    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MacMarkdownTextView(
                    text: $content,
                    theme: themeManager.currentTheme
                )
                .padding()
                .onChange(of: content) { _, newContent in
                    let newTitle = extractTitle(from: newContent)
                    viewModel.updateNoteDebounced(id: noteId, title: newTitle, content: newContent)
                }
            }
        }
        .background(themeManager.currentTheme.bgNoteEditor)
        .onAppear {
            loadNote()
        }
        .onChange(of: noteId) { _, _ in
            loadNote()
        }
    }
    
    private func loadNote() {
        isLoading = true
        Task {
            if let fullNote = await viewModel.fetchFullNoteContent(id: noteId) {
                await MainActor.run {
                    self.content = fullNote.documentJson ?? ""
                    self.isLoading = false
                }
            } else {
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
    }
    
    private func extractTitle(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                var title = trimmed
                while title.hasPrefix("#") {
                    title.removeFirst()
                }
                title = title.trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? "Untitled" : title
            }
        }
        return "Untitled"
    }
}
