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
    
    // 在最外层（App 根节点）组装具体的 Provider 和路由策略
    private let aiService: AIService = {
        let local = AppleFoundationProvider()
        let cloud = QWenProvider()
        let routing = RoutingAIProvider(localProvider: local, cloudProvider: cloud, tokenThreshold: 2000)
        return AIService(provider: routing)
    }()

    var body: some Scene {
        WindowGroup {
            MainSplitView(aiService: aiService)
                .environmentObject(themeManager)
        }
        
        Settings {
            SettingsView()
                .environmentObject(themeManager)
        }
    }
}
