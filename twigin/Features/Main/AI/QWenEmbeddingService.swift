import Foundation

// MARK: - QWenEmbeddingService
/// 专用于处理阿里云百炼（DashScope）文本向量化（Embedding）的独立服务。
public final class QWenEmbeddingService: Sendable {
    
    public struct Configuration: Sendable {
        public let endpoint: URL
        public let model: String
        public let timeoutInterval: TimeInterval

        public init(
            endpoint: URL = URL(string: "https://ws-1ac7g9swxc2dszw3.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1/embeddings")!,
            model: String = "qwen3.7-text-embedding",
            timeoutInterval: TimeInterval = 60
        ) {
            self.endpoint = endpoint
            self.model = model
            self.timeoutInterval = timeoutInterval
        }
    }

    private let configuration: Configuration
    private let urlSession: URLSession

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = configuration.timeoutInterval
        sessionConfig.timeoutIntervalForResource = configuration.timeoutInterval * 2
        self.urlSession = URLSession(configuration: sessionConfig)
    }

    // MARK: - Codable Response Structures
    private struct EmbeddingItem: Codable {
        let embedding: [Float]
    }

    private struct EmbeddingResponse: Codable {
        let data: [EmbeddingItem]
    }

    // MARK: - Public API

    /// 批量获取多段文本的向量数据
    /// - Parameters:
    ///   - inputs: 文本数组（支持批量请求以提高效率）
    ///   - apiKey: 阿里云百炼 API Key
    /// - Returns: 对应每段文本的 `[Float]` 向量数组
    public func fetchEmbeddings(for inputs: [String], apiKey: String? = nil) async throws -> [[Float]] {
        guard !inputs.isEmpty else { return [] }
        
        let effectiveApiKey = await AIKeyRetriever.retrieve(fallback: apiKey ?? "")
        guard !effectiveApiKey.isEmpty else {
            throw AIProviderError.unavailable("Qwen API Key 缺失，无法执行向量化。")
        }
        
        var urlRequest = URLRequest(url: configuration.endpoint, timeoutInterval: configuration.timeoutInterval)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(effectiveApiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": configuration.model,
            "input": inputs
        ]
        
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: urlRequest)// 可直接用 data(for:)
        
        // 实际上用 URLSession.shared.data(for:) 更直接简单，这里也可以用：
        // let (data, response) = try await urlSession.data(for: urlRequest)

        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError.unavailable("Non-HTTP response received from embedding service.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let serverMsg = String(data: data, encoding: .utf8) ?? "(no body)"
            throw AIProviderError.unavailable("Embedding API HTTP \(http.statusCode): \(serverMsg)")
        }

        let decoder = JSONDecoder()
        let embeddingResp = try decoder.decode(EmbeddingResponse.self, from: data)

        guard !embeddingResp.data.isEmpty else {
            throw AIProviderError.unavailable("Embedding API returned no vectors.")
        }

        return embeddingResp.data.map { $0.embedding }
    }

    /// 获取单条文本的向量数据
    public func fetchEmbedding(for text: String, apiKey: String) async throws -> [Float] {
        let results = try await fetchEmbeddings(for: [text], apiKey: apiKey)
        guard let first = results.first else {
            throw AIProviderError.unavailable("Failed to parse single embedding vector.")
        }
        return first
    }
}
