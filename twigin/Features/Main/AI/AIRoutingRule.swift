import Foundation

/// A lightweight routing rule protocol. Implementations can decide which
/// provider to use for a given `AIRequest`.
public protocol AIRoutingRule: Sendable {
    func evaluate(request: AIRequest) -> (any AIProvider)?
}

/// Simple token-threshold routing rule implementation.
public final class TokenThresholdRoutingRule: AIRoutingRule, Sendable {
    public let appleProvider: any AIProvider
    public let qwenProvider: any AIProvider
    public let threshold: Int

    public init(appleProvider: any AIProvider, qwenProvider: any AIProvider, threshold: Int = 2000) {
        self.appleProvider = appleProvider
        self.qwenProvider = qwenProvider
        self.threshold = threshold
    }

    private func estimateTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    public func evaluate(request: AIRequest) -> (any AIProvider)? {
        let combined = request.prompt + "\n" + (request.context ?? "")
        let tokens = estimateTokens(combined)
        return tokens > threshold ? qwenProvider : appleProvider
    }
}
