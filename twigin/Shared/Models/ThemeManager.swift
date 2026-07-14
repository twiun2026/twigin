import SwiftUI
import Combine

class ThemeManager: ObservableObject {
    @AppStorage("selectedThemeName") private var selectedThemeName: String = ThemePresets.simplistic.name
    
    @Published var currentTheme: AppTheme = ThemePresets.simplistic
    
    init() {
        // Find the theme matching the stored name, default to simplistic if not found
        if let savedTheme = ThemePresets.allThemes.first(where: { $0.name == selectedThemeName }) {
            self.currentTheme = savedTheme
        }
    }
    
    func setTheme(_ theme: AppTheme) {
        currentTheme = theme
        selectedThemeName = theme.name
    }
}
