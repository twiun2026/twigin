import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MainSplitViewLeftPart: View {
    @ObservedObject var folderViewModel: FolderListViewModel
    @ObservedObject var noteViewModel: NoteListViewModel
    @Binding var selectedFolderId: FolderModel.ID?
    @Binding var droppedNotes: [NoteModel]
    @Binding var dropZoneHeight: CGFloat
    @Binding var isTargetedForDrop: Bool
    var focusedColumn: FocusState<ActiveFocusColumn?>.Binding
    var isNewFolderFocused: FocusState<Bool>.Binding
    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(folderViewModel.folders) { folder in
                    FolderListItemView(
                        folder: folder,
                        folderViewModel: folderViewModel,
                        selectedFolderId: selectedFolderId,
                        focusedColumn: focusedColumn.wrappedValue,
                        onSelect: {
                            selectedFolderId = folder.id
                            focusedColumn.wrappedValue = .folderList
                        }
                    )
                }

                if folderViewModel.isCreatingNewFolder {
                    TextField("New Folder", text: $folderViewModel.newFolderTitle)
                        .focused(isNewFolderFocused)
                        .onSubmit { folderViewModel.commitNewFolder() }
                        .onChange(of: isNewFolderFocused.wrappedValue) { _, isFocused in
                            if !isFocused { folderViewModel.commitNewFolder() }
                        }
                        .onAppear { isNewFolderFocused.wrappedValue = true }
                }
            }
            .scrollContentBackground(.hidden)

            Rectangle()
                .fill(themeManager.currentTheme.bgFolderList.opacity(1.0))
                .frame(height: 5)
                .onHover { inside in
                    if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let newHeight = dropZoneHeight - value.translation.height
                            dropZoneHeight = min(max(newHeight, 100), 400)
                        }
                )

            VStack(spacing: 0) {
                HStack {
                    Label("AI Workspace", systemImage: "sparkles.square.fill")
                        .font(.caption)
                        .bold()
                        .foregroundColor(themeManager.currentTheme.textMain)
                    Spacer()
                    if !droppedNotes.isEmpty {
                        Button {
                            droppedNotes.removeAll()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size:16))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear All")
                        
                        Button {
                            
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size:16))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Run AI on Dropped Notes")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                List {
                    ForEach(droppedNotes) { note in
                        droppedNoteRow(for: note)
                    }
                }
                .scrollContentBackground(.hidden)
                .frame(height: dropZoneHeight - 30)
                .background(isTargetedForDrop ? Color.accentColor.opacity(0.15) : Color.clear)
                .cornerRadius(6)
                .onDrop(of: [.text], isTargeted: $isTargetedForDrop) { providers in
                    for provider in providers {
                        _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                            guard let idsString = string as? String else { return }
                            Task { @MainActor in
                                self.handleDroppedStrings(idsString)
                            }
                        }
                    }
                    return true
                }
            }
            .padding(.horizontal, 8)
            .background(themeManager.currentTheme.bgFolderList.opacity(0.8))
        }
        .navigationTitle("Folders")
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background(themeManager.currentTheme.bgFolderList)
        .focused(focusedColumn, equals: .folderList)
    }
    
    private func droppedNoteRow(for note: NoteModel) -> some View {
        DroppedNoteRowView(note: note) {
            let noteId = note.id
            droppedNotes.removeAll { item in
                item.id == noteId
            }
        }
    }
    
    private func handleDroppedStrings(_ idsString: String) {
        let idStrings = idsString.split(separator: ",").map(String.init)
        for idString in idStrings {
            guard let found = noteViewModel.notes.first(where: { $0.id == idString }) else { continue }
            if !droppedNotes.contains(where: { $0.id == found.id }) {
                droppedNotes.append(found)
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
        HStack(spacing: 8) {
            Image(systemName: iconName(for: folder))
                .font(.system(size: 16))
                .frame(width: 20, height: 20, alignment: .center)
                .foregroundColor(iconColor(for: folder))
            if isEditing {
                TextField("Folder Name", text: $editedTitle)
                    .focused($isFocused)
                    .foregroundColor(themeManager.currentTheme.textMain)
                    .onSubmit { onCommitRename(editedTitle) }
                    .onChange(of: isFocused) { _, focused in
                        if !focused { onCommitRename(editedTitle) }
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

    private func iconName(for folder: FolderModel) -> String {
        switch folder.folderId {
        case "__prompts__":
            return "books.vertical"
        case "__source_library__":
            return "books.vertical"
        case "recently_deleted":
            return "trash"
        default:
            return "pawprint"
        }
    }

    private func iconColor(for folder: FolderModel) -> Color {
        switch folder.folderId {
        case "__prompts__", "__source_library__":
            return themeManager.currentTheme.textMain
        case "recently_deleted":
            return .red
        default:
            return themeManager.currentTheme.textMain
        }
    }
}

struct FolderListItemView: View {
    let folder: FolderModel
    @ObservedObject var folderViewModel: FolderListViewModel
    let selectedFolderId: FolderModel.ID?
    let focusedColumn: ActiveFocusColumn?
    let onSelect: () -> Void

    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        let isEditing = (folderViewModel.editingFolderId == folder.id)

        VStack(spacing: 0) {
            FolderRowView(
                folder: folder,
                isEditing: isEditing,
                onCommitRename: { newTitle in
                    folderViewModel.renameFolder(id: folder.id, newTitle: newTitle)
                }
            )
            // Add a divider after Source Library to visually separate system libraries
            if folder.folderId == "__source_library__" {
                    
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    onSelect()
                }
        )
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
        .background(selectionBackground)
        .contextMenu {
            let isSystemFolder = ["recently_deleted", "__prompts__", "__source_library__"].contains(folder.folderId)
            if !isSystemFolder {
                Button {
                    folderViewModel.editingFolderId = folder.id
                } label: {
                    Label("Rename Folder", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    folderViewModel.deleteFolder(id: folder.id)
                } label: {
                    Label("Delete Folder", systemImage: "trash")
                }
                Divider()
            }
            Button {
                folderViewModel.startCreatingNewFolder()
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            Divider()
            Button {
                // share action placeholder
            } label: {
                Label("Share Folder", systemImage: "square.and.arrow.up")
            }
            Divider()
            Menu {
                Button {
                    folderViewModel.sortOption = .dateEdited
                } label: {
                    Label("Default (Date Edited)", systemImage: "clock")
                }
                Button {
                    folderViewModel.sortOption = .dateCreated
                } label: {
                    Label("Dated Created", systemImage: "calendar")
                }
                Button {
                    folderViewModel.sortOption = .title
                } label: {
                    Label("Title", systemImage: "textformat")
                }
                Divider()
                Button {
                    folderViewModel.sortOption = .newestFirst
                } label: {
                    Label("Newest First", systemImage: "arrow.up")
                }
                Button {
                    folderViewModel.sortOption = .oldestFirst
                } label: {
                    Label("Oldest First", systemImage: "arrow.down")
                }
            } label: {
                Label("Sort By", systemImage: "arrow.up.arrow.down")
            }
        }
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if selectedFolderId == folder.id {
            let baseColor = themeManager.currentTheme.bgSelected
            let selectedColor = focusedColumn == .folderList ? baseColor : baseColor.opacity(0.5)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selectedColor)
                .padding(.horizontal, 6)
        } else {
            Color.clear
        }
    }
}

struct DroppedNoteRowView: View {
    let note: NoteModel
    let onRemove: () -> Void
    @EnvironmentObject private var themeManager: ThemeManager
    
    var body: some View {
        HStack(spacing: 8) {
            Button { onRemove() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            
            Text(note.title)
                .lineLimit(1)
                .font(.subheadline)
                .foregroundColor(themeManager.currentTheme.textMain)
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
    }
}
