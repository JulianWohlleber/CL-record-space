import SwiftUI

@MainActor
final class SetupViewModel: ObservableObject {
    @Published var selectedFolderURL: URL?
    @Published var errorMessage: String?

    var selectedFolderPath: String? {
        selectedFolderURL?.path
    }

    func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for your voice memo vault"
        panel.prompt = "Select"
        panel.level = .floating

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        selectedFolderURL = url
    }

    func configureVault() {
        guard let url = selectedFolderURL else {
            errorMessage = "Please select a folder first."
            return
        }

        let fm = FileManager.default

        do {
            try fm.createDirectory(
                at: url.appendingPathComponent("recordings"),
                withIntermediateDirectories: true
            )
            try fm.createDirectory(
                at: url.appendingPathComponent("transcripts"),
                withIntermediateDirectories: true
            )

            // Pass the actual NSOpenPanel URL so the security-scoped bookmark works
            AppSettings.shared.saveBaseFolder(url)
        } catch {
            errorMessage = "Failed to create folders: \(error.localizedDescription)"
        }
    }
}
