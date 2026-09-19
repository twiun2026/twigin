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
    @StateObject private var promptPopoverVM = PromptPopoverViewModel()
    
    @State private var selectedFolderId: FolderModel.ID?
    @State private var selectedNoteId: NoteModel.ID?
    @State private var editorFocusRequest = UUID()
    @State private var showConfetti: Bool = false

    @State private var selectedNoteIds: Set<NoteModel.ID> = []
    @State private var droppedNotes: [DroppedItem] = []
    @State private var dropZoneHeight: CGFloat = 180
    @State private var isTargetedForDrop: Bool = false

    @FocusState private var isNewFolderFocused: Bool
    @FocusState private var focusedColumn: ActiveFocusColumn?

    let aiService: AIService
    
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
        Task {
            do {
                let fm = FileManager.default
                let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let dir = appSupport.appendingPathComponent(Bundle.main.bundleIdentifier ?? "twigin").path
                let store = try Store(directoryPath: dir)
                let box = store.box(for: SourceModel.self)
                let q = try box.query { SourceModel.noteId == noteId }.build()
                let found = try q.find()
                if !found.isEmpty {
                    for entity in found { try box.remove(entity.id) }
                    let alert = NSAlert()
                    alert.messageText = "Vector record deleted"
                    alert.informativeText = "The corresponding vector record for the note was removed from the local vector database."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
                store.close()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private func embedNote(noteId: NoteModel.ID) {
            Task {
                do {
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
                    let parsed = SourceMetadataParser().parse(raw)
                    let title = parsed.title
                    let publishDate = parsed.publishDate
                    let urlString = parsed.url
                    let tags: [String] = parsed.tags
                    let content = parsed.content

                    func chunk(_ text: String, maxLen: Int = 300, overlap: Int = 50) -> [String] {
                        guard !text.isEmpty else { return [] }
                        let chars = Array(text)
                        var result: [String] = []
                        var start = 0
                        let n = chars.count
                        while start < n {
                            let end = min(start + maxLen, n)
                            result.append(String(chars[start..<end]))
                            if end == n { break }
                            start = max(0, end - overlap)
                        }
                        return result
                    }

                    let chunks = chunk(content)
                    if chunks.isEmpty {
                        let alert = NSAlert()
                        alert.messageText = "Empty content"
                        alert.informativeText = "The selected note does not contain content to embed. Make sure the note has body text starting from the fourth line."
                        alert.alertStyle = .informational
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                        return
                    }

                    guard let apiKey = try await KeychainManager.shared.getApiKey(), !apiKey.isEmpty else {
                        let alert = NSAlert()
                        alert.messageText = "Qwen API Key missing"
                        alert.informativeText = "No Qwen API Key was found in the Keychain. Please open Settings → Artificial Intelligence and save your API Key so embedding can proceed."
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                        return
                    }

                    // ==========================================
                    // 优雅调用：通过独立的 QWenEmbeddingService 批量获取向量
                    // ==========================================
                    let embeddingService = QWenEmbeddingService()
                    let batchSize = 20
                    var vectors: [[Float]] = []

                    for batchStart in stride(from: 0, to: chunks.count, by: batchSize) {
                        let batchEnd = min(batchStart + batchSize, chunks.count)
                        let batch = Array(chunks[batchStart..<batchEnd])
                        
                        // 核心调用：传入文本批次与 apiKey，直接拿到对应结果
                        let batchVectors = try await embeddingService.fetchEmbeddings(for: batch)
                        vectors.append(contentsOf: batchVectors)
                    }

                    guard !vectors.isEmpty else {
                        let alert = NSAlert()
                        alert.messageText = "No embeddings"
                        alert.informativeText = "Embedding API returned no vectors."
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                        return
                    }

                    let count = Float(vectors.count)
                    guard let dim = vectors.first?.count else {
                        throw NSError(domain: "EmbedError", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unexpected embedding shape"])
                    }
                    var avg = Array(repeating: Float(0), count: dim)
                    for v in vectors {
                        if v.count == dim {
                            for i in 0..<dim { avg[i] += v[i] }
                        } else {
                            throw NSError(domain: "EmbedError", code: -3, userInfo: [NSLocalizedDescriptionKey: "Inconsistent embedding dimension returned by API"])
                        }
                    }
                    for i in 0..<dim { avg[i] /= count }

                    let fm = FileManager.default
                    let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    let dir = appSupport.appendingPathComponent(Bundle.main.bundleIdentifier ?? "twigin").path
                    let store = try Store(directoryPath: dir)
                        let box = store.box(for: SourceModel.self)

                    let q = try box.query { SourceModel.noteId == noteId }.build()
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
                            let entity = SourceModel(noteId: noteId, title: title, content: content, url: urlString, tags: tags, publishDate: publishDate, embedding: avg)
                        try box.put(entity)
                    }

                    debugPrintObjectBox(store: store)
                    store.close()
                    await MainActor.run { showAnimationNotification() }

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
            let box = store.box(for: SourceModel.self)
            print("===== ObjectBox 数据总览 =====")
            print("当前总记录数: [\(try box.count())]")
            for article in try box.all() {
                print("ID: \(article.noteId)")
                print("Title: \(article.title)")
                print("Date: \(article.publishDate)")
                let urlPreview = article.url ?? "N/A"
                print("URL: \(urlPreview)")
                print("Content 预览: \(article.content.prefix(50))...")
            }
            print("================================")
        } catch {
            print("调试打印 ObjectBox 数据出错: \(error)")
        }
    }

    private func showAnimationNotification() {
        withAnimation(.easeOut(duration: 0.25)) { showConfetti = true }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.25)) { showConfetti = false }
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            MainSplitViewLeftPart(
                folderViewModel: folderViewModel,
                noteViewModel: noteViewModel,
                selectedFolderId: $selectedFolderId,
                droppedNotes: $droppedNotes,
                dropZoneHeight: $dropZoneHeight,
                isTargetedForDrop: $isTargetedForDrop,
                focusedColumn: $focusedColumn,
                isNewFolderFocused: $isNewFolderFocused,
                aiService: aiService
            )
        } content: {
            MainSplitViewMiddlePart(
                noteViewModel: noteViewModel,
                selectedNoteIds: $selectedNoteIds,
                selectedNoteId: $selectedNoteId,
                selectedFolderId: selectedFolderId,
                focusedColumn: $focusedColumn,
                createAndFocusNewNote: createAndFocusNewNote,
                deleteNote: deleteNote,
                embedNote: embedNote,
                showAnimationNotification: showAnimationNotification
            )
        } detail: {
            MainSplitViewRightPart(
                selectedNoteId: selectedNoteId,
                noteViewModel: noteViewModel,
                selectedFolderId: selectedFolderId,
                editorFocusRequest: editorFocusRequest,
                promptPopoverVM: promptPopoverVM,
                showConfetti: showConfetti,
                onTogglePromptPopover: {
                    focusedColumn = .noteList
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    promptPopoverVM.isPresented.toggle()
                }
            )
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
}

#Preview {
    MainSplitView(
        aiService: AIService(
            provider: RoutingAIProvider(
                localProvider: AppleFoundationProvider(),
                cloudProvider: QWenProvider(),
                tokenThreshold: 2000
            )
        )
    )
    .environmentObject(ThemeManager())
}
