import SwiftUI
import ObjectBox

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
    
    private func embedNote(noteId: NoteModel.ID){
        // Run asynchronously to avoid blocking the UI
        Task {
            do {
                // 1) Fetch full note content
                guard let fullNote = await noteViewModel.fetchFullNoteContent(id: noteId) else {
                    let alert = NSAlert()
                    alert.messageText = "Note not found"
                    alert.informativeText = "Cannot find the selected note in the database."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    return
                }

                let raw = fullNote.documentJson ?? ""
                let lines = raw.components(separatedBy: .newlines)

                // Parse metadata according to specification
                // 1st line: title starting with '#'
                var title = "Untitled"
                if let first = lines.first?.trimmingCharacters(in: .whitespaces) , !first.isEmpty {
                    var t = first
                    while t.hasPrefix("#") { t.removeFirst() }
                    title = t.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                // 2nd line: publish Date: ...
                var publishDate = Date()
                if lines.count > 1 {
                    let second = lines[1].trimmingCharacters(in: .whitespaces)
                    if second.lowercased().hasPrefix("publish date:") {
                        let idx = second.index(second.startIndex, offsetBy: "publish Date:".count)
                        let dateStr = second[idx...].trimmingCharacters(in: .whitespacesAndNewlines)
                        // Try several common formats
                        if let d = ISO8601DateFormatter().date(from: String(dateStr)) {
                            publishDate = d
                        } else {
                            let df = DateFormatter()
                            df.locale = Locale(identifier: "en_US_POSIX")
                            df.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
                            if let d = df.date(from: String(dateStr)) {
                                publishDate = d
                            } else {
                                df.dateFormat = "yyyy-MM-dd"
                                if let d = df.date(from: String(dateStr)) {
                                    publishDate = d
                                } else {
                                    // fallback leave as now
                                }
                            }
                        }
                    }
                }

                // 3rd line: url: ...
                var urlString: String? = nil
                if lines.count > 2 {
                    let third = lines[2].trimmingCharacters(in: .whitespaces)
                    if third.lowercased().hasPrefix("url:") {
                        let idx = third.index(third.startIndex, offsetBy: "url:".count)
                        let u = third[idx...].trimmingCharacters(in: .whitespacesAndNewlines)
                        urlString = u.isEmpty ? nil : String(u)
                    }
                }

                // 4th line onward => content for embedding
                let contentLines = lines.count > 3 ? Array(lines[3...]) : []
                let content = contentLines.joined(separator: "\n")

                // 1) Chunk content into ~300-char segments with overlap
                func chunk(_ text: String, maxLen: Int = 300, overlap: Int = 50) -> [String] {
                    guard !text.isEmpty else { return [] }
                    let chars = Array(text)
                    var result: [String] = []
                    var start = 0
                    let n = chars.count
                    while start < n {
                        let end = min(start + maxLen, n)
                        let slice = String(chars[start..<end])
                        result.append(slice)
                        if end == n { break }
                        start = max(0, end - overlap)
                    }
                    return result
                }

                let chunks = chunk(content)

                // If there are no chunks (empty content), stop with an alert
                if chunks.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = "Empty content"
                    alert.informativeText = "The selected note does not contain content to embed. Make sure the note has body text starting from the fourth line."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    return
                }

                // 2) Call embedding API
                guard let apiKey = try await KeychainManager.shared.getApiKey(), !apiKey.isEmpty else {
                    let alert = NSAlert()
                    alert.messageText = "Qwen API Key missing"
                    alert.informativeText = "No Qwen API Key was found in the Keychain. Please open Settings → Artificial Intelligence and save your API Key so embedding can proceed."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    return
                }

                let endpoint = URL(string: "https://ws-1ac7g9swxc2dszw3.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1/embeddings")!
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

                let body: [String: Any] = [
                    "model": "qwen3.7-text-embedding",
                    "input": chunks
                ]
                
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    let alert = NSAlert(error: NSError(domain: "EmbedError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response from embedding service"]))
                    alert.runModal()
                    return
                }

                if !(200..<300).contains(http.statusCode) {
                    let serverMsg = String(data: data, encoding: .utf8) ?? "(no body)"
                    let alert = NSAlert()
                    alert.messageText = "Embedding failed"
                    alert.informativeText = "Server returned HTTP \(http.statusCode): \(serverMsg)"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    return
                }

                // Parse embedding response
                struct EmbeddingItem: Codable { let embedding: [Float] }
                struct EmbeddingResp: Codable { let data: [EmbeddingItem] }

                let decoder = JSONDecoder()
                let embResp = try decoder.decode(EmbeddingResp.self, from: data)
                guard !embResp.data.isEmpty else {
                    let alert = NSAlert()
                    alert.messageText = "No embeddings"
                    alert.informativeText = "Embedding API returned no vectors."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    return
                }

                // Aggregate embeddings into a single vector (mean pooling)
                let vectors = embResp.data.map { $0.embedding }
                let count = Float(vectors.count)
                guard let dim = vectors.first?.count else {
                    throw NSError(domain: "EmbedError", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unexpected embedding shape"]) }
                var avg = Array(repeating: Float(0), count: dim)
                for v in vectors {
                    if v.count == dim {
                        for i in 0..<dim { avg[i] += v[i] }
                    }
                }
                for i in 0..<dim { avg[i] /= count }

                // 3) ObjectBox Upsert
                // Create a store in Application Support/<bundle-id>/objectbox
                let fm = FileManager.default
                let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let dir = appSupport.appendingPathComponent(Bundle.main.bundleIdentifier ?? "twigin").path

                let store = try Store(directoryPath: dir)
                let box = store.box(for: NewsArticleDataModel.self)

                // Query by noteId
                let q = try box.query { NewsArticleDataModel.noteId == noteId }.build()
                let found = try q.find()
                if let existing = found.first {
                    existing.noteId = noteId
                    existing.title = title
                    existing.content = content
                    existing.url = urlString
                    existing.publishDate = publishDate
                    existing.embedding = avg
                    try box.put(existing)
                } else {
                    let entity = NewsArticleDataModel(noteId: noteId, title: title, content: content, url: urlString, publishDate: publishDate, embedding: avg)
                    try box.put(entity)
                }

                // Inform user
                let alert = NSAlert()
                alert.messageText = "Embedding saved"
                alert.informativeText = "Embeddings for the note were computed and stored successfully."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()

                //debug print ObjectBox contents for verification
                debugPrintObjectBox(store: store)
                // Note: leaving store open is fine; closing explicitly if desired:
                store.close()

            } catch {
                let alert = NSAlert(error: error)
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }

    }
    
    private func debugPrintObjectBox(store s: Store?) {
        guard let store = s else {
            print("Store 实例为 nil，跳过调试打印。")
            return
        }
        do {
            let box = store.box(for: NewsArticleDataModel.self)
            
            print("===== ObjectBox 数据总览 =====")
            let totalCount = try box.count()
            print("当前总记录数: [\(totalCount)]")
            
            let articles = try box.all()
            for article in articles{
                print("--------------------------------")
                print("ID: \(article.noteId)")
                print("Title: \(article.title)")
                print("Date: \(article.publishDate)")
                print("URL: \(article.url ?? "N/A")")
                print("Content 预览: \(article.content.prefix(50))...")
                // 如果你的向量字段是 Float 数组，可以打印它的维度
                // print("Vector 维度: \(article.embedding.count)")
            }
            print("================================")
        } catch {
            print("调试打印 ObjectBox 数据出错: \(error)")
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
                                Divider()
                                Button("To Embed This Note", role: .destructive) {
                                    embedNote(noteId: note.id)
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
