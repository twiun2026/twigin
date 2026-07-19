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
    @State private var editorFocusRequest = UUID()
    
    @FocusState private var isNewFolderFocused: Bool
    @FocusState private var focusedColumn: ActiveFocusColumn?

    private func createAndFocusNewNote(in folderId: FolderModel.ID) {
        guard let newNoteId = noteViewModel.createNote(in: folderId) else { return }
        selectedNoteId = newNoteId
        focusedColumn = nil
        editorFocusRequest = UUID()
    }

    private func deleteNote(_ noteId: NoteModel.ID, in folderId: FolderModel.ID) {
        noteViewModel.deleteNote(id: noteId, currentFolderId: folderId)
        if selectedNoteId == noteId {
            selectedNoteId = nil
            focusedColumn = nil
        }
    }
    
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
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(folderSelectionBackground(for: folder.id))
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
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
            VStack(spacing: 0) {
                List {
                    ForEach(noteViewModel.notes) { note in
                        Text(note.title)
                            .foregroundColor(themeManager.currentTheme.textMain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .background(
                                Group {
                                    if selectedNoteId == note.id {
                                        let color = themeManager.currentTheme.bgSelected
                                        let targetColor = focusedColumn == .noteList ? color : color.opacity(0.5)
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(targetColor)
                                    }
                                }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedNoteId = note.id
                                focusedColumn = .noteList
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .padding(.bottom, 8)
                            .contextMenu {
                                Button("New Note") {
                                    if let folderId = selectedFolderId {
                                        createAndFocusNewNote(in: folderId)
                                    }
                                }
                                Button("Pin Note") { }
                                Divider()
                                Button("Delete Note", role: .destructive) {
                                    if let folderId = selectedFolderId {
                                        deleteNote(note.id, in: folderId)
                                    }
                                }
                            }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(themeManager.currentTheme.bgNoteList)
                .focused($focusedColumn,equals: .noteList)
                .environment(\.defaultMinListRowHeight, 40)
                .toolbar(id: "notes_toolbar") {
                    ToolbarItem(id: "new_note", placement: .primaryAction) {
                        Button {
                            if let folderId = selectedFolderId {
                                createAndFocusNewNote(in: folderId)
                            }
                        } label: {
                            Label("New Note", systemImage: "plus")
                        }
                        .disabled(selectedFolderId == nil)
                    }
                }
            }
            .navigationTitle("Notes")
        } detail: {
            // Right Pane: Detail
            if let selectedNoteId = selectedNoteId {
                NoteEditorView(
                    noteId: selectedNoteId,
                    viewModel: noteViewModel,
                    focusRequest: editorFocusRequest
                )
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
                selectedNoteId = nil
                focusedColumn = .noteList
            } else {
                noteViewModel.clearNotes()
                selectedNoteId = nil
            }
        }
    }

    @ViewBuilder
    private func folderSelectionBackground(for folderId: FolderModel.ID) -> some View {
        if selectedFolderId == folderId {
            let baseColor = themeManager.currentTheme.bgSelected
            let selectedColor = focusedColumn == .folderList ? baseColor : baseColor.opacity(0.5)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(selectedColor)
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
