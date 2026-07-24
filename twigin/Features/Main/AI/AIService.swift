import Foundation

// MARK: - AIServiceError

/// Unified error type surfaced by ``AIService``.
///
/// All provider-specific errors are mapped to this type before reaching callers,
/// keeping upstream code decoupled from concrete provider implementations.
public enum AIServiceError: Error, Sendable {
    /// The request failed pre-flight validation (e.g., an empty prompt).
    case validationFailed(String)
    /// The underlying ``AIProvider`` reported a structured error.
    case providerError(AIProviderError)
    /// An unclassified error occurred during execution.
    case unknown(String)
}

extension AIServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .validationFailed(let message): "Validation failed: \(message)"
        case .providerError(let error):      "Provider error: \(error)"
        case .unknown(let message):          "Unknown error: \(message)"
        }
    }
}

// MARK: - AIEvent

/// A strongly-typed event emitted during an AI request lifecycle.
///
/// Consumers iterate the `AsyncThrowingStream` returned by
/// ``AIService/execute(request:)`` and react to each event in order.
/// Every stream is guaranteed to emit exactly one terminal event
/// (`.completed`, `.cancelled`, or `.failed`) before closing.
public enum AIEvent: Sendable {
    /// Emitted once immediately after the provider accepts the request.
    case started
    /// An incremental Markdown text chunk from the provider. Forward directly to the editor.
    case chunk(String)
    /// Emitted once when the provider signals the complete response has been streamed.
    case completed
    /// Emitted when the request was cancelled via ``AIService/cancel()``.
    case cancelled
    /// Emitted when an error terminates the request.
    case failed(AIServiceError)
}

// MARK: - AIExecutionState

/// The execution state of ``AIService`` at a given point in time.
///
/// State transitions follow a linear path:
/// `idle` → `thinking` → `streaming` → `completed | cancelled | failed`
public enum AIExecutionState: Sendable {
    /// No request is currently in-flight.
    case idle
    /// A request has been dispatched; waiting for the first token from the provider.
    case thinking
    /// Tokens are actively streaming from the provider.
    case streaming
    /// The most recent request completed successfully.
    case completed
    /// The most recent request was cancelled.
    case cancelled
    /// The most recent request terminated with an error.
    case failed(AIServiceError)
}

// MARK: - AIService

