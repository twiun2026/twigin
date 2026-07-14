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
    
    var body: some Scene {
        WindowGroup {
            MainSplitView()
                .environmentObject(themeManager)
        }
        
        Settings {
            SettingsView()
                .environmentObject(themeManager)
        }
    }
}
