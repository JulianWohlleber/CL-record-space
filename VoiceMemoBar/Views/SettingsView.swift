import SwiftUI

struct SettingsView: View {
    @State private var vaultPath: String = AppSettings.shared.baseFolderPath ?? "Not set"
    @State private var isHoveringChange = false
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("Settings")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.7))
                .padding(.bottom, 20)

            // Vault section
            SectionHeader("Storage")

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Vault folder")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.5))
                    Text(vaultPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.3))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button("Change…") {
                    changeVaultFolder()
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(Color.primary.opacity(isHoveringChange ? 0.6 : 0.35))
                .onHover { isHoveringChange = $0 }
            }
            .padding(.vertical, 10)

            SettingsDivider()
                .padding(.top, 4)
                .padding(.bottom, 16)

            // Transcription section
            SectionHeader("Transcription")

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Engine")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.5))
                    Text(settings.engine == .whisper ? "More accurate, slower" : "Faster, less accurate")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.3))
                }

                Spacer()

                Picker("", selection: $settings.engine) {
                    ForEach(TranscriptionEngine.allCases) { engine in
                        Text(engine.label).tag(engine)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            .padding(.vertical, 10)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Language")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.5))
                }

                Spacer()

                Picker("", selection: $settings.language) {
                    ForEach(TranscriptionLanguage.allCases) { lang in
                        Text(lang.label).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }
            .padding(.vertical, 6)

            SettingsDivider()
                .padding(.top, 4)
                .padding(.bottom, 16)

            // Shortcuts section
            SectionHeader("Shortcuts")

            VStack(spacing: 0) {
                ShortcutRow(label: "Start / Stop", shortcut: "⌃⌥⌘R")
                ShortcutRow(label: "Pause / Resume", shortcut: "⌃⌥⌘P")
                ShortcutRow(label: "Place Marker", shortcut: "⌃⌥⌘M")
                ShortcutRow(label: "Quick Note", shortcut: "⌃⌥⌘N")
            }

            Spacer()

            // Version
            HStack {
                Spacer()
                Text("record_space 1.0")
                    .font(.system(size: 10))
                    .foregroundStyle(.primary.opacity(0.15))
                Spacer()
            }
        }
        .padding(28)
        .frame(minWidth: 380, minHeight: 320)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func changeVaultFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a new vault folder"
        panel.prompt = "Select"

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.appendingPathComponent("recordings"),
            withIntermediateDirectories: true
        )
        try? fm.createDirectory(
            at: url.appendingPathComponent("transcripts"),
            withIntermediateDirectories: true
        )

        AppSettings.shared.stopAccessingBaseFolder()
        AppSettings.shared.saveBaseFolder(url)
        vaultPath = url.path
    }
}

// MARK: - Settings Components

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.25))
            .tracking(0.8)
            .padding(.bottom, 8)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(.primary.opacity(0.06))
            .frame(height: 0.5)
    }
}

struct ShortcutRow: View {
    let label: String
    let shortcut: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.45))
            Spacer()
            KeyCapGroup(shortcut: shortcut)
        }
        .padding(.vertical, 6)
    }
}

struct KeyCapGroup: View {
    let shortcut: String

    var body: some View {
        Text(shortcut)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.primary.opacity(0.3))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }
}