/// Orchestration layer that bridges ``AICommandParser`` output to an ``AIProvider``.
///
/// `AIService` accepts a fully-formed ``AIRequest``, validates it, forwards it to
/// the active provider, and relays the streamed response as strongly-typed
/// ``AIEvent`` values without buffering or mutation.
///
/// It deliberately knows nothing about text rendering, cursor positioning,
/// prompt construction, or networking — those concerns live in other layers.
///
/// ## Call Site Example
/// ```swift
/// let service = AIService(provider: AppleFoundationProvider())
/// let stream = await service.execute(request: request)
/// for try await event in stream {
///     switch event {
///     case .chunk(let text): // append text to editor
///     case .completed:       // finalize
///     case .failed(let err): // show error
///     default: break
///     }
/// }
/// ```
///
/// ## Concurrency
/// `AIService` is a Swift `actor`, guaranteeing data-race safety under
/// Swift 6 strict concurrency. All state mutations are actor-isolated and
/// serialised on the actor's executor.
public actor AIService {

    // MARK: - Private State

    private var provider: any AIProvider
    private var activeTask: Task<Void, Never>?

    /// Monotonically increasing counter that uniquely identifies each request.
    /// Tasks capture their generation at creation time and compare it before
    /// mutating `state`, preventing stale cancellations from overwriting
    /// a newer request's state.
    private var generation: UInt64 = 0

    // MARK: - Public State

    /// The current execution state, updated atomically as requests progress.
    ///
    /// Observe via the ``AIEvent`` stream for real-time updates, or read
    /// this property to query point-in-time state.
    public private(set) var state: AIExecutionState = .idle

    // MARK: - Initialisation

    /// Creates an `AIService` backed by the supplied provider.
    ///
    /// - Parameter provider: The initial AI provider. Can be replaced at runtime
    ///   via ``updateProvider(_:)`` without restarting the service.
    public init(provider: any AIProvider) {
        self.provider = provider
    }

    // MARK: - Public API

    /// Executes a fully-prepared AI request and returns a stream of lifecycle events.
    ///
    /// - If a previous request is in-flight it is cancelled before the new one begins.
    /// - The stream emits ``AIEvent/started`` first, followed by zero or more
    ///   ``AIEvent/chunk(_:)`` values, then exactly one terminal event.
    /// - Chunks are forwarded immediately without buffering to support low-latency UI.
    ///
    /// - Parameter request: A pre-built ``AIRequest`` produced by ``AICommandParser``.
    /// - Returns: An `AsyncThrowingStream` of ``AIEvent`` values.
    public func execute(request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
        stopActiveTask()

        let trimmedPrompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            return immediateFailureStream(.validationFailed("Prompt must not be empty."))
        }

        let (stream, continuation) = AsyncThrowingStream<AIEvent, Error>.makeStream()

        state = .thinking
        generation &+= 1
        let myGeneration = generation
        let currentProvider = provider

        activeTask = Task {
            do {
                continuation.yield(.started)

                // stream(request:) may be @MainActor-isolated on concrete providers
                // (e.g. AppleFoundationProvider stores a @MainActor LanguageModelSession).
                // Hop to the main actor to obtain the stream, then iterate from any context.
                let providerStream = await MainActor.run { currentProvider.stream(request: request) }
                var hasStartedStreaming = false
                for try await chunk in providerStream {
                    try Task.checkCancellation()
                    if !hasStartedStreaming {
                        hasStartedStreaming = true
                        if self.generation == myGeneration {
                            self.state = .streaming
                        }
                    }
                    continuation.yield(.chunk(chunk))
                }

                // Guard against cancellation arriving after the provider stream closes.
                try Task.checkCancellation()

                if self.generation == myGeneration { self.state = .completed }
                continuation.yield(.completed)
                continuation.finish()

            } catch is CancellationError {
                if self.generation == myGeneration { self.state = .cancelled }
                continuation.yield(.cancelled)
                continuation.finish()

            } catch let error as AIProviderError {
                let serviceError = AIServiceError.providerError(error)
                if self.generation == myGeneration { self.state = .failed(serviceError) }
                continuation.yield(.failed(serviceError))
                continuation.finish()

            } catch {
                let serviceError = AIServiceError.unknown(error.localizedDescription)
                if self.generation == myGeneration { self.state = .failed(serviceError) }
                continuation.yield(.failed(serviceError))
                continuation.finish()
            }
        }

        return stream
    }

    /// Cancels any currently active execution.
    ///
    /// The active stream will receive a ``AIEvent/cancelled`` event and close.
    /// Calling this when no request is in-flight is a no-op.
    public func cancel() async {
        stopActiveTask()
    }

    /// Replaces the active provider with a new one at runtime.
    ///
    /// Any in-flight request is cancelled before the switch occurs.
    /// Subsequent ``execute(request:)`` calls will use the new provider.
    /// The editor remains completely agnostic to which provider is active.
    ///
    /// - Parameter provider: The new AI provider to adopt.
    public func updateProvider(_ provider: any AIProvider) async {
        stopActiveTask()
        self.provider = provider
    }

    // MARK: - Private Helpers

    private func stopActiveTask() {
        activeTask?.cancel()
        activeTask = nil
    }

    /// Returns a stream that immediately emits a `.failed` event and closes.
    private func immediateFailureStream(_ error: AIServiceError) -> AsyncThrowingStream<AIEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<AIEvent, Error>.makeStream()
        continuation.yield(.failed(error))
        continuation.finish()
        return stream
    }
}
