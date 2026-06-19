import Foundation
import WhisperKit
import NaturalLanguage

/// WhisperKit-based transcription service — significantly more accurate than
/// Apple's SFSpeechRecognizer, especially for German and technical English.
/// Uses CoreML + Neural Engine on Apple Silicon.
///
/// Thread safety: `whisperKit` and `currentModel` are guarded by `kitLock`
/// to prevent races between `loadModel` and concurrent `transcribe`/`detectLanguage`
/// calls. `@Published status` is always updated on the main thread.
final class WhisperTranscriptionService: ObservableObject {
    private var whisperKit: WhisperKit?
    private var currentModel: String?

    /// Serialises access to `whisperKit` and `currentModel` across async contexts.
    private let kitLock = NSLock()

    /// Whether the WhisperKit model has been downloaded and is ready to use.
    var isReady: Bool {
        kitLock.lock()
        defer { kitLock.unlock() }
        return whisperKit != nil
    }

    /// Human-readable status for UI (downloading, ready, error, etc.)
    @Published var status: ModelStatus = .notDownloaded

    enum ModelStatus: Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case ready
        case error(String)
    }

    /// Update status on the main thread to avoid @Published data races.
    private func setStatus(_ newStatus: ModelStatus) {
        if Thread.isMainThread {
            status = newStatus
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.status = newStatus
            }
        }
    }

    // MARK: - Model Management

    /// Recommended model for accuracy on Apple Silicon Macs.
    /// "large-v3-turbo" balances size (~626MB) and accuracy (2.2% WER).
    static let defaultModel = "large-v3-turbo"

    /// Initialize WhisperKit with the specified model. Downloads if needed.
    func loadModel(_ model: String = WhisperTranscriptionService.defaultModel) async {
        kitLock.lock()
        if whisperKit != nil && currentModel == model {
            kitLock.unlock()
            return
        }
        kitLock.unlock()

        setStatus(.downloading(progress: 0))
        do {
            let config = WhisperKitConfig(model: model)
            let kit = try await WhisperKit(config)
            kitLock.lock()
            whisperKit = kit
            currentModel = model
            kitLock.unlock()
            setStatus(.ready)
            print("[WhisperTranscription] Model '\(model)' loaded successfully")
        } catch {
            // Clear stale state on failure so isReady stays false
            kitLock.lock()
            whisperKit = nil
            currentModel = nil
            kitLock.unlock()
            setStatus(.error(error.localizedDescription))
            print("[WhisperTranscription] Failed to load model: \(error.localizedDescription)")
        }
    }

    // MARK: - Transcription

    /// Transcribe an audio file returning `[TimedSegment]` compatible with the
    /// existing marker algorithm.
    func transcribe(fileURL: URL, locale: Locale? = nil) async throws -> [TimedSegment] {
        kitLock.lock()
        guard let kit = whisperKit else {
            kitLock.unlock()
            throw WhisperTranscriptionError.modelNotLoaded
        }
        kitLock.unlock()

        var options = DecodingOptions(wordTimestamps: true)
        if let locale {
            // Map locale identifier to Whisper language code (e.g. "en-US" → "en", "de-DE" → "de")
            let langCode = String(locale.identifier.prefix(2))
            options.language = langCode
        }

        let results = try await kit.transcribe(audioPath: fileURL.path, decodeOptions: options)

        guard let result = results.first else {
            return []
        }

        return mapToTimedSegments(result.segments)
    }

    /// Detect the dominant language from the first portion of audio.
    func detectLanguage(fileURL: URL) async -> Locale {
        kitLock.lock()
        guard let kit = whisperKit else {
            kitLock.unlock()
            return Locale(identifier: "en-US")
        }
        kitLock.unlock()

        // Quick transcription with auto language detection
        let options = DecodingOptions(wordTimestamps: false)
        do {
            let results = try await kit.transcribe(audioPath: fileURL.path, decodeOptions: options)
            if let lang = results.first?.language, !lang.isEmpty {
                // WhisperKit returns ISO codes like "en", "de"
                switch lang {
                case "de": return Locale(identifier: "de-DE")
                case "en": return Locale(identifier: "en-US")
                default:   return Locale(identifier: "\(lang)")
                }
            }
        } catch {
            print("[WhisperTranscription] Language detection failed: \(error.localizedDescription)")
        }

        return Locale(identifier: "en-US")
    }

    // MARK: - Mapping to TimedWord / TimedSegment

    /// Map WhisperKit's `TranscriptionSegment` array into the app's
    /// `TimedSegment` format that `applyMarkers` consumes.
    private func mapToTimedSegments(_ segments: [TranscriptionSegment]) -> [TimedSegment] {
        return segments.compactMap { segment in
            // If word-level timings are available, use them
            if let wordTimings = segment.words, !wordTimings.isEmpty {
                let words = wordTimings.map { wt in
                    TimedWord(
                        text: wt.word.trimmingCharacters(in: .whitespaces),
                        timestamp: TimeInterval(wt.start),
                        duration: TimeInterval(wt.duration)
                    )
                }
                return TimedSegment(
                    words: words,
                    timestamp: TimeInterval(segment.start),
                    duration: TimeInterval(segment.duration)
                )
            }

            // Fallback: whole segment as a single "word" (less accurate for markers)
            let singleWord = TimedWord(
                text: segment.text.trimmingCharacters(in: .whitespaces),
                timestamp: TimeInterval(segment.start),
                duration: TimeInterval(segment.duration)
            )
            guard !singleWord.text.isEmpty else { return nil }
            return TimedSegment(
                words: [singleWord],
                timestamp: TimeInterval(segment.start),
                duration: TimeInterval(segment.duration)
            )
        }
    }
}

enum WhisperTranscriptionError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "WhisperKit model is not loaded. Please download a model in Settings."
        }
    }
}
