import SwiftUI
import AppKit
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
    @State private var showConfetti: Bool = false
    
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
        // Also remove any corresponding vector record from ObjectBox (if present).
        Task {
            do {
                let fm = FileManager.default
                let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let dir = appSupport.appendingPathComponent(Bundle.main.bundleIdentifier ?? "twigin").path

                let store = try Store(directoryPath: dir)
                let box = store.box(for: ArticleDataModel.self)

                // Query by noteId
                let q = try box.query { ArticleDataModel.noteId == noteId }.build()
                let found = try q.find()
                if !found.isEmpty {
                    // Remove all matching entities
                    for entity in found {
                        try box.remove(entity.id)
                    }

                    // Inform user of successful deletion from local vector DB
                    let alert = NSAlert()
                    alert.messageText = "Vector record deleted"
                    alert.informativeText = "The corresponding vector record for the note was removed from the local vector database."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }

                store.close()
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
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

                // Use ArticleMetadataParser to extract metadata and remaining content.
                let parsed = ArticleMetadataParser().parse(raw)

                // Extract fields required by the embedding/upsert flow
                let title = parsed.title
                let publishDate = parsed.publishDate
                let urlString = parsed.url
                let tags: [String] = parsed.tags
                let content = parsed.content

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

                // 2) Call embedding API in batches (max 20 per request)
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

                struct EmbeddingItem: Codable { let embedding: [Float] }
                struct EmbeddingResp: Codable { let data: [EmbeddingItem] }

                let decoder = JSONDecoder()
                var vectors: [[Float]] = []
                let batchSize = 20

                for start in stride(from: 0, to: chunks.count, by: batchSize) {
                    let end = min(start + batchSize, chunks.count)
                    let batch = Array(chunks[start..<end])

                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

                    let body: [String: Any] = [
                        "model": "qwen3.7-text-embedding",
                        "input": batch
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

                    let embResp = try decoder.decode(EmbeddingResp.self, from: data)
                    if embResp.data.isEmpty {
                        let alert = NSAlert()
                        alert.messageText = "No embeddings"
                        alert.informativeText = "Embedding API returned no vectors for a batch."
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                        return
                    }

                    // Append embeddings preserving order
                    for item in embResp.data {
                        vectors.append(item.embedding)
                    }
                }

                // Validate we got embeddings
                guard !vectors.isEmpty else {
                    let alert = NSAlert()
                    alert.messageText = "No embeddings"
                    alert.informativeText = "Embedding API returned no vectors."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    return
                }

                // Aggregate embeddings into a single vector (mean pooling)
                let count = Float(vectors.count)
                guard let dim = vectors.first?.count else {
                    throw NSError(domain: "EmbedError", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unexpected embedding shape"]) }
                var avg = Array(repeating: Float(0), count: dim)
                for v in vectors {
                    if v.count == dim {
                        for i in 0..<dim { avg[i] += v[i] }
                    } else {
                        throw NSError(domain: "EmbedError", code: -3, userInfo: [NSLocalizedDescriptionKey: "Inconsistent embedding dimension returned by API"]) }
                }
                for i in 0..<dim { avg[i] /= count }
                

                // 3) ObjectBox Upsert
                // Create a store in Application Support/<bundle-id>/objectbox
                let fm = FileManager.default
                let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let dir = appSupport.appendingPathComponent(Bundle.main.bundleIdentifier ?? "twigin").path

                let store = try Store(directoryPath: dir)
                let box = store.box(for: ArticleDataModel.self)

                // Query by noteId
                let q = try box.query { ArticleDataModel.noteId == noteId }.build()
                let found = try q.find()
                if let existing = found.first {
                    existing.noteId = noteId
                    existing.title = title
                    existing.content = content
                    existing.url = urlString
                    existing.tags = tags
                    existing.publishDate = publishDate
                    existing.embedding = avg
                    try box.put(existing)
                } else {
                    let entity = ArticleDataModel(noteId: noteId, title: title, content: content, url: urlString, tags: tags, publishDate: publishDate, embedding: avg)
                    try box.put(entity)
                }

                //debug print ObjectBox contents for verification
                debugPrintObjectBox(store: store)
                // Note: leaving store open is fine; closing explicitly if desired:
                store.close()
                // trigger confetti notification in the right pane
                await MainActor.run {
                    showAnimationNotification()
                }

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
            let box = store.box(for: ArticleDataModel.self)
            
            print("===== ObjectBox 数据总览 =====")
            let totalCount = try box.count()
            print("当前总记录数: [\(totalCount)]")
            
            let articles = try box.all()
            for article in articles{
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

    // Trigger an ephemeral confetti-style animation in the right pane.
    private func showAnimationNotification() {
        // Animate show/hide to make the overlay fade in/out reliably
        withAnimation(.easeOut(duration: 0.25)) {
            showConfetti = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.25)) {
                    showConfetti = false
                }
            }
        }
    }

    // A lightweight SwiftUI confetti particle system. Uses Canvas + TimelineView
    // to animate many colored particles; optimized for short-lived 2s playback.
    private struct ConfettiView: View {
        struct Particle {
            let id = UUID()
            let color: Color
            let x0: CGFloat
            let y0: CGFloat
            let vx: CGFloat
            let vy: CGFloat
            let rot0: Double
            let rotSpeed: Double
            let size: CGFloat
            let shapeRect: CGRect
        }

        @State private var particles: [Particle] = []
        @State private var startDate: Date? = nil
        private let colors: [Color] = [
            .red, .pink, .orange, .yellow, .green, .blue, .purple
        ]

        private func makeParticles(in size: CGSize, count: Int = 80) -> [Particle] {
            var out: [Particle] = []
            let centerX = size.width * 0.5
            // Start near the bottom of the screen to shoot upwards
            let startY = size.height * 0.95
            for _ in 0..<count {
                let angle = Double.random(in: (-Double.pi / 2.0 - 0.6)...(-Double.pi / 2.0 + 0.6))
                let speed = CGFloat.random(in: 120...520)
                let vx = CGFloat(cos(angle)) * speed
                let vy = CGFloat(sin(angle)) * speed
                let sz = CGFloat.random(in: 6...18)
                let xJitter = CGFloat.random(in: -80...80)
                let color = colors.randomElement() ?? .blue
                let rot0 = Double.random(in: 0...360)
                let rotSpeed = Double.random(in: -360...360)
                let rect = CGRect(x: centerX + xJitter - sz/2, y: startY - sz/2, width: sz, height: sz * CGFloat.random(in: 0.7...1.6))
                out.append(Particle(color: color, x0: rect.midX, y0: rect.midY, vx: vx, vy: vy, rot0: rot0, rotSpeed: rotSpeed, size: sz, shapeRect: rect))
            }
            return out
        }

        var body: some View {
            GeometryReader { geo in
                TimelineView(.animation) { timeline in
                    let now = timeline.date
                    Canvas { context, size in
                        guard let sd = startDate else {
                            DispatchQueue.main.async {
                                if startDate == nil {
                                    particles = makeParticles(in: size)
                                    startDate = Date()
                                }
                            }
                            return
                        }
                        // compute elapsed time since particles were created (cap at 2s)
                        let dt = CGFloat(min(2.0, max(0.0, now.timeIntervalSince(sd))))
                        let gravity: CGFloat = 600

                        for p in particles {
                            let x = p.x0 + p.vx * dt
                            let y = p.y0 + p.vy * dt + 0.5 * gravity * dt * dt
                            let rot = p.rot0 + p.rotSpeed * Double(dt)
                            
                            context.drawLayer { localContext in
                                localContext.translateBy(x: x, y: y)
                                localContext.rotate(by: .degrees(rot))
                                let rect = CGRect(x: -p.size/2, y: -p.size/2, width: p.size, height: p.size * 1.2)
                                let path = Path(roundedRect: rect, cornerRadius: p.size * 0.2)
                                let opacity = max(0.0, 1.0 - Double(dt / 2.0))
                                localContext.fill(path, with: .color(p.color.opacity(opacity)))
                                localContext.stroke(path, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
                            }
                        }
                    }
                    .allowsHitTesting(false)
                    .compositingGroup()
                }
                .onAppear {
                    if geo.size.width > 0 {
                        particles = makeParticles(in: geo.size)
                        startDate = Date()
                    }
                }
                .onChange(of: geo.size) { oldSize, newSize in
                    if newSize.width > 0 {
                        particles = makeParticles(in: newSize)
                        startDate = Date()
                    }
                }
            }
            .ignoresSafeArea()
        }
    }

    // A native AppKit view wrapper to solve the SwiftUI-AppKit "airspace" rendering conflict.
    // By wrapping ConfettiView in an NSHostingView subview, it becomes a sibling to
    // MarkdownEditorView's NSScrollView and is drawn correctly on top of the editor.
    private struct ConfettiHostView: NSViewRepresentable {
        func makeNSView(context: Context) -> NSHostingView<ConfettiView> {
            let view = NSHostingView(rootView: ConfettiView())
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
            return view
        }

        func updateNSView(_ nsView: NSHostingView<ConfettiView>, context: Context) {}
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
            // Right Pane: Detail (wrapped to allow confetti overlay)
            ZStack {
                if let selectedNoteId = selectedNoteId {
                    NoteEditorView(
                        noteId: selectedNoteId,
                        viewModel: noteViewModel,
                        focusRequest: editorFocusRequest
                    )
                } else {
                    Text("No note selected")
                        .foregroundColor(themeManager.currentTheme.textMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if showConfetti {
                    ConfettiHostView()
                        .transition(.opacity)
                        .zIndex(1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
            .background(themeManager.currentTheme.bgNoteEditor)
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
