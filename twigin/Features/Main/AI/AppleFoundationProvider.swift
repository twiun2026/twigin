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
@available(macOS 26.0, *)
public final class AppleFoundationProvider: AIProvider {

    // MARK: - Properties

    private let session: LanguageModelSession

    // MARK: - Initialisation

    /// Creates a provider using the system's default language model with optional instructions.
    ///
    /// - Parameter instructions: System-level guidance for the model's behaviour.
    ///   Pass `nil` to use the model with no additional instructions.
    public init(instructions: String? = nil) {
        if let instructions {
            self.session = LanguageModelSession(instructions: instructions)
        } else {
            self.session = LanguageModelSession()
        }
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
        let session = self.session
        let prompt = buildPrompt(for: request)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let responseStream = session.streamResponse(to: prompt)
                    var emittedLength = 0

                    // TODO: Future — inspect stream for tool-call interjections before forwarding text.
                    // TODO: Future — support structured output via Generable conformance.

                    for try await snapshot in responseStream {
                        let fullText = snapshot.content
                        guard fullText.count > emittedLength else { continue }

                        let startIndex = fullText.index(
                            fullText.startIndex,
                            offsetBy: emittedLength
                        )
                        let newChunk = String(fullText[startIndex...])
                        continuation.yield(newChunk)
                        emittedLength = fullText.count
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
