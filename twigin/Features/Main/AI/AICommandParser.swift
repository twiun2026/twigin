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

/// Example: line `"   Ai::What is Swift?"` → `.ask` request with prompt `"What is Swift?"`.
public struct PrefixCommandMatcher: CommandMatcher {
    private let prefix: String
    private let command: AICommand

    public init(prefix: String, command: AICommand) {
        self.prefix = prefix.lowercased()
        self.command = command
    }

    public func match(_ line: String) -> AIRequest? {
        // 1. 找到第一个非空白字符（空格/Tab）的起点位置
        guard let firstNonWhitespaceIndex = line.firstIndex(where: { !$0.isWhitespace }) else {
            return nil
        }
        
        // 从第一个非空白字符开始切片
        let subSequence = line[firstNonWhitespaceIndex...]
        
        // 2. 检查剩余长度是否足够放下一个前缀（例如 "ai::" 长度为 4）
        guard subSequence.count >= prefix.count else {
            return nil
        }
        
        // 3. 仅取前 4 个字符（针对这 4 个字符转小写比对）
        let prefixRangeEnd = subSequence.index(subSequence.startIndex, offsetBy: prefix.count)
        let actualPrefix = subSequence[..<prefixRangeEnd].lowercased()
        
        // 4. 比对：如果这 4 个字符转小写后不是 "ai::"，直接退出返回 nil
        guard actualPrefix == prefix else {
            return nil
        }
        
        // 5. 比对成功！截取 4 个字符之后的 Prompt 内容（保留原始大小写）
        let prompt = String(subSequence[prefixRangeEnd...])
            .trimmingCharacters(in: .whitespaces)
        
        guard !prompt.isEmpty else {
            return nil
        }
        
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
