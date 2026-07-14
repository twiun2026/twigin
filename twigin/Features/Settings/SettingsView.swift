import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    
    var body: some View {
        TabView {
            ThemeSettingsView()
                .tabItem {
                    Label("Theme", systemImage: "paintpalette")
                }
        }
        .frame(width: 400, height: 300)
    }
}

struct ThemeSettingsView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    
    // For grid layout
    let columns = [GridItem(.adaptive(minimum: 120))]
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(ThemePresets.allThemes) { theme in
                    ThemePreviewCard(
                        theme: theme,
                        isSelected: theme.name == themeManager.currentTheme.name
                    ) {
                        themeManager.setTheme(theme)
                    }
                }
            }
            .padding(20)
        }
    }
}

struct ThemePreviewCard: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // Preview graphic
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(theme.bgFolderList)
                        .frame(width: 40)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Header")
                            .font(.headline)
                            .foregroundColor(theme.textHeader)
                        
                        Text("Normal text content...")
                            .font(.caption)
                            .foregroundColor(theme.textMain)
                            .lineLimit(2)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(theme.bgNoteEditor)
                }
                .frame(height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.blue : theme.borderLine, lineWidth: isSelected ? 3 : 1)
                )
                
                // Theme Name
                Text(theme.name)
                    .font(.subheadline)
                    .padding(.top, 8)
                    .foregroundColor(.primary)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview {
    SettingsView()
        .environmentObject(ThemeManager())
}
