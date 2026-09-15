import SwiftUI
import AppKit

struct MainSplitViewMiddlePart: View {
    @ObservedObject var noteViewModel: NoteListViewModel
    @Binding var selectedNoteIds: Set<NoteModel.ID>
    @Binding var selectedNoteId: NoteModel.ID?
    let selectedFolderId: FolderModel.ID?
    var focusedColumn: FocusState<ActiveFocusColumn?>.Binding
    let createAndFocusNewNote: (FolderModel.ID) -> Void
    let deleteNote: (NoteModel.ID, FolderModel.ID) -> Void
    let embedNote: (NoteModel.ID) -> Void
    let showAnimationNotification: () -> Void
    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedNoteIds) {
                ForEach(noteViewModel.notes) { note in
                    Text(note.title)
                        .foregroundColor(themeManager.currentTheme.textMain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .tag(note.id)
                        .background(noteSelectionBackground(for: note.id))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedNoteId = note.id
                            focusedColumn.wrappedValue = .noteList
                        }
                        .onDrag {
                            let itemsToDrag = selectedNoteIds.contains(note.id) ? selectedNoteIds : [note.id]
                            let idsString = itemsToDrag.map { String($0) }.joined(separator: ",")
                            return NSItemProvider(object: idsString as NSString)
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .padding(.bottom, 8)
                        .contextMenu {
                            Button("New Note") {
                                if let folderId = selectedFolderId {
                                    createAndFocusNewNote(folderId)
                                }
                            }
                            Button("Pin Note") { }
                            Divider()
                            Button("Delete Note", role: .destructive) {
                                if let folderId = selectedFolderId {
                                    deleteNote(note.id, folderId)
                                }
                            }
                            Divider()
                            Button("To Embed This Note", role: .destructive) {
                                embedNote(note.id)
                            }
                        }
                }
            }
            .scrollContentBackground(.hidden)
            .background(themeManager.currentTheme.bgNoteList)
            .focused(focusedColumn, equals: .noteList)
            .environment(\.defaultMinListRowHeight, 40)
            .toolbar(id: "notes_toolbar") {
                ToolbarItem(id: "test_confetti", placement: .navigation) {
                    Button {
                        showAnimationNotification()
                    } label: {
                        Label("Test Confetti", systemImage: "sparkles")
                    }
                }
                ToolbarItem(id: "new_note", placement: .primaryAction) {
                    Button {
                        if let folderId = selectedFolderId {
                            createAndFocusNewNote(folderId)
                        }
                    } label: {
                        Label("New Note", systemImage: "plus")
                    }
                    .disabled(selectedFolderId == nil)
                }
            }
        }
        .navigationTitle("Notes")
    }

    @ViewBuilder
    private func noteSelectionBackground(for noteId: NoteModel.ID) -> some View {
        if selectedNoteId == noteId {
            let color = themeManager.currentTheme.bgSelected
            let targetColor = focusedColumn.wrappedValue == .noteList ? color : color.opacity(0.5)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(targetColor)
        }
    }
}
