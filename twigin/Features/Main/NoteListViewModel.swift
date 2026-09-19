import SwiftUI
import Combine
import ObjectBox

@MainActor
class NoteListViewModel: ObservableObject {
    @Published var notes: [NoteModel] = []
    private var currentFolderId: String = ""

    private var updateSubject = PassthroughSubject<(String, String, String), Never>()
    private var cancellables = Set<AnyCancellable>()

    init() {
        setupDebounce()
    }

    private func setupDebounce() {
        updateSubject
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] noteId, title, content in
                self?.performUpdateNote(id: noteId, title: title, content: content)
            }
            .store(in: &cancellables)
    }

    func loadNotes(for folderId: String) {
        currentFolderId = folderId
        switch FolderType(folderId) {
        case .prompts:
            Task {
                guard let dao = SQLiteDAO.shared else { return }
                if let prompts = try? await dao.prompt.getAll() {
                    self.notes = prompts.map { NoteModel(from: $0) }
                }
            }
        case .sourceLibrary:
            Task { self.notes = await loadAllFromObjectBox() }
        case .regular:
            guard let dao = SQLiteDAO.shared else { return }
            do {
                self.notes = try dao.note.getSummaryByFolder(id: folderId)
            } catch {
                print("Failed to fetch notes: \(error)")
            }
        }
    }

    func clearNotes() {
        self.notes = []
        currentFolderId = ""
    }

    func createNote(in folderId: String) -> NoteModel.ID? {
        let newId = UUID().uuidString
        let now = Int64(Date().timeIntervalSince1970)
        switch FolderType(folderId) {
        case .prompts:
            Task {
                guard let dao = SQLiteDAO.shared else { return }
                let p = PromptModel(id: newId, title: "New Prompt", content: "")
                try? await dao.prompt.insert(p)
                loadNotes(for: folderId)
            }
        case .sourceLibrary:
            Task {
                guard let dir = objectBoxDir(),
                      let store = try? Store(directoryPath: dir) else { return }
                defer { store.close() }
                let box = store.box(for: SourceModel.self)
                let entity = SourceModel(noteId: newId, title: "New Article", content: "", tags: [], embedding: [])
                // Explicitly ignore the optional result to avoid the "Result of 'try?' is unused" warning
                _ = try? box.put(entity)
                loadNotes(for: folderId)
            }
        case .regular:
            guard let dao = SQLiteDAO.shared else { return nil }
            let newNote = NoteModel(
                noteId: newId,
                folderId: folderId,
                title: "New Note",
                documentJson: "",
                createdAt: now,
                updatedAt: now
            )
            do {
                try dao.note.insert(newNote)
                loadNotes(for: folderId)
            } catch {
                print("Failed to create note: \(error)")
                return nil
            }
        }
        return newId
    }

    func deleteNote(id: String, currentFolderId: String) {
        switch FolderType(currentFolderId) {
        case .prompts:
            Task {
                guard let dao = SQLiteDAO.shared else { return }
                try? await dao.prompt.delete(id: id)
                loadNotes(for: currentFolderId)
            }
        case .sourceLibrary:
            Task {
                guard let dir = objectBoxDir(),
                      let store = try? Store(directoryPath: dir) else { return }
                defer { store.close() }
                let box = store.box(for: SourceModel.self)
                let q = try? box.query { SourceModel.noteId == id }.build()
                let found = (try? q?.find()) ?? []
                for e in found { _ = try? box.remove(e.id) }
                loadNotes(for: currentFolderId)
            }
        case .regular:
            guard let dao = SQLiteDAO.shared else { return }
            do {
                try dao.note.delete(id: id)
                loadNotes(for: currentFolderId)
            } catch {
                print("Failed to delete note: \(error)")
            }
        }
    }

    func updateNoteDebounced(id: String, title: String, content: String) {
        updateSubject.send((id, title, content))
        if let index = notes.firstIndex(where: { $0.id == id }) {
            let oldNote = notes[index]
            if oldNote.title != title {
                notes[index] = NoteModel(
                    noteId: oldNote.noteId,
                    folderId: oldNote.folderId,
                    title: title,
                    documentJson: oldNote.documentJson,
                    createdAt: oldNote.createdAt,
                    updatedAt: Int64(Date().timeIntervalSince1970),
                    tags: oldNote.tags,
                    isSystem: oldNote.isSystem
                )
            }
        }
    }

    private func performUpdateNote(id: String, title: String, content: String) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : title
        switch FolderType(currentFolderId) {
        case .prompts:
            Task {
                guard let dao = SQLiteDAO.shared else { return }
                if var p = try? await dao.prompt.get(id: id) {
                    p.title = cleanTitle
                    p.content = content
                    p.updatedAt = Date()
                    try? await dao.prompt.update(p)
                } else {
                    let p = PromptModel(id: id, title: cleanTitle, content: content)
                    try? await dao.prompt.insert(p)
                }
            }
        case .sourceLibrary:
            Task {
                guard let dir = objectBoxDir(),
                      let store = try? Store(directoryPath: dir) else { return }
                defer { store.close() }
                let box = store.box(for: SourceModel.self)
                let q = try? box.query { SourceModel.noteId == id }.build()
                if let existing = try? q?.find().first {
                    existing.title = cleanTitle
                    existing.content = content
                    _ = try? box.put(existing)
                }
            }
        case .regular:
            guard let dao = SQLiteDAO.shared else { return }
            do {
                guard let existingNote = try dao.note.get(id: id) else { return }
                let now = Int64(Date().timeIntervalSince1970)
                let updatedNote = NoteModel(
                    noteId: existingNote.noteId,
                    folderId: existingNote.folderId,
                    title: cleanTitle,
                    documentJson: content,
                    createdAt: existingNote.createdAt,
                    updatedAt: now,
                    tags: existingNote.tags,
                    isSystem: existingNote.isSystem
                )
                try dao.note.update(updatedNote)
            } catch {
                print("Failed to update note in DB: \(error)")
            }
        }
    }

    func fetchFullNoteContent(id: String) async -> NoteModel? {
        let now = Int64(Date().timeIntervalSince1970)
        switch FolderType(currentFolderId) {
        case .prompts:
            guard let dao = SQLiteDAO.shared else { return nil }
            if let prompt = try? await dao.prompt.get(id: id) {
                return NoteModel(from: prompt)
            }
            return NoteModel(noteId: id, folderId: "__prompts__", title: "New Prompt",
                             documentJson: "", createdAt: now, updatedAt: now)
        case .sourceLibrary:
            guard let dir = objectBoxDir(),
                  let store = try? Store(directoryPath: dir) else { return nil }
            defer { store.close() }
            let box = store.box(for: SourceModel.self)
            let q = try? box.query { SourceModel.noteId == id }.build()
            if let article = try? q?.find().first {
                return NoteModel(from: article)
            }
            return NoteModel(noteId: id, folderId: "__source_library__", title: "New Article",
                             documentJson: "", createdAt: now, updatedAt: now)
        case .regular:
            guard let dao = SQLiteDAO.shared else { return nil }
            do {
                return try dao.note.get(id: id)
            } catch {
                print("Failed to fetch full note: \(error)")
                return nil
            }
        }
    }

    // MARK: - ObjectBox Helpers

    private func objectBoxDir() -> String? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return appSupport.appendingPathComponent(Bundle.main.bundleIdentifier ?? "twigin").path
    }

    private func loadAllFromObjectBox() async -> [NoteModel] {
        guard let dir = objectBoxDir(),
              let store = try? Store(directoryPath: dir) else { return [] }
        defer { store.close() }
        let box = store.box(for: SourceModel.self)
        let articles = (try? box.all()) ?? []
        return articles.map { NoteModel(from: $0) }
    }
}

// MARK: - NoteModel conversions

private extension NoteModel {
    init(from article: SourceModel) {
        self.init(
            noteId: article.noteId,
            folderId: "__source_library__",
            title: article.title,
            documentJson: article.content,
            createdAt: Int64(article.publishDate.timeIntervalSince1970),
            updatedAt: Int64(article.publishDate.timeIntervalSince1970)
        )
    }
}
