//
//  SQLiteDAO.swift
//  twigin
//
//  Created by Neo on 7/12/26.
//

import Foundation
import SQLite

// MARK: - Models

struct FolderModel: Identifiable, Hashable {
    let folderId: String
    var folderTitle: String
    let createdAt: Int64
    var updatedAt: Int64
    var isDeleted: Bool = false
    var syncState: Int = 0
    var id: String { folderId } // 实现 Identifiable 协议
}
// 扩展，给上面的结构体“加个技能”（方便后面直接一键生成新文件夹）
extension FolderModel {
    /// 用于创建一个全新的文件夹（自动生成 UUID 和当前秒级时间戳）
    static func createNew(title: String) -> FolderModel {
        let now = Int64(Date().timeIntervalSince1970)
        return FolderModel(
            folderId: UUID().uuidString,
            folderTitle: title,
            createdAt: now,
            updatedAt: now,
        )
    }
}

struct NoteModel: Identifiable, Hashable {
    let noteId: String
    let folderId: String?
    let title: String
    let documentJson: String?
    let createdAt: Int64
    let updatedAt: Int64
    
    var id: String { noteId }
}

struct NoteOpsLogModel {
    let operationId: String
    let noteId: String
    let version: Int64
    let type: String
    let payloadJson: String
    let timestamp: Int64
    let author: String
}

struct NoteSnapshotModel {
    let snapshotId: String
    let noteId: String
    let baseVersion: Int64
    let documentJson: String
    let createdAt: Int64
}

// MARK: - DAOs

class FolderDAO {
    private let db: Connection
    private let table = Table("folders")
    
    private let folderId = Expression<String>("folder_id")
    private let folderTitle = Expression<String>("folder_title")
    private let createdAt = Expression<Int64>("created_at")
    private let updatedAt = Expression<Int64>("updated_at")
    private let isDeleted = Expression<Int64>("is_deleted")
    
    init(db: Connection) {
        self.db = db
    }
    
    func insert(_ model: FolderModel) throws {
        let insert = table.insert(
            folderId <- model.folderId,
            folderTitle <- model.folderTitle,
            createdAt <- model.createdAt,
            updatedAt <- model.updatedAt
        )
        try db.run(insert)
    }
    
    func update(_ model: FolderModel) throws {
        let item = table.filter(folderId == model.folderId)
        try db.run(item.update(
            folderTitle <- model.folderTitle,
            updatedAt <- model.updatedAt
        ))
    }
    
    func delete(id: String) throws {
        let now = Int64(Date().timeIntervalSince1970)
        let item = table.filter(folderId == id)
        try db.run(item.update(
            isDeleted <- 1,         // 1 表示 true (已被移入最近删除)
            updatedAt <- now        // 记录本次删除操作的时间
        ))
    }
    
    func get(id: String) throws -> FolderModel? {
        let item = table.filter(folderId == id)
        if let row = try db.pluck(item) {
            return FolderModel(
                folderId: row[folderId],
                folderTitle: row[folderTitle],
                createdAt: row[createdAt],
                updatedAt: row[updatedAt]
            )
        }
        return nil
    }
    
    func getAll() throws -> [FolderModel] {
        var results = [FolderModel]()
        let query = table.filter(isDeleted == 0)// 只筛选出未被删除的文件夹 (is_deleted == 0)
        for row in try db.prepare(query) {
            results.append(FolderModel(
                folderId: row[folderId],
                folderTitle: row[folderTitle],
                createdAt: row[createdAt],
                updatedAt: row[updatedAt],
                isDeleted: row[isDeleted] == 1,// 将 0/1 转换为 Swift 的 Bool
                syncState: 0 // 暂存默认值
            ))
        }
        return results
    }
    
    /// 获取所有被放入回收站的文件夹
    func getRecentlyDeleted() throws -> [FolderModel] {
        var results = [FolderModel]()
        let query = table.filter(isDeleted == 1) // 只查被删除的
        
        for row in try db.prepare(query) {
            results.append(FolderModel(
                folderId: row[folderId],
                folderTitle: row[folderTitle],
                createdAt: row[createdAt],
                updatedAt: row[updatedAt],
                isDeleted: true,
                syncState: 0
            ))
        }
        return results
    }
}

class NoteDAO {
    private let db: Connection
    private let table = Table("notes")
    
    private let noteId = Expression<String>("note_id")
    private let folderId = Expression<String?>("folder_id")
    private let title = Expression<String>("title")
    private let documentJson = Expression<String>("document_json")
    private let createdAt = Expression<Int64>("created_at")
    private let updatedAt = Expression<Int64>("updated_at")
    
    init(db: Connection) {
        self.db = db
    }
    
    func insert(_ model: NoteModel) throws {
        let insert = table.insert(
            noteId <- model.noteId,
            folderId <- model.folderId,
            title <- model.title,
            documentJson <- model.documentJson ?? "",
            createdAt <- model.createdAt,
            updatedAt <- model.updatedAt
        )
        try db.run(insert)
    }
    
    func update(_ model: NoteModel) throws {
        let item = table.filter(noteId == model.noteId)
        try db.run(item.update(
            folderId <- model.folderId,
            title <- model.title,
            documentJson <- model.documentJson ?? "",
            updatedAt <- model.updatedAt
        ))
    }
    
