import Foundation

// MARK: - AIKeyRetriever
/// 统一负责管理和动态获取 AI 模型所需的 API Key
public enum AIKeyRetriever {
    
    /// 从 Keychain 中异步获取指定的 API Key。
    /// - Parameters:
    ///   - account: Keychain 账户名（如 "GeminiAPIKey"），不传则读取默认账户
    ///   - fallback: 备用 Key（通常来自 Configuration 中预设的值）
    /// - Returns: 可用的有效 API Key 字符串
    public static func retrieve(account: String? = nil, fallback: String = "") async -> String {
        do {
            let key: String?
            if let account = account {
                key = try await KeychainManager.shared.getApiKey(account: account)
            } else {
                key = try await KeychainManager.shared.getApiKey()
            }
            
            if let validKey = key, !validKey.isEmpty {
                return validKey
            }
        } catch {
            print("[AIKeyRetriever] 从 Keychain 读取 API Key 失败: \(error)")
        }
        return fallback
    }
}
