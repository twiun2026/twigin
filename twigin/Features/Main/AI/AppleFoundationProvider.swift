import Foundation
import FoundationModels

// MARK: - AppleFoundationProvider

/// An `AIProvider` backed by Apple Foundation Models.
///
/// Uses `LanguageModelSession` to generate text on-device with no networking.
/// Returns incremental Markdown text chunks via an `AsyncThrowingStream`.
///
/// This type is decoupled from any editor, view, or Markdown renderer.
/// It operates purely on `AIRequest` inputs and raw text outputs.
public final class AppleFoundationProvider: AIProvider {

    // MARK: - Properties
    private let instructions: String?
    
    // MARK: - Initialisation
    /// Creates a provider using the system's default language model with optional instructions.
    ///
    /// - Parameter instructions: System-level guidance for the model's behaviour.
    ///   Pass `nil` to use the model with no additional instructions.
    public init(instructions: String? = nil) {
        self.instructions = instructions
        // TODO: Future — accept `[any Tool]` to enable tool calling.
        // TODO: Future — accept a `Transcript` to resume a previous session.
    }

    // MARK: - AIProvider

    /// Streams incremental Markdown text from Apple Foundation Models.
    ///
    /// Each yielded chunk contains only the newly generated text since the
    /// previous chunk, making it suitable for direct appending into `NSTextStorage`.
    ///
    /// - Parameter request: The structured AI request.
    /// - Returns: An `AsyncThrowingStream` emitting incremental Markdown text.
    public func stream(request: AIRequest) -> AsyncThrowingStream<String, any Error> {
            let prompt = buildPrompt(for: request)
            let instructions = self.instructions

            return AsyncThrowingStream { continuation in
                Task {
                    do {
                        // 2. 每次请求时，创建全新的 Session，请求结束自动释放！
                        let session: LanguageModelSession
                        if let instructions {
                            session = LanguageModelSession(instructions: instructions)
                        } else {
                            session = LanguageModelSession()
                        }

                        let responseStream = session.streamResponse(to: prompt)
                        var lastIndex: String.Index? = nil

                        for try await snapshot in responseStream {
                            let fullText = snapshot.content
                            
                            // 初始化起始点
                            if lastIndex == nil {
                                lastIndex = fullText.startIndex
                            }
                            
                            guard let currentIndex = lastIndex, currentIndex < fullText.endIndex else {
                                continue
                            }

                            // 精确截取从 lastIndex 到最新 fullText.endIndex 的真正 Incremental Delta
                            let newChunk = String(fullText[currentIndex..<fullText.endIndex])
                            
                            if !newChunk.isEmpty {
                                continuation.yield(newChunk)
                                // 更新锚点至最新的结尾
                                lastIndex = fullText.endIndex
                            }
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: Self.mapError(error))
                    }
                }
            }
        }

    // MARK: - Private Helpers

    /// Assembles a prompt string from the command and optional context.
    private func buildPrompt(for request: AIRequest) -> String {
        var parts: [String] = []

        if let context = request.context, !context.isEmpty {
            parts.append("Context:\n\(context)")
        }

        switch request.command {
        case .ask:
            parts.append(request.prompt)
        }

        return parts.joined(separator: "\n\n")
    }

    /// Maps framework errors to `AIProviderError` for provider-agnostic error handling.
    private static func mapError(_ error: any Error) -> AIProviderError {
        guard let generationError = error as? LanguageModelSession.GenerationError else {
            return .streamInterrupted(error)
        }

        switch generationError {
        case .rateLimited:
            return .rateLimited
        case .exceededContextWindowSize:
            return .contextWindowExceeded
        case .assetsUnavailable:
            return .unavailable("Foundation Models assets are unavailable on this device.")
        case .guardrailViolation, .refusal:
            return .invalidRequest("The request was refused by the model's safety guardrails.")
        default:
            return .streamInterrupted(generationError)
        }
    }
}
