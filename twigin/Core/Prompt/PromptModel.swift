import Foundation

/// 本地 Prompt 模型
/// 可序列化为 JSON 存入 SQLite 的 TEXT 字段（variables / targetStyle）
public struct PromptModel: Identifiable, Codable, Sendable {
    public var id: String
    public var title: String
    public var category: String?
    public var content: String
    /// 动态变量列表，存储时会编码为 JSON 字符串写入 SQLite TEXT 字段
    public var variables: [String]
    /// 目标文风/Style 数组，同样会以 JSON 字符串形式存储在 SQLite 的 TEXT 字段
    public var targetStyle: [String]
    /// 是否为系统内置模板（数据库字段 is_system）
    public var isSystem: Bool
    /// 创建 / 更新时间，解析时会尝试从数据库的 DATETIME 文本转换为 Date
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString,
                title: String,
                category: String? = nil,
                content: String,
                variables: [String] = [],
                targetStyle: [String] = [],
                isSystem: Bool = false,
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.category = category
        self.content = content
        self.variables = variables
        self.targetStyle = targetStyle
        self.isSystem = isSystem
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
