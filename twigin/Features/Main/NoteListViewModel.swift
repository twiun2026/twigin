import SwiftUI
import Combine

@MainActor
class NoteListViewModel: ObservableObject {
    @Published var notes: [NoteModel] = []
    
    // Combine subject for debouncing note updates
    private var updateSubject = PassthroughSubject<(String, String, String), Never>()
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        setupDebounce()
    }
    
    private func setupDebounce() {
        updateSubject
            // 500ms debounce
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] noteId, title, content in
                self?.performUpdateNote(id: noteId, title: title, content: content)
            }
            .store(in: &cancellables)
    }
    
    func loadNotes(for folderId: String) {
        guard let dao = SQLiteDAO.shared else { return }
        do {
            self.notes = try dao.note.getSummaryByFolder(id: folderId)
        } catch {
            print("Failed to fetch notes: \(error)")
        }
    }
    
    func clearNotes() {
        self.notes = []
    }
    
    func createNote(in folderId: String) {
        guard let dao = SQLiteDAO.shared else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let newNote = NoteModel(
            noteId: UUID().uuidString,
            folderId: folderId,
            title: "New Note",
            documentJson: "", // Initial empty content
            createdAt: now,
            updatedAt: now
        )
        do {
            try dao.note.insert(newNote)
            loadNotes(for: folderId) // Reload the list to show the new note
        } catch {
            print("Failed to create note: \(error)")
        }
    }
    
    func deleteNote(id: String, currentFolderId: String) {
        guard let dao = SQLiteDAO.shared else { return }
        do {
            // Delete from database
            try dao.note.delete(id: id)
            // Refresh list
            loadNotes(for: currentFolderId)
        } catch {
            print("Failed to delete note: \(error)")
        }
    }
    
    func updateNoteDebounced(id: String, title: String, content: String) {
        // Send to debouncer
        updateSubject.send((id, title, content))
        
        // Optimistically update the title in the list
        if let index = notes.firstIndex(where: { $0.id == id }) {
            let oldNote = notes[index]
            if oldNote.title != title {
                notes[index] = NoteModel(
                    noteId: oldNote.noteId,
                    folderId: oldNote.folderId,
                    title: title,
                    documentJson: oldNote.documentJson,
                    createdAt: oldNote.createdAt,
                    updatedAt: Int64(Date().timeIntervalSince1970)
                )
            }
        }
    }
    
    private func performUpdateNote(id: String, title: String, content: String) {
        guard let dao = SQLiteDAO.shared else { return }
        do {
            guard let existingNote = try dao.note.get(id: id) else { return }
            let now = Int64(Date().timeIntervalSince1970)
            let updatedNote = NoteModel(
                noteId: existingNote.noteId,
                folderId: existingNote.folderId,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : title,
                documentJson: content,
                createdAt: existingNote.createdAt,
                updatedAt: now
            )
            try dao.note.update(updatedNote)
        } catch {
            print("Failed to update note in DB: \(error)")
        }
    }
    
    func fetchFullNoteContent(id: String) async -> NoteModel? {
        guard let dao = SQLiteDAO.shared else { return nil }
        do {
            // Though SQLite.swift is synchronous, wrap in a Task for async behavior if preferred
            return try dao.note.get(id: id)
        } catch {
            print("Failed to fetch full note: \(error)")
            return nil
        }
    }
}
