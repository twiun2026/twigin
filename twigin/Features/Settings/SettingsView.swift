import SwiftUI
import AppKit
import Foundation

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
            DataSettingsView()
                .tabItem {
                    Label("Data", systemImage: "externaldrive")
                }
            // Artificial Intelligence settings tab
            AISettingsView()
                .tabItem {
                    Label("Artificial Intelligence", systemImage: "brain")
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

                FontSizeRow()

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

struct FontSizeRow: View {
    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        HStack(spacing: 12) {
            Text("Font Size")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)
            Slider(
                value: Binding(
                    get: { themeManager.fontSize },
                    set: { themeManager.setFontSize($0) }
                ),
                in: 10...20,
                step: 1
            )
            TextField(
                "",
                value: Binding(
                    get: { Int(themeManager.fontSize) },
                    set: { themeManager.setFontSize(max(10, min(20, Double($0)))) }
                ),
                format: .number
            )
            .textFieldStyle(.plain)
            .frame(width: 28)
            .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 4)
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

// MARK: - Data Settings

struct DataSettingsView: View {
    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Local storage location row
            HStack(spacing: 12) {
                Text("Local Storage Location:")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(width: 150, alignment: .leading)

                Button(action: openFolderPicker) {
                    HStack(spacing: 6) {
                        Text(themeManager.localStoragePath.isEmpty ? "Choose..." : themeManager.localStoragePath)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundColor(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                }
                .buttonStyle(PlainButtonStyle())
            }

            // Backup to cloud checkbox
            HStack(spacing: 12) {
                Toggle(isOn: Binding(
                    get: { themeManager.backupToCloud },
                    set: { themeManager.setBackupToCloud($0) }
                )) {
                    Text("Backup to Cloud:")
                        .font(.system(size: 13))
                }
                .toggleStyle(.checkbox)

                Spacer()
            }

            Spacer()
        }
        .padding(20)
    }

    private func openFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = "Choose Local Storage Folder"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                DispatchQueue.main.async {
                    themeManager.setLocalStoragePath(url.path)
                }
            }
        }
    }
}

// MARK: - AI Settings

struct AISettingsView: View {
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var apiKey: String = ""
    @State private var showKey: Bool = false
    @State private var showSavedAlert: Bool = false
    @State private var showErrorAlert: Bool = false
    @State private var errorMessage: String = ""
    @State private var isTesting: Bool = false
    @State private var showTestResultAlert: Bool = false
    @State private var testResultMessage: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Qwen API Key")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                if showKey {
                    TextField("Enter Qwen API Key", text: $apiKey)
                        .textFieldStyle(.plain)
                        .frame(height: 28)
                } else {
                    SecureField("Enter Qwen API Key", text: $apiKey)
                        .textFieldStyle(.plain)
                        .frame(height: 28)
                }

                Button(action: { showKey.toggle() }) {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))

            HStack(spacing: 8) {
                Spacer()
                Button(action: { Task { await testKey() } }) {
                    if isTesting {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .frame(width: 20, height: 20)
                    } else {
                        Text("Test Key")
                    }
                }
                .buttonStyle(.bordered)

                Button(action: { Task { await saveKey() } }) {
                    Text("Save")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
        .padding(20)
        .onAppear {
            Task { @MainActor in
                do {
                    if let saved = try await KeychainManager.shared.getApiKey() {
                        apiKey = saved
                    }
                } catch {
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                }
            }
        }
        .alert("Saved", isPresented: $showSavedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("API Key saved to Keychain.")
        }
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert("Test Result", isPresented: $showTestResultAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(testResultMessage)
        }
    }

    private func saveKey() async {
        do {
            try await KeychainManager.shared.save(apiKey: apiKey)
            await MainActor.run { showSavedAlert = true }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                showErrorAlert = true
            }
        }
    }

    private func testKey() async {
        isTesting = true
        defer { Task { @MainActor in isTesting = false } }

        // Lightweight validation: send a non-streaming POST to verify auth
        guard !apiKey.isEmpty else {
            await MainActor.run {
                testResultMessage = "API Key is empty. Please enter a key before testing."
                showTestResultAlert = true
            }
            return
        }

        let endpoint = URL(string: "https://ws-1ac7g9swxc2dszw3.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1/embeddings")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": "qwen3.7-text-embedding",
            "input": "ping",
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if (200..<300).contains(http.statusCode) {
                    await MainActor.run {
                        testResultMessage = "Key appears valid (HTTP \(http.statusCode))."
                        showTestResultAlert = true
                    }
                } else {
                    let serverMsg = String(data: data, encoding: .utf8) ?? "(no body)"
                    await MainActor.run {
                        testResultMessage = "Server returned HTTP \(http.statusCode): \(serverMsg)"
                        showTestResultAlert = true
                    }
                }
            } else {
                await MainActor.run {
                    testResultMessage = "Non-HTTP response received."
                    showTestResultAlert = true
                }
            }
        } catch {
            await MainActor.run {
                testResultMessage = "Network error: \(error.localizedDescription)"
                showTestResultAlert = true
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(ThemeManager())
}
