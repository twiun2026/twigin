import Foundation
import ObjectBox

// objectbox: entity
class SourceModel {
    var id: Id = 0 // ObjectBox 内部自增主键
    var noteId: String = "" // 对应 SQLite 中的 note_id (TEXT UNIQUE)
    var title: String = ""
    var author: String? = nil
    var content: String = ""
    var url: String? = nil
    var tags: [String] = []
    var publishDate: Date = Date()
    var embedding: [Float] = []
    
    required init() {}
    
    init(noteId: String, title: String, author: String? = nil, content: String, url: String? = nil, tags: [String], publishDate: Date = Date(), embedding: [Float]) {
        self.noteId = noteId
        self.title = title
        self.author = nil
        self.content = content
        self.url = url
        self.tags = tags
        self.publishDate = publishDate
        self.embedding = embedding
    }
}
