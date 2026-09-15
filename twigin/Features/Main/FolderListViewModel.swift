import SwiftUI
import Combine

enum FolderSortOption {
    case dateEdited
    case dateCreated
    case title
    case newestFirst
    case oldestFirst
}

@MainActor
class FolderListViewModel: ObservableObject {
    @Published var folders: [FolderModel] = []
    
    @Published var sortOption: FolderSortOption = .dateEdited {
        didSet { loadFolders() }
    }
    
    @Published var isCreatingNewFolder = false
    @Published var newFolderTitle = "New Folder"
    
    @Published var editingFolderId: String? = nil
    
    func setupAndLoad() {
        // Initialize the database
        _ = SQLiteManager.shared.setupDatabase()
        ensureSystemFolders()
        loadFolders()
    }
    
    private func ensureSystemFolders() {
        guard let dao = SQLiteDAO.shared else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let system: [(id: String, title: String)] = [
            ("__prompts__", "Prompt List"),
            ("__source_library__", "Source Library"),
            ("recently_deleted", "Recently Deleted")
        ]
        for sf in system {
            do {
                if try dao.folder.get(id: sf.id) == nil {
                    try dao.folder.insert(FolderModel(folderId: sf.id, folderTitle: sf.title, createdAt: now, updatedAt: now))
                }
            } catch {
                print("Failed to ensure system folder \(sf.id): \(error)")
            }
        }
    }
    
    func loadFolders() {
        guard let dao = SQLiteDAO.shared else {
            print("SQLiteDAO is nil, database might not be initialized")
            return
        }
        do {
            let fetchedFolders = try dao.folder.getAll()

            let systemTopIds = ["__prompts__", "__source_library__"]
            let topFolders = systemTopIds.compactMap { id in fetchedFolders.first(where: { $0.folderId == id }) }
            let bottomFolder = fetchedFolders.first(where: { $0.folderId == "recently_deleted" })
            var userFolders = fetchedFolders.filter {
                !systemTopIds.contains($0.folderId) && $0.folderId != "recently_deleted"
            }

            switch sortOption {
            case .title:
                userFolders.sort { $0.folderTitle.localizedStandardCompare($1.folderTitle) == .orderedAscending }
            case .dateEdited, .dateCreated, .newestFirst, .oldestFirst:
                break
            }

            self.folders = topFolders + userFolders + (bottomFolder.map { [$0] } ?? [])
            print("Loaded \(self.folders.count) folders from DB.")
        } catch {
            print("Failed to fetch folders: \(error)")
        }
    }
    
    func startCreatingNewFolder() {
        newFolderTitle = "New Folder"
        isCreatingNewFolder = true
    }
    
    func commitNewFolder() {
        guard isCreatingNewFolder else { return }
        isCreatingNewFolder = false // Prevent double commit
        
        let title = newFolderTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            guard let dao = SQLiteDAO.shared else { return }
            let newFolder = FolderModel.createNew(title: title)
            do {
                try dao.folder.insert(newFolder)
            } catch {
                print("Failed to insert new folder: \(error)")
            }
        }
        loadFolders()
    }
    
    func renameFolder(id: String, newTitle: String) {
        guard editingFolderId == id else { return } // Prevent double commit
        editingFolderId = nil
        
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let dao = SQLiteDAO.shared else {
            return
        }
        do {
            if let existing = try dao.folder.get(id: id) {
                let now = Int64(Date().timeIntervalSince1970)
                let updated = FolderModel(folderId: existing.folderId, folderTitle: title, createdAt: existing.createdAt, updatedAt: now)
                try dao.folder.update(updated)
            }
        } catch {
            print("Failed to rename folder: \(error)")
        }
        loadFolders()
    }
    
    func deleteFolder(id: String) {
        let protectedIds = ["recently_deleted", "__prompts__", "__source_library__"]
        guard !protectedIds.contains(id) else { return }
        guard let dao = SQLiteDAO.shared else { return }
        
        do {
            // 1. Move associated notes to "Recently Deleted"
            let notesInFolder = try dao.note.getByFolder(id: id)
            for note in notesInFolder {
                let updatedNote = NoteModel(
                    noteId: note.noteId,
                    folderId: "recently_deleted",
                    title: note.title,
                    documentJson: note.documentJson,
                    createdAt: note.createdAt,
                    updatedAt: note.updatedAt,
                    tags: note.tags,
                    isSystem: note.isSystem
                )
                try dao.note.update(updatedNote)
            }
            
            // 2. Delete the folder
            try dao.folder.delete(id: id)
            
            // 3. Refresh list
            loadFolders()
        } catch {
            print("Failed to delete folder: \(error)")
        }
    }
}
