import Foundation
import AppKit
import SwiftUI
import Combine

/// ViewModel for the Prompt Popover.
/// - Note: isolated on MainActor to safely update @Published UI state.
@MainActor
final class PromptPopoverViewModel: ObservableObject {
    // Provide an explicit publisher to satisfy ObservableObject in all compiler contexts
    let objectWillChange = ObservableObjectPublisher()
    // UI state
    @Published var isPresented: Bool = false
    @Published var selectedTab: Int = 0

    // Tab 1: metadata
    @Published var wordCount: Int = 0
    @Published var createdAt: Date? = nil
    @Published var updatedAt: Date? = nil

    // Tab 2: prompts related
    @Published var categories: [String] = []
    @Published var selectedCategory: String? = nil
    @Published var showCustomCategoryField: Bool = false
    @Published var customCategoryText: String = ""

    @Published var variables: [String] = []

    @Published var styles: [String] = []
    @Published var selectedStyle: String? = nil
    @Published var showCustomStyleField: Bool = false
    @Published var customStyleText: String = ""
    
    /// Whether the current note lives in the "Prompt List" folder
    @Published var isPromptFolder: Bool = false

    // Text observation - we register self as observer via selector so we can
    // safely removeObserver(self) in deinit without accessing actor-isolated tokens.
    private weak var observedTextStorage: NSTextStorage?

    // Debounce task for text processing (main-actor isolated)
    private var debounceTask: Task<Void, Never>? = nil

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    init() {
        Task { await loadPromptOptions() }
    }

    // MARK: - Public API

    /// Attach the ViewModel to an NSTextView's textStorage to receive incremental updates.
    /// This uses NSTextStorage.didProcessEditingNotification to avoid heavy polling.
    func attach(to textView: NSTextView) {
        // detach previous observers
        NotificationCenter.default.removeObserver(self)

        guard let storage = textView.textStorage else { return }
        // store weak reference on main actor
        observedTextStorage = storage

        // Register self as observer. The selector handler will forward to MainActor.
        NotificationCenter.default.addObserver(self, selector: #selector(textStorageDidProcessEditing(_:)), name: NSTextStorage.didProcessEditingNotification, object: storage)
    }

    /// Detach any text storage observers
    func detachTextObservation() {
        NotificationCenter.default.removeObserver(self)
        observedTextStorage = nil
        debounceTask?.cancel()
    }

    @MainActor
    private func scheduleDebouncedProcessFromObservedStorage() async {
        // cancel previous task and start a new one to debounce frequent edits
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000) // 80ms
            guard !Task.isCancelled else { return }
            guard let storage = observedTextStorage else { return }
            await processEditorText(storage.string)
        }
    }

    @objc private func textStorageDidProcessEditing(_ note: Notification) {
        Task { await scheduleDebouncedProcessFromObservedStorage() }
    }

    /// Manually update metadata (useful on opening a note)
    func updateMetadata(created: Date?, modified: Date?, text: String) async {
        await MainActor.run {
            self.createdAt = created
            self.updatedAt = modified
            self.wordCount = Self.countWords(in: text)
        }
        await processEditorText(text)
    }

    /// Load categories and styles from prompts table (deduplicated)
    func loadPromptOptions() async {
        do {
            guard let dao = SQLiteDAO.shared?.prompt else { return }
            let all = try await dao.getAll()
            // dedupe categories and styles
            var catSet = Set<String>()
            var styleSet = Set<String>()
            for p in all {
                if let c = p.category, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    catSet.insert(c)
                }
                for s in p.targetStyle {
                    if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        styleSet.insert(s)
                    }
                }
            }
            let cats = Array(catSet).sorted()
            let styles = Array(styleSet).sorted()
            await MainActor.run {
                self.categories = cats
                self.styles = styles
            }
        } catch {
            print("PromptPopoverViewModel.loadPromptOptions error: \(error)")
        }
    }

    /// Save a custom category as a new Prompt entry with minimal payload.
    func saveCustomCategoryIfNeeded() async {
        let trimmed = customCategoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let model = PromptModel(title: trimmed, category: trimmed, content: "", variables: [], targetStyle: [], isSystem: false)
            try await SQLiteDAO.shared?.prompt.insert(model)
            customCategoryText = ""
            showCustomCategoryField = false
            selectedCategory = trimmed
            await loadPromptOptions()
        } catch {
            print("Failed to save custom category: \(error)")
        }
    }

    /// Save a custom style similarly
    func saveCustomStyleIfNeeded() async {
        let trimmed = customStyleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let model = PromptModel(title: trimmed, category: nil, content: "", variables: [], targetStyle: [trimmed], isSystem: false)
            try await SQLiteDAO.shared?.prompt.insert(model)
            customStyleText = ""
            showCustomStyleField = false
            selectedStyle = trimmed
            await loadPromptOptions()
        } catch {
            print("Failed to save custom style: \(error)")
        }
    }

    // MARK: - Internal text processing

    private func processEditorText(_ text: String) async {
        // word count is cheap; compute on main actor
        await MainActor.run {
            self.wordCount = Self.countWords(in: text)
        }

        // Extract variables of form {{var}}. Use a simple regex.
        let vars = Self.extractVariables(from: text)
        await MainActor.run {
            self.variables = vars
        }
    }

    // Very small utility: count words simply by splitting on whitespaces/newlines
    private static func countWords(in text: String) -> Int {
        let comps = text.split { $0.isWhitespace || $0.isNewline }
        return comps.count
    }

    // Extract unique variables in order of appearance
    private static func extractVariables(from text: String) -> [String] {
        var out: [String] = []
        let pattern = #"\{\{([^\}]+)\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        var seen = Set<String>()
        for m in matches {
            if m.numberOfRanges >= 2 {
                let r = m.range(at: 1)
                let token = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty && !seen.contains(token) {
                    seen.insert(token)
                    out.append(token)
                }
            }
        }
        return out
    }
}
