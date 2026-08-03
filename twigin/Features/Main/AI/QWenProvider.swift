import Foundation

// MARK: - QWenProvider
/// `AIProvider` backed by a QWen3 model via an OpenAI-compatible HTTP streaming API.

public final class QWenProvider: AIProvider {
    public struct Configuration: Sendable {
        public let endpoint: URL
        public let apiKey: String
        public let model: String
        public let timeoutInterval: TimeInterval

        public init(
            endpoint: URL = URL(string: "http://127.0.0.1:11434/v1/chat/completions")!,
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

    private let configuration: Configuration
    private let urlSession: URLSession

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = configuration.timeoutInterval
        sessionConfig.timeoutIntervalForResource = configuration.timeoutInterval * 2
        self.urlSession = URLSession(configuration: sessionConfig)
    }

    // MARK: - AIProvider

    public func stream(request: AIRequest) -> AsyncThrowingStream<String, any Error> {
        let config = configuration
        print("[QWenProvider] stream() called! Target model: \(config.model), Endpoint: \(config.endpoint)")
        
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlRequest = URLRequest(url: config.endpoint, timeoutInterval: config.timeoutInterval)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

                    var messages: [[String: String]] = []
                    if let systemPrompt = request.context, !systemPrompt.isEmpty {
                        messages.append(["role": "system", "content": systemPrompt])
                        messages.append(["role": "user", "content": request.prompt])
                    } else {
                        messages.append(["role": "user", "content": request.prompt])
                    }
                    let body: [String: Any] = [
                        "model": config.model,
                        "stream": true,
                        "messages": messages
                    ]
                    
                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await urlSession.bytes(for: urlRequest)

                    guard let http = response as? HTTPURLResponse else {
                        throw AIProviderError.unavailable("Non-HTTP response received.")
                    }
                    print("[QWenProvider] HTTP Response Code: \(http.statusCode)")
                    
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
                    print("[QWenProvider] Stream error caught: \(error)")
                    continuation.finish(throwing: AIProviderError.streamInterrupted(error))
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

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