    func delete(id: String) throws {
        let item = table.filter(noteId == id)
        try db.run(item.delete())
    }
    
    func get(id: String) throws -> NoteModel? {
        let item = table.filter(noteId == id)
        if let row = try db.pluck(item) {
            return NoteModel(
                noteId: row[noteId],
                folderId: row[folderId],
                title: row[title],
                documentJson: row[documentJson],
                createdAt: row[createdAt],
                updatedAt: row[updatedAt]
            )
        }
        return nil
    }
    
    func getByFolder(id: String) throws -> [NoteModel] {
        var results = [NoteModel]()
        let query = table.filter(folderId == id).order(updatedAt.desc)
        for row in try db.prepare(query) {
            results.append(NoteModel(
                noteId: row[noteId],
                folderId: row[folderId],
                title: row[title],
                documentJson: row[documentJson],
                createdAt: row[createdAt],
                updatedAt: row[updatedAt]
            ))
        }
        return results
    }
    
    func getSummaryByFolder(id: String) throws -> [NoteModel] {
        var results = [NoteModel]()
        let query = table.select(noteId, folderId, title, createdAt, updatedAt)
            .filter(folderId == id)
            .order(updatedAt.desc)
        for row in try db.prepare(query) {
            results.append(NoteModel(
                noteId: row[noteId],
                folderId: row[folderId],
                title: row[title],
                documentJson: nil,
                createdAt: row[createdAt],
                updatedAt: row[updatedAt]
            ))
        }
        return results
    }
}

class NoteOpsLogDAO {
    private let db: Connection
    private let table = Table("note_ops_log")
    
    private let operationId = Expression<String>("operation_id")
    private let noteId = Expression<String>("note_id")
    private let version = Expression<Int64>("version")
    private let type = Expression<String>("type")
    private let payloadJson = Expression<String>("payload_json")
    private let timestamp = Expression<Int64>("timestamp")
    private let author = Expression<String>("author")
    
    init(db: Connection) {
        self.db = db
    }
    
    func insert(_ model: NoteOpsLogModel) throws {
        let insert = table.insert(
            operationId <- model.operationId,
            noteId <- model.noteId,
            version <- model.version,
            type <- model.type,
            payloadJson <- model.payloadJson,
            timestamp <- model.timestamp,
            author <- model.author
        )
        try db.run(insert)
    }
    
    func getByNote(id: String) throws -> [NoteOpsLogModel] {
        var results = [NoteOpsLogModel]()
        let query = table.filter(noteId == id).order(version.desc)
        for row in try db.prepare(query) {
            results.append(NoteOpsLogModel(
                operationId: row[operationId],
                noteId: row[noteId],
                version: row[version],
                type: row[type],
                payloadJson: row[payloadJson],
                timestamp: row[timestamp],
                author: row[author]
            ))
        }
        return results
    }
    
    func deleteByNote(id: String) throws {
        let item = table.filter(noteId == id)
        try db.run(item.delete())
    }
}

class NoteSnapshotDAO {
    private let db: Connection
    private let table = Table("note_snapshots")
    
    private let snapshotId = Expression<String>("snapshot_id")
    private let noteId = Expression<String>("note_id")
    private let baseVersion = Expression<Int64>("base_version")
    private let documentJson = Expression<String>("document_json")
    private let createdAt = Expression<Int64>("created_at")
    
    init(db: Connection) {
        self.db = db
    }
    
    func insert(_ model: NoteSnapshotModel) throws {
        let insert = table.insert(
            snapshotId <- model.snapshotId,
            noteId <- model.noteId,
            baseVersion <- model.baseVersion,
            documentJson <- model.documentJson,
            createdAt <- model.createdAt
        )
        try db.run(insert)
    }
    
    func getByNote(id: String) throws -> [NoteSnapshotModel] {
        var results = [NoteSnapshotModel]()
        let query = table.filter(noteId == id).order(baseVersion.desc)
        for row in try db.prepare(query) {
            results.append(NoteSnapshotModel(
                snapshotId: row[snapshotId],
                noteId: row[noteId],
                baseVersion: row[baseVersion],
                documentJson: row[documentJson],
                createdAt: row[createdAt]
            ))
        }
        return results
    }
    
    func deleteByNote(id: String) throws {
        let item = table.filter(noteId == id)
        try db.run(item.delete())
    }
}

class SQLiteDAO {
    let folder: FolderDAO
    let note: NoteDAO
    let opsLog: NoteOpsLogDAO
    let snapshot: NoteSnapshotDAO
    
    // 1. 标准依赖注入初始化，方便单元测试和解耦
    init(db: Connection) {
        self.folder = FolderDAO(db: db)
        self.note = NoteDAO(db: db)
        self.opsLog = NoteOpsLogDAO(db: db)
        self.snapshot = NoteSnapshotDAO(db: db)
    }
    
    // 2. 提供单例便捷访问属性，默认使用 SQLiteManager 的长连接
    static var shared: SQLiteDAO? {
        guard let db = SQLiteManager.shared.connection else {
            print("警告: 数据库尚未初始化，无法获取 SQLiteDAO 单例。请先调用 SQLiteManager.shared.setupDatabase()")
            return nil
        }
        return SQLiteDAO(db: db)
    }
}
