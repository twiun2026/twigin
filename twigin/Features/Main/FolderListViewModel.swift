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
        ensureRecentlyDeletedFolder()
        loadFolders()
    }
    
    private func ensureRecentlyDeletedFolder() {
        guard let dao = SQLiteDAO.shared else { return }
        do {
            if try dao.folder.get(id: "recently_deleted") == nil {
                let now = Int64(Date().timeIntervalSince1970)
                let recentlyDeleted = FolderModel(folderId: "recently_deleted", folderTitle: "Recently Deleted", createdAt: now, updatedAt: now)
                try dao.folder.insert(recentlyDeleted)
            }
        } catch {
            print("Failed to ensure Recently Deleted folder: \(error)")
        }
    }
    
    func loadFolders() {
        guard let dao = SQLiteDAO.shared else { 
            print("SQLiteDAO is nil, database might not be initialized")
            return 
        }
        do {
            var fetchedFolders = try dao.folder.getAll()
            
            // Separate "Recently Deleted" so it always appears at the bottom
            let recentlyDeleted = fetchedFolders.first(where: { $0.folderId == "recently_deleted" })
            fetchedFolders.removeAll(where: { $0.folderId == "recently_deleted" })
            
            // Sort remaining folders based on sortOption (Note: FolderModel currently lacks date fields, 
            // so we implement basic sorting on title or fallback to no-op for dates as a placeholder)
            switch sortOption {
            case .title:
                fetchedFolders.sort { $0.folderTitle.localizedStandardCompare($1.folderTitle) == .orderedAscending }
            case .dateEdited, .dateCreated, .newestFirst, .oldestFirst:
                // Placeholder for future implementation when Date fields are added to FolderModel
                break
            }
            
            if let recentlyDeleted = recentlyDeleted {
                fetchedFolders.append(recentlyDeleted)
            }
            
            self.folders = fetchedFolders
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
        // Prevent deleting the recently deleted folder
        guard id != "recently_deleted" else { return }
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
                    updatedAt: note.updatedAt
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
