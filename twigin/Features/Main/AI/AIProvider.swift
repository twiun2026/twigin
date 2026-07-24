import Foundation

// MARK: - AICommand

/// A command type that specifies the intent of an AI request.
///
/// Extend this enum to support additional commands (e.g. `.translate`, `.summarize`).
public enum AICommand: Sendable, Hashable {
    case ask
    // Future: case translate, case summarize, case explain, case fixGrammar
}

// MARK: - AIRequest

/// A structured request to send to an AI provider.
///
/// `AIRequest` is provider-agnostic; any `AIProvider` conformer can consume it.
public struct AIRequest: Sendable {
    /// The command that describes the requested operation.
    public let command: AICommand
    /// The primary prompt text supplied by the user.
    public let prompt: String
    /// Optional surrounding document text used as context for the model.
    public let context: String?

    public init(command: AICommand, prompt: String, context: String? = nil) {
        self.command = command
        self.prompt = prompt
        self.context = context
    }
}

// MARK: - AIProviderError

/// Errors that any `AIProvider` implementation may throw.
public enum AIProviderError: Error, Sendable {
    /// The provider or underlying model is unavailable (e.g. assets not downloaded).
    case unavailable(String)
    /// The request is malformed or contains an unsupported field.
    case invalidRequest(String)
    /// The stream was interrupted by an underlying framework error.
    case streamInterrupted(any Error)
    /// The requested command is not supported by this provider.
    case unsupportedCommand(AICommand)
    /// The provider is temporarily rate-limited.
    case rateLimited
    /// The session's context window was exceeded.
    case contextWindowExceeded
    /// An unknown error occurred.
    case unknown
}

// MARK: - AIProvider

/// A unified streaming interface for any Large Language Model provider.
///
/// Conforming types must return incremental Markdown text chunks suitable
/// for insertion into `NSTextStorage`. The editor never needs to know
/// which provider is active.
///
/// ## Adding a new provider
/// 1. Create a type that conforms to `AIProvider`.
/// 2. Inject it wherever `any AIProvider` is required — no editor code changes needed.
public protocol AIProvider: Sendable {
    /// Streams incremental Markdown text from the underlying model.
    ///
    /// Each yielded `String` is a new chunk of text that has not been emitted
    /// before; callers should append chunks directly to their text storage.
    ///
    /// - Parameter request: The structured AI request.
    /// - Returns: An `AsyncThrowingStream` emitting Markdown text chunks.
    /// - Throws: `AIProviderError` (wrapped in the stream) on failure.
    func stream(request: AIRequest) -> AsyncThrowingStream<String, any Error>
}
