import SwiftUI

struct SetupView: View {
    @ObservedObject var viewModel: SetupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.3))

                Text("record_space")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.4))
                    .tracking(0.3)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ThinDivider()

            // Instruction
            Text("Choose a folder to store your recordings and transcripts.")
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.5))
                .lineSpacing(3)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

            // Folder picker
            Button(action: { viewModel.selectFolder() }) {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.3))

                    Text(viewModel.selectedFolderPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Select folder…")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(viewModel.selectedFolderPath != nil ? 0.6 : 0.3))

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.primary.opacity(0.15))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)

            // Continue
            if viewModel.selectedFolderPath != nil {
                Button(action: { viewModel.configureVault() }) {
                    Text("Continue")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.5))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            if let error = viewModel.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 9, weight: .medium))
                    Text(error)
                        .font(.system(size: 11))
                }
                .foregroundStyle(.red.opacity(0.6))
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            Spacer().frame(height: 14)
        }
        .frame(width: 280)
        .background(.ultraThickMaterial)
        .animation(.easeInOut(duration: 0.15), value: viewModel.selectedFolderPath)
    }
}
