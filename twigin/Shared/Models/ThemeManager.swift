import SwiftUI
import Combine

class ThemeManager: ObservableObject {
    @AppStorage("selectedThemeName") private var selectedThemeName: String = ThemePresets.simplistic.name
    @AppStorage("selectedFontName") private var storedFontName: String = "Avenir Next"
    @AppStorage("storedLineSpacing") private var storedLineSpacing: Double = 1.5
    @AppStorage("storedFontSize") private var storedFontSize: Double = 14
    @AppStorage("localStoragePath") private var storedLocalStoragePath: String = ""
    @AppStorage("backupToCloud") private var storedBackupToCloud: Bool = false

    @Published var currentTheme: AppTheme = ThemePresets.simplistic
    @Published var selectedFontName: String = "Avenir Next"
    @Published var lineSpacing: Double = 1.5
    @Published var fontSize: Double = 14
    @Published var localStoragePath: String = ""
    @Published var backupToCloud: Bool = false

    init() {
        if let savedTheme = ThemePresets.allThemes.first(where: { $0.name == selectedThemeName }) {
            self.currentTheme = savedTheme
        }
        self.selectedFontName = storedFontName
        self.lineSpacing = storedLineSpacing > 0 ? storedLineSpacing : 1.5
        self.fontSize = (10...20).contains(storedFontSize) ? storedFontSize : 14
        // Load persisted data settings
        self.localStoragePath = storedLocalStoragePath
        self.backupToCloud = storedBackupToCloud
    }

    func setTheme(_ theme: AppTheme) {
        currentTheme = theme
        selectedThemeName = theme.name
    }

    func setFont(_ name: String) {
        selectedFontName = name
        storedFontName = name
    }

    func setLocalStoragePath(_ path: String) {
        localStoragePath = path
        storedLocalStoragePath = path
    }

    func setBackupToCloud(_ enabled: Bool) {
        backupToCloud = enabled
        storedBackupToCloud = enabled
    }

    func setLineSpacing(_ value: Double) {
        lineSpacing = value
        storedLineSpacing = value
    }

    func setFontSize(_ value: Double) {
        fontSize = value
        storedFontSize = value
    }
}
