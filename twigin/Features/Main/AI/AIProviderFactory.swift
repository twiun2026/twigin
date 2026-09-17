import Foundation

public struct AIProviderFactory: Sendable {
    public static func makeProvider(for identifier: String) -> any AIProvider {
        let type = AIProviderType(rawValue: identifier) ?? .apple
        return makeProvider(for: type)
    }

    public static func makeProvider(for type: AIProviderType) -> any AIProvider {
        switch type {
        case .apple:  return AppleFoundationProvider()
        case .qwen:   return QWenProvider()
        case .gemini: return GeminiProvider()
        }
    }
}
