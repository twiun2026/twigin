import Foundation
import SQLite // 引入 SQLite.swift

class SQLiteManager {
    // 1. 单例实例
    static let shared = SQLiteManager()
    
    // 私有化构造函数，防止外部直接实例化
    private init() {}

    private var db: Connection? // 保持长连接实例
    private let databaseFileName = "twigin.sqlite"

    /// 获取当前的数据库连接（如果需要给其他地方提供原生查询能力）
    var connection: Connection? {
        return db
    }

    /// 初始化数据库并返回数据库路径
    func setupDatabase() -> String? {
        if let _ = db {
            // 避免重复初始化
            return ""
        }

        do {
            // 1. 完美适配 macOS 沙盒的 Application Support 路径
            let fileManager = FileManager.default
            let appSupportDir = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let twiginDir = appSupportDir.appendingPathComponent("twigin", isDirectory: true)
            
            if !fileManager.fileExists(atPath: twiginDir.path) {
                try fileManager.createDirectory(at: twiginDir, withIntermediateDirectories: true, attributes: nil)
            }

            let dbURL = twiginDir.appendingPathComponent(databaseFileName)

            // 2. 兼容旧版本数据库迁移
            let legacyDBURL = twiginDir.appendingPathComponent("notes.sqlite3")
            if !fileManager.fileExists(atPath: dbURL.path) && fileManager.fileExists(atPath: legacyDBURL.path) {
                try fileManager.copyItem(at: legacyDBURL, to: dbURL)
            }

            // 3. 建立长连接
            let connection = try Connection(dbURL.path)
            self.db = connection

            // 4. 工业级性能核心 Pragma 开关
            try connection.execute("PRAGMA journal_mode=WAL;")
            try connection.execute("PRAGMA synchronous=NORMAL;")
            try connection.execute("PRAGMA foreign_keys=ON;")

            // 5. 执行建表、索引、FTS5 及 Trigger 语句
            try createSchema(db: connection)

            print("Database initialized at path: \(dbURL.path)")
            return dbURL.path
        } catch {
            print("SQLite 初始化失败: \(error)")
            return nil
        }
    }

    /// 释放数据库连接
    func closeDatabase() {
        self.db = nil
    }

