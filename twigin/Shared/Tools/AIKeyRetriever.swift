import Foundation

// MARK: - AIKeyRetriever
/// 统一负责管理和动态获取 AI 模型所需的 API Key
public enum AIKeyRetriever {
    
    /// 从 Keychain 中异步获取最新的 API Key。
    /// 如果 Keychain 中没有或读取失败，则回退并返回传入的 fallback 默认值。
    /// - Parameter fallback: 备用 Key（通常来自 Configuration 中预设的值）
    /// - Returns: 可用的有效 API Key 字符串
    public static func retrieve(fallback: String = "") async -> String {
        do {
            if let key = try await KeychainManager.shared.getApiKey(), !key.isEmpty {
                return key
            }
        } catch {
            print("[AIKeyRetriever] 从 Keychain 读取 API Key 失败: \(error)")
        }
        return fallback
    }
}
