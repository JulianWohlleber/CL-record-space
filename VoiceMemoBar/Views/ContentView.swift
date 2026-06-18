import SwiftUI

struct ContentView: View {
    @EnvironmentObject var recorderViewModel: RecorderViewModel
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var setupViewModel = SetupViewModel()

    var body: some View {
        Group {
            if !settings.isSetupComplete {
                SetupView(viewModel: setupViewModel)
            } else if recorderViewModel.state == .transcribing {
                TranscribingView()
            } else {
                RecorderView()
            }
        }
        .background(.ultraThickMaterial)
    }
}
