import SwiftUI
import Combine

class ThemeManager: ObservableObject {
    @AppStorage("selectedThemeName") private var selectedThemeName: String = ThemePresets.simplistic.name
    @AppStorage("selectedFontName") private var storedFontName: String = "Avenir Next"
    @AppStorage("storedLineSpacing") private var storedLineSpacing: Double = 1.5

    @Published var currentTheme: AppTheme = ThemePresets.simplistic
    @Published var selectedFontName: String = "Avenir Next"
    @Published var lineSpacing: Double = 1.5

    init() {
        if let savedTheme = ThemePresets.allThemes.first(where: { $0.name == selectedThemeName }) {
            self.currentTheme = savedTheme
        }
        self.selectedFontName = storedFontName
        self.lineSpacing = storedLineSpacing > 0 ? storedLineSpacing : 1.5
    }

    func setTheme(_ theme: AppTheme) {
        currentTheme = theme
        selectedThemeName = theme.name
    }

    func setFont(_ name: String) {
        selectedFontName = name
        storedFontName = name
    }

    func setLineSpacing(_ value: Double) {
        lineSpacing = value
        storedLineSpacing = value
    }
}
