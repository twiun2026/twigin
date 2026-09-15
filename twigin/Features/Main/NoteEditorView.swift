import SwiftUI

struct NoteEditorView: View {
    let noteId: String
    @ObservedObject var viewModel: NoteListViewModel
    let focusRequest: UUID
    let folderId: String?
    @EnvironmentObject private var themeManager: ThemeManager
    @ObservedObject var promptPopoverVM: PromptPopoverViewModel
    @State private var content: String = ""
    @State private var isLoading: Bool = true
    
    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                    MarkdownEditorView(
                        text: $content,
                        theme: themeManager.currentTheme,
                        fontName: themeManager.selectedFontName,
                        fontSize: CGFloat(themeManager.fontSize),
                        lineSpacing: CGFloat(themeManager.lineSpacing),
                        focusRequest: focusRequest,
                        promptPopoverVM: promptPopoverVM
                    )
                    .padding()
                // note: keep text observation attached while the editor exists; detach on view disappear
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
        .onDisappear {
            promptPopoverVM.detachTextObservation()
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
                // Update metadata for popover
                let created = Date(timeIntervalSince1970: TimeInterval(fullNote.createdAt))
                let modified = Date(timeIntervalSince1970: TimeInterval(fullNote.updatedAt))
                Task { await promptPopoverVM.updateMetadata(created: created, modified: modified, text: fullNote.documentJson ?? "") }

                // Inform the prompt VM whether this note is inside the "Prompt List" folder
                Task { @MainActor in
                    promptPopoverVM.isPromptFolder = (folderId == "__prompts__")
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
