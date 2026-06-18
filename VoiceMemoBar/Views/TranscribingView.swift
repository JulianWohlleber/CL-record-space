import SwiftUI

struct TranscribingView: View {
    @State private var dotCount = 0
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 10) {
            // Animated waveform bars
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    WaveBar(delay: Double(i) * 0.15)
                }
            }
            .frame(width: 16)

            Text("Finalizing transcript" + String(repeating: ".", count: dotCount))
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.primary.opacity(0.4))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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
