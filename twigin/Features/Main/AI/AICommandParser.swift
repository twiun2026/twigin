import Foundation

// MARK: - CommandMatcher

/// A strategy that attempts to recognise an AI command in a line of text.
///
/// Each matcher is responsible for exactly one syntax (e.g. `ai::`, `/translate`).
/// Register additional matchers in `AICommandParser` to extend the supported syntax
/// without touching existing matchers or the parser itself.
public protocol CommandMatcher: Sendable {
    /// Attempts to parse `line` into an `AIRequest`.
    ///
    /// - Parameter line: A single, already-trimmed line of editor text.
    /// - Returns: An `AIRequest` if the line matches this syntax, otherwise `nil`.
    func match(_ line: String) -> AIRequest?
}

// MARK: - PrefixCommandMatcher

/// Matches lines that start with a fixed prefix followed by the prompt text.
///
/// Example: prefix `"ai::"`, line `"ai::What is Swift?"` → `.ask` request.
public struct PrefixCommandMatcher: CommandMatcher {
    private let prefix: String
    private let command: AICommand

    /// - Parameters:
    ///   - prefix: The literal prefix that triggers this command.
    ///   - command: The `AICommand` to associate with matched lines.
    public init(prefix: String, command: AICommand) {
        self.prefix = prefix
        self.command = command
    }

    public func match(_ line: String) -> AIRequest? {
        guard line.hasPrefix(prefix) else { return nil }
        let prompt = String(line.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty else { return nil }
        return AIRequest(command: command, prompt: prompt)
    }
}

// MARK: - AICommandParser

/// Parses a single line of editor text into a structured `AIRequest`.
///
/// ## Supported syntax
/// | Input               | Command | Prompt           |
/// |---------------------|---------|------------------|
/// | `ai::What is Swift?`| `.ask`  | `What is Swift?` |
///
/// ## Extending the parser
/// To support new syntax (e.g. `/translate`, `@note filename summarize`):
/// 1. Create a new `CommandMatcher` implementation.
/// 2. Pass it in `additionalMatchers` when initialising `AICommandParser`.
///
/// No existing code needs to change.
///
/// ## Responsibilities
/// - Parsing only. No model calls, networking, or text mutations.
public struct AICommandParser: Sendable {

    private let matchers: [any CommandMatcher]

    /// The default set of built-in matchers.
    public static let defaultMatchers: [any CommandMatcher] = [
        PrefixCommandMatcher(prefix: "ai::", command: .ask),
    ]

    /// Creates a parser using the built-in matchers plus any additional ones.
    ///
    /// - Parameter additionalMatchers: Extra matchers appended after the defaults.
    public init(additionalMatchers: [any CommandMatcher] = []) {
        self.matchers = Self.defaultMatchers + additionalMatchers
    }

    /// Creates a parser with a fully custom matcher list, replacing the defaults.
    ///
    /// Use this when you need complete control over which syntaxes are recognised.
    public init(matchers: [any CommandMatcher]) {
        self.matchers = matchers
    }

    // MARK: - Parsing

    /// Parses `line` into an `AIRequest`, or returns `nil` if no pattern matches.
    ///
    /// Leading and trailing whitespace is stripped before matching.
    ///
    /// - Parameter line: A single line of editor text.
    /// - Returns: A fully populated `AIRequest`, or `nil`.
    public func parse(_ line: String) -> AIRequest? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        for matcher in matchers {
            if let request = matcher.match(trimmed) {
                return request
            }
        }
        return nil
    }
}
