import SwiftUI
import AppKit

/// Popover UI for Prompt metadata and prompt controls.
struct PromptPopoverView: View {
    @ObservedObject var vm: PromptPopoverViewModel
    @EnvironmentObject var themeManager: ThemeManager

    @FocusState private var customCategoryFocused: Bool
    @FocusState private var customStyleFocused: Bool

    private let customSentinel = "__CUSTOM__"

    var body: some View {
        VStack {
            Picker(selection: $vm.selectedTab, label: Text("")) {
                Text("Metadata").tag(0)
                Text("Prompt").tag(1)
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding([.top, .horizontal])

            Divider()

            if vm.selectedTab == 0 {
                // Tab 1: metadata
                metadataTab
            } else {
                // Tab 2: prompt controls (render only when in Prompt List folder)
                if vm.isPromptFolder {
                    promptTab
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Prompt controls are available only in the \"Prompt List\" folder.")
                            .foregroundColor(themeManager.currentTheme.textMuted)
                        Spacer()
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).fill(themeManager.currentTheme.bgNoteEditor))
                }
            }
        }
        .frame(minWidth: 360, minHeight: 240)
        .background(themeManager.currentTheme.bgNoteEditor)
        .foregroundColor(themeManager.currentTheme.textMain)
        .cornerRadius(8)
        .onAppear {
            Task { await vm.loadPromptOptions() }
        }
    }

    private var metadataTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Category")
                    .font(.headline)

                HStack {
                    Picker(selection: Binding(get: { vm.selectedCategory ?? "" }, set: { new in
                        if new == customSentinel {
                            vm.showCustomCategoryField = true
                            vm.selectedCategory = nil
                        } else {
                            vm.selectedCategory = new.isEmpty ? nil : new
                            vm.showCustomCategoryField = false
                        }
                    }), label: Text("Category")) {
                        Text("None").tag("")
                        ForEach(vm.categories, id: \.self) { c in
                            Text(c).tag(c)
                        }
                        Text("Customize...").tag(customSentinel)
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }

                if vm.showCustomCategoryField {
                    TextField("New category", text: $vm.customCategoryText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .focused($customCategoryFocused)
                        .onChange(of: customCategoryFocused) { _, focused in
                            if !focused {
                                Task { await vm.saveCustomCategoryIfNeeded() }
                            }
                        }
                }

                Divider()

                HStack {
                    Text("Words")
                        .font(.subheadline)
                        .foregroundColor(themeManager.currentTheme.textSecondary)
                    Spacer()
                    Text("\(vm.wordCount)")
                        .font(.body)
                        .foregroundColor(themeManager.currentTheme.textMain)
                }

                Divider()

                HStack {
                    Text("Created")
                        .font(.subheadline)
                        .foregroundColor(themeManager.currentTheme.textSecondary)
                    Spacer()
                    if let dt = vm.createdAt {
                        Text(Self.formatDate(dt))
                            .font(.body)
                            .foregroundColor(themeManager.currentTheme.textMain)
                    } else {
                        Text("–")
                            .font(.body)
                            .foregroundColor(themeManager.currentTheme.textMuted)
                    }
                }

                Divider()

                HStack {
                    Text("Updated")
                        .font(.subheadline)
                        .foregroundColor(themeManager.currentTheme.textSecondary)
                    Spacer()
                    if let dt = vm.updatedAt {
                        Text(Self.formatDate(dt))
                            .font(.body)
                            .foregroundColor(themeManager.currentTheme.textMain)
                    } else {
                        Text("–")
                            .font(.body)
                            .foregroundColor(themeManager.currentTheme.textMuted)
                    }
                }
            }

            Spacer()
        }
        .padding()
    }

    private var promptTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Category
                Text("Category")
                    .font(.headline)

                HStack {
                    Picker(selection: Binding(get: {
                        vm.selectedCategory ?? ""
                    }, set: { new in
                        if new == customSentinel {
                            vm.showCustomCategoryField = true
                            vm.selectedCategory = nil
                        } else {
                            vm.selectedCategory = new.isEmpty ? nil : new
                            vm.showCustomCategoryField = false
                        }
                    }), label: Text("Category")) {
                        Text("None").tag("")
                        ForEach(vm.categories, id: \.self) { c in
                            Text(c).tag(c)
                        }
                        Text("Customize...").tag(customSentinel)
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }

                if vm.showCustomCategoryField {
                    TextField("New category", text: $vm.customCategoryText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .focused($customCategoryFocused)
                        .onChange(of: customCategoryFocused) { _, focused in
                            if !focused {
                                Task { await vm.saveCustomCategoryIfNeeded() }
                            }
                        }
                }

                Divider()

                // Variables (read-only)
                Text("Variables")
                    .font(.headline)

                if vm.variables.isEmpty {
                    Text("No variables found in the document.")
                        .foregroundColor(themeManager.currentTheme.textSecondary)
                } else {
                    // Adaptive grid for chips
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)], spacing: 8) {
                        ForEach(vm.variables, id: \.self) { v in
                            Text(v)
                                .font(.caption)
                                .foregroundColor(themeManager.currentTheme.textMain)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .background(RoundedRectangle(cornerRadius: 10).fill(themeManager.currentTheme.bgFolderList.opacity(0.06)))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(themeManager.currentTheme.borderLine.opacity(0.08)))
                        }
                    }
                }

                Divider()

                // Target Style
                Text("Target Style")
                    .font(.headline)

                HStack {
                    Picker(selection: Binding(get: { vm.selectedStyle ?? "" }, set: { new in
                        if new == customSentinel {
                            vm.showCustomStyleField = true
                            vm.selectedStyle = nil
                        } else {
                            vm.selectedStyle = new.isEmpty ? nil : new
                            vm.showCustomStyleField = false
                        }
                    }), label: Text("Style")) {
                        Text("None").tag("")
                        ForEach(vm.styles, id: \.self) { s in
                            Text(s).tag(s)
                        }
                        Text("Customize...").tag(customSentinel)
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }

                if vm.showCustomStyleField {
                    TextField("New style", text: $vm.customStyleText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .focused($customStyleFocused)
                        .onChange(of: customStyleFocused) { _, focused in
                            if !focused {
                                Task { await vm.saveCustomStyleIfNeeded() }
                            }
                        }
                }

                Spacer()
            }
            .padding()
        }
    }

    // MARK: - Utilities
    private static func formatDate(_ d: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale.current
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: d)
    }
}

// Preview helper
struct PromptPopoverView_Previews: PreviewProvider {
    static var previews: some View {
        let vm = PromptPopoverViewModel()
        vm.wordCount = 123
        vm.createdAt = Date()
        vm.updatedAt = Date()
        vm.categories = ["Writing", "Study", "Personal"]
        vm.styles = ["Concise", "Formal"]
        vm.variables = ["NAME", "DATE"]
        return PromptPopoverView(vm: vm)
            .frame(width: 380, height: 320)
    }
}
