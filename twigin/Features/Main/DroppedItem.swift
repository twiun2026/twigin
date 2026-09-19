import Foundation

// A lightweight enum to represent items that can be dropped into the AI workspace.
// It can represent a regular Note (from SQLite), a Prompt (from prompts table),
// or a SourceModel (ObjectBox entity).
enum DroppedItem: Identifiable, Hashable {
    case note(NoteModel)
    case prompt(PromptModel)
    case source(SourceModel)

    var id: String {
        switch self {
        case .note(let n): return n.id
        case .prompt(let p): return p.id
        case .source(let s): return s.noteId
        }
    }

    var title: String {
        switch self {
        case .note(let n): return n.title
        case .prompt(let p): return p.title
        case .source(let s): return s.title
        }
    }

    // helper checks
    var isPrompt: Bool {
        if case .prompt = self { return true } else { return false }
    }
}

// Manual Equatable/Hashable implementations because associated types
// (NoteModel / PromptModel / SourceModel) may not themselves be Equatable/Hashable
// or may have different semantics. We consider items equal only when they
// are the same case and their identity fields match. Hashing also includes
// the case discriminator to avoid collisions between different kinds that
// happen to share the same id string.
extension DroppedItem: Equatable {
    static func == (lhs: DroppedItem, rhs: DroppedItem) -> Bool {
        switch (lhs, rhs) {
        case (.note(let a), .note(let b)):
            return a.id == b.id
        case (.prompt(let a), .prompt(let b)):
            return a.id == b.id
        case (.source(let a), .source(let b)):
            return a.noteId == b.noteId
        default:
            return false
        }
    }
}

extension DroppedItem {
    func hash(into hasher: inout Hasher) {
        switch self {
        case .note(let n):
            hasher.combine("note")
            hasher.combine(n.id)
        case .prompt(let p):
            hasher.combine("prompt")
            hasher.combine(p.id)
        case .source(let s):
            hasher.combine("source")
            hasher.combine(s.noteId)
        }
    }
}
