import AppKit
import SwiftUI

/// The Settings window (⌘,). Every control writes straight into
/// `EditorSettings.shared`, which all open editors observe, so changes
/// apply live — there is no OK button.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Editor", systemImage: "character.cursor.ibeam") {
                EditorSettingsPane()
            }
            Tab("IntelliSense", systemImage: "text.badge.plus") {
                IntelliSenseSettingsPane()
            }
            Tab("Preview", systemImage: "eye") {
                PreviewSettingsPane()
            }
        }
        .frame(width: 480)
        .scenePadding()
    }
}

private struct EditorSettingsPane: View {
    @Bindable private var settings = EditorSettings.shared
    @State private var fontFamilies: [MonospacedFontFamily] = []

    var body: some View {
        Form {
            Section("Font") {
                Picker("Font:", selection: $settings.fontName) {
                    Text("System Monospaced").tag("")
                    Divider()
                    ForEach(fontFamilies) { family in
                        Text(family.name).tag(family.fontName)
                    }
                    // Keep a configured font selectable even if it is not
                    // (or no longer) in the list.
                    if !settings.fontName.isEmpty, !fontFamilies.contains(where: { $0.fontName == settings.fontName }) {
                        Text(settings.fontName).tag(settings.fontName)
                    }
                }
                Stepper(value: $settings.fontSize, in: EditorSettings.minFontSize...EditorSettings.maxFontSize, step: 1) {
                    LabeledContent("Size:") {
                        Text("\(Int(settings.fontSize)) pt").monospacedDigit()
                    }
                }
                Text("The quick brown fox jumps over the lazy dog — 0O 1lI")
                    .font(Font(settings.font))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }

            Section("Indentation") {
                Stepper(value: $settings.tabWidth, in: 1...8) {
                    LabeledContent("Tab width:") {
                        Text("\(settings.tabWidth)").monospacedDigit()
                    }
                }
                Toggle("Indent with spaces", isOn: $settings.indentWithSpaces)
            }

            Section("Display") {
                Toggle("Wrap lines", isOn: $settings.wrapsLines)
                Toggle("Show line numbers", isOn: $settings.showsLineNumbers)
                Toggle("Show invisible characters", isOn: $settings.showsInvisibles)
                Toggle("Highlight current line", isOn: $settings.highlightsCurrentLine)
                Toggle("Show status bar", isOn: $settings.showsStatusBar)
            }

            Section("Typing") {
                Toggle("Insert closing brackets and quotes", isOn: $settings.autoPairs)
                Toggle("Renumber ordered lists automatically", isOn: $settings.renumbersLists)
                Toggle("Smart quotes", isOn: $settings.smartQuotes)
                Toggle("Check spelling while typing", isOn: $settings.spellChecking)
            }

            ResetSection()
        }
        .formStyle(.grouped)
        .task {
            if fontFamilies.isEmpty { fontFamilies = await MonospacedFontFamily.installed() }
        }
    }
}

private struct IntelliSenseSettingsPane: View {
    @Bindable private var settings = EditorSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Show completions while typing", isOn: $settings.showsCompletions)
            } footer: {
                Text("When off, completions appear only on ⌃Space.")
                    .foregroundStyle(.secondary)
            }
            ResetSection()
        }
        .formStyle(.grouped)
    }
}

private struct PreviewSettingsPane: View {
    @Bindable private var settings = EditorSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("Default view for new windows:", selection: $settings.defaultViewMode) {
                    ForEach(ViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("Editor and preview:", selection: $settings.splitOrientation) {
                    ForEach(SplitOrientation.allCases) { orientation in
                        Text(orientation.title).tag(orientation)
                    }
                }
                .pickerStyle(.radioGroup)
                Toggle("Scroll preview with editor", isOn: $settings.syncScrolling)
            }
            ResetSection()
        }
        .formStyle(.grouped)
    }
}

/// Shown at the bottom of every pane; resets all panes, not just this one.
private struct ResetSection: View {
    @State private var isConfirming = false

    var body: some View {
        Section {
            HStack {
                Spacer()
                Button("Reset to Defaults…") { isConfirming = true }
            }
        }
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $isConfirming) {
            Button("Reset", role: .destructive) { EditorSettings.shared.resetToDefaults() }
        } message: {
            Text("This affects the Editor, IntelliSense and Preview settings.")
        }
    }
}

/// An installed font family whose regular face is fixed-pitch.
struct MonospacedFontFamily: Identifiable, Hashable, Sendable {
    /// Family name for display ("Menlo").
    var name: String
    /// PostScript name of the regular face ("Menlo-Regular"), which is what
    /// `EditorSettings.fontName` stores and `NSFont(name:size:)` resolves.
    var fontName: String
    var id: String { fontName }

    /// Instantiating a font for every installed family takes a moment, so
    /// the list is built off the main thread and cached.
    static func installed() async -> [MonospacedFontFamily] {
        if let cached = await Cache.shared.families { return cached }
        let families = await Task.detached(priority: .userInitiated) { scan() }.value
        await Cache.shared.store(families)
        return families
    }

    nonisolated static func scan() -> [MonospacedFontFamily] {
        let manager = NSFontManager.shared
        var result: [MonospacedFontFamily] = []
        for family in manager.availableFontFamilies where !family.hasPrefix(".") {
            guard let font = manager.font(withFamily: family, traits: [], weight: 5, size: 13),
                  font.isFixedPitch
            else { continue }
            result.append(MonospacedFontFamily(name: family, fontName: font.fontName))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private actor Cache {
        static let shared = Cache()
        var families: [MonospacedFontFamily]?
        func store(_ families: [MonospacedFontFamily]) { self.families = families }
    }
}
