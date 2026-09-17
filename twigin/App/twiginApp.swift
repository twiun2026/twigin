//
//  twiginApp.swift
//  twigin
//
//  Created by Neo on 7/12/26.
//

import SwiftUI

@main
struct twiginApp: App {
    @StateObject private var themeManager = ThemeManager()
    
    // 启动时从持久化存储读取用户选择的 Provider，避免出现初始状态不一致
    private let aiService: AIService = {
        let stored = UserDefaults.standard.string(forKey: "selectedAIProvider") ?? AIProviderType.apple.rawValue
        return AIService(provider: AIProviderFactory.makeProvider(for: stored))
    }()

    var body: some Scene {
        WindowGroup {
            MainSplitView(aiService: aiService)
                .environmentObject(themeManager)
                .onChange(of: themeManager.selectedAIProvider) { _, newValue in
                    Task {
                        await aiService.updateProvider(AIProviderFactory.makeProvider(for: newValue))
                    }
                }
        }
        
        Settings {
            SettingsView()
                .environmentObject(themeManager)
        }
    }
}