    private func createSchema(db: Connection) throws {
        // 注意：
        // PRAGMA foreign_keys = ON
        // 建议在 Connection 创建完成后执行，而不是 migration 中执行。
        try db.execute("""
        PRAGMA foreign_keys = ON;
        """)
        
        // =====================================================
        // 1. 设备表
        // =====================================================
        try db.execute("""
        CREATE TABLE IF NOT EXISTS devices (
            device_rowid INTEGER PRIMARY KEY AUTOINCREMENT,
            device_id TEXT UNIQUE NOT NULL,
            user_id TEXT NOT NULL,
            last_server_sequence INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL
        );
        """)

        // =====================================================
        // 2. 文件夹表
        // =====================================================
        try db.execute("""
        CREATE TABLE IF NOT EXISTS folders (
            folder_rowid INTEGER PRIMARY KEY AUTOINCREMENT,
            folder_id TEXT UNIQUE NOT NULL,
            folder_title TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            is_deleted INTEGER NOT NULL DEFAULT 0,
            sync_state INTEGER NOT NULL DEFAULT 0
        );
        """)

        try db.execute("""
        CREATE INDEX IF NOT EXISTS idx_folders_updated
        ON folders(updated_at DESC);
        """)




        // =====================================================
        // 3. 笔记核心表
        // =====================================================

        try db.execute("""
        CREATE TABLE IF NOT EXISTS notes (

            -- 本地稳定 rowid
            note_rowid INTEGER PRIMARY KEY AUTOINCREMENT,

            -- 云端 UUID / ULID
            note_id TEXT UNIQUE NOT NULL,
            folder_id TEXT,
            title TEXT NOT NULL DEFAULT '未命名笔记',

            -- 完整编辑数据
            document_json TEXT NOT NULL,

            -- 专门给搜索使用
            search_text TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            is_deleted INTEGER NOT NULL DEFAULT 0,
            sync_state INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY(folder_id)
            REFERENCES folders(folder_id)
        );
        """)

        try db.execute("""
        CREATE INDEX IF NOT EXISTS idx_notes_folder
        ON notes(folder_id)
        WHERE is_deleted = 0;
        """)
        
        try db.execute("""
        CREATE INDEX IF NOT EXISTS idx_notes_updated
        ON notes(updated_at DESC);
        """)

        try db.execute("""
        CREATE INDEX IF NOT EXISTS idx_notes_title
        ON notes(title COLLATE NOCASE ASC)
        WHERE is_deleted = 0;
        """)

        // =====================================================
        // 4. Oplog 增量同步日志
        // =====================================================
        try db.execute("""
        CREATE TABLE IF NOT EXISTS note_ops_log (
            operation_rowid INTEGER PRIMARY KEY AUTOINCREMENT,
            operation_id TEXT UNIQUE NOT NULL,
            note_id TEXT NOT NULL,
        
            -- 当前设备产生的版本号
            version INTEGER NOT NULL,
            type TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            timestamp INTEGER NOT NULL,
            client_device_id TEXT NOT NULL,

            -- 云端同步后的全局顺序
            server_sequence INTEGER,
            sync_state INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY(client_device_id)
            REFERENCES devices(device_id)
        );
        """)



        // 同一个设备内同一个 note 的版本不能重复
        try db.execute("""
        CREATE UNIQUE INDEX IF NOT EXISTS idx_ops_device_version
        ON note_ops_log(
            note_id,
            client_device_id,
            version
        );
        """)

        // 云端拉取使用
        try db.execute("""
        CREATE INDEX IF NOT EXISTS idx_ops_server_sequence
        ON note_ops_log(server_sequence);
        """)

        // 本地上传队列
        try db.execute("""
        CREATE INDEX IF NOT EXISTS idx_ops_pending
        ON note_ops_log(sync_state,timestamp);
        """)

        // =====================================================
        // 5. Snapshot
        // =====================================================
        try db.execute("""
        CREATE TABLE IF NOT EXISTS note_snapshots (
            snapshot_rowid INTEGER PRIMARY KEY AUTOINCREMENT,
            snapshot_id TEXT UNIQUE NOT NULL,
            note_id TEXT NOT NULL,
            base_version INTEGER NOT NULL,
            document_json TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            FOREIGN KEY(note_id)
            REFERENCES notes(note_id)
        );
        """)

        try db.execute("""
        CREATE INDEX IF NOT EXISTS idx_snapshot_version
        ON note_snapshots(
            note_id,
            base_version DESC
        );
        """)

        // =====================================================
        // 6. FTS5
        // =====================================================
        try db.execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts
        USING fts5(
            note_id UNINDEXED,
            title,
            search_text,
            content='notes',
            content_rowid='note_rowid'
        );
        """)

        // =====================================================
        // 7. FTS Trigger
        // =====================================================

        // insert
        try db.execute("""
        CREATE TRIGGER IF NOT EXISTS trg_notes_insert_fts
        AFTER INSERT ON notes
        WHEN new.is_deleted = 0
        BEGIN
            INSERT INTO notes_fts(
                rowid,
                note_id,
                title,
                search_text
            )
            VALUES(
                new.note_rowid,
                new.note_id,
                new.title,
                new.search_text
            );
        END;
        """)
        
        // physical delete
        try db.execute("""
        CREATE TRIGGER IF NOT EXISTS trg_notes_delete_fts
        AFTER DELETE ON notes
        BEGIN
            INSERT INTO notes_fts(
                notes_fts,
                rowid,
                note_id,
                title,
                search_text
            )
            VALUES(
                'delete',
                old.note_rowid,
                old.note_id,
                old.title,
                old.search_text
            );
        END;
        """)

        // update
        try db.execute("""
        CREATE TRIGGER IF NOT EXISTS trg_notes_update_fts
        AFTER UPDATE ON notes
        BEGIN
            INSERT INTO notes_fts(
                notes_fts,
                rowid,
                note_id,
                title,
                search_text
            )
            VALUES(
                'delete',
                old.note_rowid,
                old.note_id,
                old.title,
                old.search_text
            );
            INSERT INTO notes_fts(
                rowid,
                note_id,
                title,
                search_text
            )
            SELECT
                new.note_rowid,
                new.note_id,
                new.title,
                new.search_text
            WHERE new.is_deleted = 0;
        END;
        """)

    }
}
