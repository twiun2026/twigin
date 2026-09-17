import Foundation

// MARK: - GeminiProvider
/// 专用于提供 Gemini 对话服务的 Provider，基于 Google AI Studio 原生流式 REST API。
public final class GeminiProvider: AIProvider {
    public struct Configuration: Sendable {
        public let endpoint: URL
        public let apiKey: String
        public let model: String
        public let timeoutInterval: TimeInterval

        public init(
            endpoint: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
            apiKey: String = "",
            model: String = "gemini-3.5-flash-lite", // 支持您指定的 Flash-Lite 模型
            timeoutInterval: TimeInterval = 120
        ) {
            self.endpoint = endpoint
            self.apiKey = apiKey
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

    // MARK: - AIProvider (Chat Streaming)

    public func stream(request: AIRequest) -> AsyncThrowingStream<String, any Error> {
        let config = configuration
        
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // 1. 从 Keychain 中获取 apiKey（带有 fallback 兜底）
                    let apiKey = await AIKeyRetriever.retrieve(account: "GeminiAPIKey", fallback: config.apiKey)
                    guard !apiKey.isEmpty else {
                        throw AIProviderError.unavailable("Gemini API Key 缺失。请在设置中保存您的 API Key。")
                    }

                    print("[GeminiProvider] 正在发起对话请求 -> 模型: \(config.model)")

                    // 2. 拼接 Gemini SSE 专属端点
                    let urlString = "\(config.endpoint.absoluteString)/models/\(config.model):streamGenerateContent?alt=sse&key=\(apiKey)"
                    guard let url = URL(string: urlString) else {
                        throw AIProviderError.invalidRequest("非法的 Gemini API 地址。")
                    }

                    var urlRequest = URLRequest(url: url, timeoutInterval: config.timeoutInterval)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
//                    urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

                    // 3. 组装 Gemini 的内容结构（支持 systemInstruction 和 contents）
                    var body: [String: Any] = [:]
                    
                    if let context = request.context, !context.isEmpty {
                        body["systemInstruction"] = [
                            "parts": [["text": context]]
                        ]
                    }
                    
                    body["contents"] = [
                        [
                            "role": "user",
                            "parts": [["text": request.prompt]]
                        ]
                    ]

                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await urlSession.bytes(for: urlRequest)

                    guard let http = response as? HTTPURLResponse else {
                        throw AIProviderError.unavailable("非法的 HTTP 响应。")
                    }

                    guard (200..<300).contains(http.statusCode) else {
                        var errorBody = ""
                        for try await line in bytes.lines { errorBody += line }
                        print("[GeminiProvider] 错误响应体: \(errorBody)")
                        throw AIProviderError.unavailable("Gemini HTTP \(http.statusCode): \(errorBody)")
                    }

                    // 4. 逐行读取 SSE 流式数据
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        
                        // 核心：调用下方方法提取 Gemini 返回的增量文本
                        if let chunk = Self.extractDeltaContent(from: payload), !chunk.isEmpty {
                            continuation.yield(chunk)
                        }
                    }

                    continuation.finish()

                } catch is CancellationError {
                    continuation.finish()
                } catch let err as AIProviderError {
                    continuation.finish(throwing: err)
                } catch {
                    print("[GeminiProvider] 对话流中断错误: \(error)")
                    continuation.finish(throwing: AIProviderError.streamInterrupted(error))
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private Helpers

    /// 负责从 Gemini SSE JSON 结构中解析增量文本
    /// 路径: candidates[0].content.parts[0].text
    private static func extractDeltaContent(from jsonString: String) -> String? {
        guard
            let data = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]],
            let text = parts.first?["text"] as? String
        else { return nil }
        return text
    }
}
