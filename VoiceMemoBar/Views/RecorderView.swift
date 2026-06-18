import SwiftUI

struct RecorderView: View {
    @EnvironmentObject var vm: RecorderViewModel
    @FocusState private var noteFocused: Bool

    var isActive: Bool {
        vm.state == .recording || vm.state == .paused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isActive {
                recordingView
            } else {
                idleView
            }
        }
        .background(.ultraThickMaterial)
        .animation(.easeInOut(duration: 0.15), value: vm.state)
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ActionRow(
                icon: "waveform",
                iconColor: .red.opacity(0.7),
                label: "Record",
                shortcut: "⌃⌥⌘R",
                action: { vm.startRecording() }
            )

            if let error = vm.errorMessage {
                errorBanner(error)
            }

            bottomBar
        }
        .frame(width: 280)
    }

    // MARK: - Recording

    private var recordingView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Timer header
            HStack(spacing: 8) {
                PulsingDot(color: vm.state == .paused ? .orange : .red)

                Text(vm.formattedTime)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.5))

                if vm.state == .paused {
                    Text("paused")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.25))
                        .textCase(.uppercase)
                        .tracking(0.5)
                }

                Spacer()

                if !vm.markers.isEmpty {
                    Text("\(vm.markers.count)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.orange.opacity(0.7))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            ThinDivider()

            // Actions
            if vm.state == .recording {
                ActionRow(icon: "pause", iconColor: .primary.opacity(0.4), label: "Pause", shortcut: "⌃⌥⌘P") {
                    vm.pauseRecording()
                }
            } else {
                ActionRow(icon: "play", iconColor: .primary.opacity(0.4), label: "Resume", shortcut: "⌃⌥⌘P") {
                    vm.resumeRecording()
                }
            }

            ActionRow(icon: "stop", iconColor: .primary.opacity(0.4), label: "Stop", shortcut: "⌃⌥⌘R") {
                vm.stopRecording()
            }

            ActionRow(icon: vm.markerActive ? "bookmark.fill" : "bookmark", iconColor: .orange.opacity(0.6), label: "Mark", shortcut: "⌃⌥⌘M") {
                vm.placeMarker()
            }

            ThinDivider()

            // Quick note
            HStack(spacing: 8) {
                Image(systemName: "pencil.line")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.2))
                    .frame(width: 16)

                TextField("Add a note…", text: $vm.quickNoteText)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                    .foregroundStyle(.primary.opacity(0.7))
                    .focused($noteFocused)
                    .onSubmit { vm.sendQuickNote() }

                ShortcutLabel("⌃⌥⌘N")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if let error = vm.errorMessage {
                errorBanner(error)
            }

            bottomBar
        }
        .frame(width: 280)
        .onChange(of: vm.quickNoteRequested) { _, requested in
            if requested { noteFocused = true }
        }
    }

    // MARK: - Components

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 9, weight: .medium))
            Text(message)
                .font(.system(size: 11))
                .lineLimit(2)
        }
        .foregroundStyle(.red.opacity(0.6))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var bottomBar: some View {
        HStack(spacing: 6) {
            LanguagePicker()
            Spacer()
            Button(action: {
                vm.requestOpenSettings()
            }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.15))
            }
            .buttonStyle(SubtleButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }
}

// MARK: - Reusable Components

struct ActionRow: View {
    let icon: String
    let iconColor: Color
    let label: String
    let shortcut: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.primary.opacity(0.65))

                Spacer()

                ShortcutLabel(shortcut)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct ShortcutLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.primary.opacity(0.15))
    }
}

struct ThinDivider: View {
    var body: some View {
        Rectangle()
            .fill(.primary.opacity(0.06))
            .frame(height: 0.5)
            .padding(.horizontal, 14)
    }
}

struct PulsingDot: View {
    let color: Color
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color.opacity(pulsing ? 0.5 : 0.9))
            .frame(width: 7, height: 7)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

struct SubtleButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(4)
            .background(isHovered ? Color.primary.opacity(0.05) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .onHover { isHovered = $0 }
    }
}

struct LanguagePicker: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TranscriptionLanguage.allCases) { lang in
                LanguagePill(
                    label: lang.label,
                    selected: settings.language == lang
                ) {
                    settings.language = lang
                }
            }
        }
    }
}

private struct LanguagePill: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary.opacity(selected ? 0.6 : 0.2))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(selected ? Color.primary.opacity(0.08) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
    }
}
