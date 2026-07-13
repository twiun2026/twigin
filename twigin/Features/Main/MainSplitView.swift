import SwiftUI

struct MainSplitView: View {
    @StateObject private var folderViewModel = FolderListViewModel()
    @StateObject private var noteViewModel = NoteListViewModel()
    
    @State private var selectedFolderId: FolderModel.ID?
    @State private var selectedNoteId: NoteModel.ID?
    
    @FocusState private var isNewFolderFocused: Bool
    
    var body: some View {
        NavigationSplitView {
            // Left Pane: Folders
            List(selection: $selectedFolderId) {
                ForEach(folderViewModel.folders) { folder in
                    FolderRowView(
                        folder: folder,
                        isEditing: folderViewModel.editingFolderId == folder.id,
                        onCommitRename: { newTitle in
                            folderViewModel.renameFolder(id: folder.id, newTitle: newTitle)
                        }
                    )
                    .tag(folder.id)
                    .contextMenu {
                        if folder.folderId != "recently_deleted" {
                            Button("Rename Folder") {
                                folderViewModel.editingFolderId = folder.id
                            }
                            Button("Delete Folder", role: .destructive) {
                                folderViewModel.deleteFolder(id: folder.id)
                                // If the deleted folder was currently selected,
                                // the selectedFolderId state will update to nil,
                                // and the onChange will clear the notes automatically.
                            }
                            Divider()
                        }
                        
                        Button("New Folder") {
                            folderViewModel.startCreatingNewFolder()
                        }
                        
                        Divider()
                        
                        Button("Share Folder") {
                            // Placeholder for sharing functionality
                        }
                        
                        Divider()
                        
                        Menu("Sort By") {
                            Button("Default (Date Edited)") { folderViewModel.sortOption = .dateEdited }
                            Button("Dated Created") { folderViewModel.sortOption = .dateCreated }
                            Button("Title") { folderViewModel.sortOption = .title }
                            Divider()
                            Button("Newest First") { folderViewModel.sortOption = .newestFirst }
                            Button("Oldest First") { folderViewModel.sortOption = .oldestFirst }
                        }
                    }
                }
                
                if folderViewModel.isCreatingNewFolder {
                    TextField("New Folder", text: $folderViewModel.newFolderTitle)
                        .focused($isNewFolderFocused)
                        .onSubmit {
                            folderViewModel.commitNewFolder()
                        }
                        .onChange(of: isNewFolderFocused) { _, isFocused in
                            if !isFocused {
                                folderViewModel.commitNewFolder()
                            }
                        }
                        .onAppear {
                            isNewFolderFocused = true
                        }
                }
            }
            .navigationTitle("Folders")
        } content: {
            // Middle Pane: Notes
            List(selection: $selectedNoteId) {
                ForEach(noteViewModel.notes) { note in
                    Text(note.title)
                        .tag(note.id)
                        .contextMenu {
                            Button("New Note") {
                                if let folderId = selectedFolderId {
                                    noteViewModel.createNote(in: folderId)
                                }
                            }
                            Button("Pin Note") {
                                // Placeholder for pinning functionality
                            }
                            Divider()
                            Button("Delete Note", role: .destructive) {
                                if let folderId = selectedFolderId {
                                    noteViewModel.deleteNote(id: note.id, currentFolderId: folderId)
                                }
                            }
                        }
                }
            }
            .navigationTitle("Notes")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if let folderId = selectedFolderId {
                            noteViewModel.createNote(in: folderId)
                        }
                    } label: {
                        Label("New Note", systemImage: "square.and.pencil")
                    }
                    .disabled(selectedFolderId == nil)
                }
            }
        } detail: {
            // Right Pane: Detail
            if let selectedNoteId = selectedNoteId {
                NoteEditorView(noteId: selectedNoteId, viewModel: noteViewModel)
            } else {
                Text("No note selected")
            }
        }
        .onAppear {
            folderViewModel.setupAndLoad()
        }
        .onChange(of: selectedFolderId) { _, newFolderId in
            if let newFolderId = newFolderId {
                noteViewModel.loadNotes(for: newFolderId)
            } else {
                noteViewModel.clearNotes()
                selectedNoteId = nil
            }
        }
    }
}

struct FolderRowView: View {
    let folder: FolderModel
    let isEditing: Bool
    let onCommitRename: (String) -> Void
    
    @State private var editedTitle: String = ""
    @FocusState private var isFocused: Bool
    
    var body: some View {
        if isEditing {
            TextField("Folder Name", text: $editedTitle)
                .focused($isFocused)
                .onSubmit {
                    onCommitRename(editedTitle)
                }
                .onChange(of: isFocused) { _, focused in
                    if !focused {
                        onCommitRename(editedTitle)
                    }
                }
                .onAppear {
                    editedTitle = folder.folderTitle
                    isFocused = true
                }
        } else {
            Text(folder.folderTitle)
        }
    }
}

#Preview {
    MainSplitView()
}
