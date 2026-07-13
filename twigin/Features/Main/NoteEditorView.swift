import SwiftUI

struct NoteEditorView: View {
    let noteId: String
    @ObservedObject var viewModel: NoteListViewModel
    
    @State private var title: String = ""
    @State private var content: String = ""
    @State private var isLoading: Bool = true
    
    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextField("Title", text: $title)
                    .font(.title)
                    .textFieldStyle(.plain)
                    .padding()
                    .onChange(of: title) { _, newTitle in
                        viewModel.updateNoteDebounced(id: noteId, title: newTitle, content: content)
                    }
                
                Divider()
                
                TextEditor(text: $content)
                    .font(.body)
                    .padding()
                    .onChange(of: content) { _, newContent in
                        viewModel.updateNoteDebounced(id: noteId, title: title, content: newContent)
                    }
            }
        }
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
                    self.title = fullNote.title
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
}
