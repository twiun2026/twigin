import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        TabView {
            ThemeSettingsView()
                .tabItem {
                    Label("Theme", systemImage: "paintpalette")
                }
            FontSettingsView()
                .tabItem {
                    Label("Font", systemImage: "textformat")
                }
        }
        .frame(width: 480, height: 420)
    }
}

// MARK: - Theme Settings

struct ThemeSettingsView: View {
    @EnvironmentObject private var themeManager: ThemeManager

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

                Text(theme.name)
                    .font(.subheadline)
                    .padding(.top, 8)
                    .foregroundColor(.primary)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Font Settings

struct FontSettingsView: View {
    @EnvironmentObject private var themeManager: ThemeManager

    private let availableFonts = ["Times New Roman", "Avenir Next", "Menlo"]
    private let lineSpacings: [Double] = [1.0, 1.5, 2.0]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    ForEach(availableFonts, id: \.self) { fontName in
                        FontPreviewCard(
                            fontName: fontName,
                            isSelected: fontName == themeManager.selectedFontName
                        ) {
                            themeManager.setFont(fontName)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                Divider()
                    .padding(.vertical, 4)

                VStack(spacing: 8) {
                    ForEach(lineSpacings, id: \.self) { value in
                        LineHeightRow(
                            spacing: value,
                            isSelected: value == themeManager.lineSpacing
                        ) {
                            themeManager.setLineSpacing(value)
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

struct FontPreviewCard: View {
    let fontName: String
    let isSelected: Bool
    let action: () -> Void

    private var shortName: String {
        switch fontName {
        case "Times New Roman": return "Times"
        case "Avenir Next": return "Avenir"
        default: return fontName
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text("Ag")
                    .font(.custom(fontName, size: 32))
                    .foregroundColor(.primary)
                Text(shortName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 80)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: isSelected ? 2 : 0.5)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct LineHeightRow: View {
    let spacing: Double
    let isSelected: Bool
    let action: () -> Void

    private var label: String {
        switch spacing {
        case 1.0: return "Compact"
        case 1.5: return "Normal"
        case 2.0: return "Relaxed"
        default: return ""
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.1f", spacing))
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary)
                    Text(label)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(width: 60, alignment: .leading)

                LineSpacingPreview(spacing: spacing)
                    .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40)

                Group {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .hidden()
                    }
                }
                .frame(width: 20)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: isSelected ? 1.5 : 0.5)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct LineSpacingPreview: View {
    let spacing: Double

    var body: some View {
        Canvas { context, size in
            let baseSize: CGFloat = 9
            let lineHeight = baseSize * CGFloat(spacing)
            let barHeight: CGFloat = 2.5
            let corner: CGFloat = 1.5
            let widths: [CGFloat] = [
                size.width,
                size.width * 0.80,
                size.width * 0.92,
                size.width * 0.65,
                size.width * 0.88
            ]

            var y: CGFloat = lineHeight / 2
            var i = 0
            while y <= size.height + lineHeight / 2 {
                let rect = CGRect(x: 0, y: y - barHeight / 2,
                                  width: widths[i % widths.count], height: barHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: corner),
                             with: .color(.primary.opacity(0.22)))
                y += lineHeight
                i += 1
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(ThemeManager())
}
