import SwiftUI

struct TranscribingView: View {
    @EnvironmentObject var vm: RecorderViewModel
    @State private var dotCount = 0
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // Animated waveform bars
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { i in
                        WaveBar(delay: Double(i) * 0.15)
                    }
                }
                .frame(width: 16)

                VStack(alignment: .leading, spacing: 4) {
                    Text(vm.transcriptionPhase + String(repeating: ".", count: dotCount))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.primary.opacity(0.4))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Phase progress bar
                    HStack(spacing: 3) {
                        ForEach(0..<vm.transcriptionPhaseCount, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(.primary.opacity(i <= vm.transcriptionPhaseIndex ? 0.3 : 0.08))
                                .frame(height: 2)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            ThinDivider()

            // Persistent bottom bar matching RecorderView
            HStack(spacing: 6) {
                LanguagePicker()
                Spacer()
                Button(action: {
                    vm.requestOpenSettings()
                }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.45))
                }
                .buttonStyle(SubtleButtonStyle())
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 8)
        }
        .frame(width: 280)
        .background(.ultraThickMaterial)
        .onReceive(timer) { _ in
            dotCount = (dotCount + 1) % 4
        }
    }
}

struct WaveBar: View {
    let delay: Double
    @State private var animating = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(.primary.opacity(0.2))
            .frame(width: 2, height: animating ? 12 : 4)
            .animation(
                .easeInOut(duration: 0.4)
                .repeatForever(autoreverses: true)
                .delay(delay),
                value: animating
            )
            .onAppear { animating = true }
    }
}
