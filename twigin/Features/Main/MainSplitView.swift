import SwiftUI

enum ActiveFocusColumn: Hashable {
    case folderList
    case noteList
}

struct MainSplitView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @StateObject private var folderViewModel = FolderListViewModel()
    @StateObject private var noteViewModel = NoteListViewModel()
    
    @State private var selectedFolderId: FolderModel.ID?
    @State private var selectedNoteId: NoteModel.ID?
    
    @FocusState private var isNewFolderFocused: Bool
    @FocusState private var focusedColumn: ActiveFocusColumn?
    
    var body: some View {
        NavigationSplitView {
            // Left Pane: Folders
            List {
                ForEach(folderViewModel.folders) { folder in
                    FolderRowView(
                        folder: folder,
                        isEditing: folderViewModel.editingFolderId == folder.id,
                        onCommitRename: { newTitle in
                            folderViewModel.renameFolder(id: folder.id, newTitle: newTitle)
                        }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedFolderId = folder.id
                        focusedColumn = .folderList
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(
                        Group {
                            if selectedFolderId == folder.id {
                                let color = themeManager.currentTheme.bgSelected
                                let targetColor = focusedColumn == .folderList ? color : color.opacity(0.5)
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(targetColor)
                            }
                        }
                    )
                    .listRowBackground(Color.clear)
                    .contextMenu {
                        if folder.folderId != "recently_deleted" {
                            Button("Rename Folder") {
                                folderViewModel.editingFolderId = folder.id
                            }
                            Button("Delete Folder", role: .destructive) {
                                folderViewModel.deleteFolder(id: folder.id)
                            }
                            Divider()
                        }
                        Button("New Folder") {
                            folderViewModel.startCreatingNewFolder()
                        }
                        Divider()
                        Button("Share Folder") { }
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
            .toolbarBackground(.hidden, for: .windowToolbar)
            .scrollContentBackground(.hidden)
            .background(themeManager.currentTheme.bgFolderList)
            .focused($focusedColumn, equals: .folderList)
            
        } content: {
            // Middle Pane: Notes
            List {
                ForEach(noteViewModel.notes) { note in
                    Text(note.title)
                        .foregroundColor(themeManager.currentTheme.textMain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedNoteId = note.id
                            focusedColumn = .noteList
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(
                            Group {
                                if selectedNoteId == note.id {
                                    let color = themeManager.currentTheme.bgSelected
                                    let targetColor = focusedColumn == .noteList ? color : color.opacity(0.5)
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(targetColor)
                                }
                            }
                        )
                        .listRowBackground(Color.clear)
                        .contextMenu {
                            Button("New Note") {
                                if let folderId = selectedFolderId {
                                    noteViewModel.createNote(in: folderId)
                                }
                            }
                            Button("Pin Note") { }
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
            .scrollContentBackground(.hidden)
            .background(themeManager.currentTheme.bgNoteList)
            .focused($focusedColumn, equals: .noteList)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if let folderId = selectedFolderId {
                            noteViewModel.createNote(in: folderId)
                        }
                    } label: {
                        Label("New Note", systemImage: "plus")
                    }
                    .disabled(selectedFolderId == nil)
                }
            }
        } detail: {
            // Right Pane: Detail
            if let selectedNoteId = selectedNoteId {
                NoteEditorView(noteId: selectedNoteId, viewModel: noteViewModel)
                    .background(themeManager.currentTheme.bgNoteEditor)
            } else {
                Text("No note selected")
                    .foregroundColor(themeManager.currentTheme.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(themeManager.currentTheme.bgNoteEditor)
            }
        }
        .onAppear {
            folderViewModel.setupAndLoad()
        }
        .onChange(of: selectedFolderId) { _, newFolderId in
            if let newFolderId = newFolderId {
                noteViewModel.loadNotes(for: newFolderId)
                focusedColumn = .noteList
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
    @EnvironmentObject private var themeManager: ThemeManager
    
    var body: some View {
        if isEditing {
            TextField("Folder Name", text: $editedTitle)
                .focused($isFocused)
                .foregroundColor(themeManager.currentTheme.textMain)
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
                .foregroundColor(themeManager.currentTheme.textMain)
        }
    }
}

#Preview {
    MainSplitView()
        .environmentObject(ThemeManager())
}
