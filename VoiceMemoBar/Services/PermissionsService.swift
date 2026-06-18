import AVFoundation
import Speech

final class PermissionsService {
    static let shared = PermissionsService()

    func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func requestSpeechRecognitionAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    var hasMicrophoneAccess: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    var hasSpeechAccess: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    func requestAllPermissions() async -> Bool {
        let mic = await requestMicrophoneAccess()
        let speech = await requestSpeechRecognitionAccess()
        return mic && speech
    }
}
