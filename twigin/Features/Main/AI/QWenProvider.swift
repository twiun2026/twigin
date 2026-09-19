import Foundation

// MARK: - QWenProvider
/// 专用于提供 QWen 对话服务的 Provider，基于 OpenAI 兼容的 HTTP 流式 API。
public final class QWenProvider: AIProvider {
    public struct Configuration: Sendable {
        public let endpoint: URL
        public let apiKey: String
        public let model: String
        public let timeoutInterval: TimeInterval

        public init(
            // 【修复点】补全了阿里云兼容模式的标准路径 /compatible-mode/v1/chat/completions
            endpoint: URL = URL(string: "https://ws-1ac7g9swxc2dszw3.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1")!,
            apiKey: String = "",
            model: String = "qwen3.8-flash",
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
        print("[QWenProvider] 正在发起对话请求 -> 模型: \(config.model), 目标地址: \(config.endpoint)")
        
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let apiKey = await APIKeyRetriever.retrieve(fallback: config.apiKey)
                    guard !apiKey.isEmpty else {
                        throw AIProviderError.unavailable("Qwen API Key 缺失。请在设置中保存您的 API Key。")
                    }

                    print("[QWenProvider] 正在发起对话请求 -> 模型: \(config.model)")
                    
                    var urlRequest = URLRequest(url: config.endpoint, timeoutInterval: config.timeoutInterval)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

                    // 组装对话消息体：支持传入 context 作为 system prompt，prompt 作为用户输入
                    var messages: [[String: String]] = []
                    if let context = request.context, !context.isEmpty {
                        messages.append(["role": "system", "content": context])
                        messages.append(["role": "user", "content": request.prompt])
                    } else {
                        messages.append(["role": "user", "content": request.prompt])
                    }
                    
                    let body: [String: Any] = [
                        "model": config.model,
                        "stream": true, // 开启流式返回
                        "messages": messages
                    ]
                    
                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await urlSession.bytes(for: urlRequest)

                    guard let http = response as? HTTPURLResponse else {
                        throw AIProviderError.unavailable("非法的 HTTP 响应。")
                    }

                    guard (200..<300).contains(http.statusCode) else {
                        var errorBody = ""
                        for try await line in bytes.lines { errorBody += line }
                        print("[QWenProvider] 错误响应体: \(errorBody)")
                        throw AIProviderError.unavailable("QWen HTTP \(http.statusCode): \(errorBody)")
                    }

                    // 逐行读取服务器下发的流式数据
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard payload != "[DONE]" else { break }
                        
                        // 核心：调用下方方法提取流式文本增量
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
                    print("[QWenProvider] 对话流中断错误: \(error)")
                    continuation.finish(throwing: AIProviderError.streamInterrupted(error))
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 核心私有方法：负责从 OpenAI 兼容格式的 SSE JSON 中解析出增量文本内容
    private static func extractDeltaContent(from jsonString: String) -> String? {
        guard
            let data = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let delta = choices.first?["delta"] as? [String: Any],
            let content = delta["content"] as? String
        else { return nil }
        return content
    }
}
