import Foundation

// MARK: - QWenProvider

/// `AIProvider` backed by a QWen3 model via an OpenAI-compatible HTTP streaming API.
///
/// Uses native `URLSession` SSE streaming — no third-party SDKs.
/// Defaults to a locally-running Ollama instance; swap `Configuration` for cloud endpoints
/// (e.g. Alibaba Cloud DashScope at `https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions`).
public final class QWenProvider: AIProvider {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// OpenAI-compatible chat completions endpoint.
        public let endpoint: URL
        /// Sent in `Authorization: Bearer <apiKey>`. Use `"ollama"` for local Ollama.
        public let apiKey: String
        /// Model identifier, e.g. `"qwen3:8b"` (Ollama) or `"qwen-plus"` (DashScope).
        public let model: String
        /// Per-request URL timeout in seconds.
        public let timeoutInterval: TimeInterval

        public init(
            endpoint: URL = URL(string: "http://localhost:11434/v1/chat/completions")!,
            apiKey: String = "ollama",
            model: String = "qwen3:8b",
            timeoutInterval: TimeInterval = 120
        ) {
            self.endpoint = endpoint
            self.apiKey = apiKey
            self.model = model
            self.timeoutInterval = timeoutInterval
        }
    }

    // MARK: - Properties

    private let configuration: Configuration

    // MARK: - Initialisation

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - AIProvider

    /// Streams incremental text from the QWen model via OpenAI-compatible SSE.
    ///
    /// The prompt is forwarded as-is; callers are responsible for injecting any
    /// instruction prefix or word-limit constraints before constructing `AIRequest`.
    public func stream(request: AIRequest) -> AsyncThrowingStream<String, any Error> {
        let config = configuration
        let prompt = buildPrompt(for: request)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlRequest = URLRequest(url: config.endpoint, timeoutInterval: config.timeoutInterval)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

                    let body: [String: Any] = [
                        "model": config.model,
                        "stream": true,
                        "messages": [["role": "user", "content": prompt]]
                    ]
                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)

                    guard let http = response as? HTTPURLResponse else {
                        throw AIProviderError.unavailable("Non-HTTP response received.")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw AIProviderError.unavailable("HTTP \(http.statusCode) from \(config.endpoint.host ?? "endpoint")")
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard payload != "[DONE]" else { break }
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
                    continuation.finish(throwing: AIProviderError.streamInterrupted(error))
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private Helpers

    private func buildPrompt(for request: AIRequest) -> String {
        guard let context = request.context, !context.isEmpty else { return request.prompt }
        return "\(context)\n\n\(request.prompt)"
    }

    /// Extracts the `delta.content` string from an OpenAI-compatible SSE JSON payload.
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
