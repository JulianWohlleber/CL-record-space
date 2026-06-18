import SwiftUI
import Combine

enum RecordingState: Equatable {
    case idle
    case recording
    case paused
    case transcribing
}

@MainActor
final class RecorderViewModel: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var elapsedTime: TimeInterval = 0
    @Published var errorMessage: String?
    @Published var shouldFlashMarker = false
    @Published var shouldFlashNoteDropped = false
    /// True for 10s after a marker is placed — drives the filled bookmark icon in the panel.
    @Published var markerActive = false
    @Published var quickNoteRequested = false
    @Published var quickNoteText = ""
    @Published var quickNotes: [(time: String, text: String)] = []
    @Published private(set) var markers: [TimeInterval] = []

    private let audioService = AudioRecorderService()
    private let transcriptionService = TranscriptionService()
    private let whisperService = WhisperTranscriptionService()
    private let ollamaService = OllamaService()
    private var timer: Timer?
    private var markerActiveTimer: Timer?
    private var recordingStartDate: Date?

    /// The date string for the current recording session — set on start, used
    /// to locate note/transcript files throughout the session.
    private var currentDateString: String?
    /// URL of the note file created at recording start (with placeholder slug "note").
    private var currentNoteURL: URL?

    func toggleRecording() {
        switch state {
        case .idle:
            startRecording()
        case .recording, .paused:
            stopRecording()
        case .transcribing:
            break
        }
    }

    func togglePause() {
        if state == .recording {
            pauseRecording()
        } else if state == .paused {
            resumeRecording()
        }
    }

    func startRecording() {
        guard AppSettings.shared.isSetupComplete else {
            errorMessage = "Please set up your vault folder first."
            return
        }

        Task {
            let hasPermissions = await PermissionsService.shared.requestAllPermissions()
            guard hasPermissions else {
                errorMessage = "Microphone and speech recognition permissions are required."
                return
            }

            guard AppSettings.shared.recordingsURL != nil else {
                errorMessage = "Vault folder not accessible."
                return
            }

            let startDate = Date()
            recordingStartDate = startDate

            do {
                try audioService.startRecording()
                state = .recording
                elapsedTime = 0
                markers = []
                quickNotes = []
                errorMessage = nil
                startTimer()

                // Create note + transcript files immediately so they're visible
                // in the vault and links are wired from the start.
                let dateString = DateFormatter.filenameFormatter.string(from: startDate)
                currentDateString = dateString
                createInitialNoteFile(dateString: dateString, startDate: startDate)
                createInitialTranscriptFile(dateString: dateString)
            } catch {
                errorMessage = "Failed to start recording: \(error.localizedDescription)"
            }
        }
    }

    func pauseRecording() {
        audioService.pause()
        state = .paused
        stopTimer()
    }

    func resumeRecording() {
        audioService.resume()
        state = .recording
        startTimer()
    }

    func stopRecording() {
        audioService.stop()
        stopTimer()
        state = .transcribing

        guard let startDate = recordingStartDate else {
            state = .idle
            return
        }

        let savedMarkers = markers
        let savedQuickNotes = quickNotes

        Task {
            await processRecording(
                startDate: startDate,
                markers: savedMarkers,
                quickNotes: savedQuickNotes
            )
        }
    }

    func placeMarker() {
        guard state == .recording || state == .paused else { return }
        markers.append(elapsedTime)
        shouldFlashMarker = true

        // Show filled bookmark in the panel for 10s
        markerActive = true
        markerActiveTimer?.invalidate()
        markerActiveTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.markerActive = false }
        }
    }

    func sendQuickNote() {
        let text = quickNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let time = DateFormatter.quickNoteTimeFormatter.string(from: Date())
        quickNotes.append((time: time, text: text))
        quickNoteText = ""
        quickNoteRequested = false
        shouldFlashNoteDropped = true

        // Append the quicknote to the on-disk note file immediately
        appendQuickNoteToFile(time: time, text: text)
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedTime += 1
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Early File Creation (at recording start)

    /// Create the note file with skeleton content. Uses placeholder slug "note"
    /// which will be renamed after title generation.
    private func createInitialNoteFile(dateString: String, startDate: Date) {
        guard let vaultURL = AppSettings.shared.vaultRootURL else { return }
        let filename = "\(dateString)-note.md"
        let fileURL = vaultURL.appendingPathComponent(filename)
        currentNoteURL = fileURL

        let created = DateFormatter.createdFormatter.string(from: startDate)
        let transcriptLink = "[Transcript](transcripts/\(dateString)-transcript.md)"

        var lines: [String] = []
        lines.append("---")
        lines.append("Created: \(created)")
        lines.append("---")
        lines.append(transcriptLink)
        lines.append("")
        lines.append("## Notes")
        lines.append("")
        lines.append("## Quicknotes")
        lines.append("")
        lines.append("## Summary")
        lines.append("#insights")
        lines.append("")
        lines.append("")
        lines.append("#actions")
        lines.append("- [ ]")
        lines.append("")
        lines.append("#Notes")

        let content = lines.joined(separator: "\n") + "\n"
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        print("[RecorderViewModel] Created initial note: \(filename)")
    }

    /// Create the transcript file with header + audio embed, but no transcript
    /// content yet. The transcript will be filled in after transcription.
    private func createInitialTranscriptFile(dateString: String) {
        guard let transcriptsURL = AppSettings.shared.transcriptsURL else { return }
        let filename = "\(dateString)-transcript.md"
        let fileURL = transcriptsURL.appendingPathComponent(filename)
        let audioEmbed = "![[\(dateString)-recording.m4a]]"
        let content = "#transcript\n\n\(audioEmbed)\n\n"
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        print("[RecorderViewModel] Created initial transcript: \(filename)")
    }

    // MARK: - Live Quicknote Append

    /// Append a single quicknote line to the existing note file on disk,
    /// inserting it right before the empty line after "## Quicknotes".
    private func appendQuickNoteToFile(time: String, text: String) {
        guard let noteURL = currentNoteURL else { return }
        guard let existing = try? String(contentsOf: noteURL, encoding: .utf8) else { return }

        let noteLine = "\(time) \(text)"

        // Strategy: find "## Quicknotes" and insert the new line after any
        // existing quicknotes (before the next "##" section or blank-line gap).
        var lines = existing.components(separatedBy: "\n")
        if let qnIndex = lines.firstIndex(where: { $0.hasPrefix("## Quicknotes") }) {
            // Find where to insert: after the last non-empty, non-heading line
            // following "## Quicknotes".
            var insertAt = qnIndex + 1
            while insertAt < lines.count {
                let line = lines[insertAt]
                if line.isEmpty || line.hasPrefix("## ") { break }
                insertAt += 1
            }
            lines.insert(noteLine, at: insertAt)
        } else {
            // Fallback: just append
            lines.append(noteLine)
        }

        let updated = lines.joined(separator: "\n")
        try? updated.write(to: noteURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Processing Pipeline (runs after recording stops)

    private func processRecording(
        startDate: Date,
        markers: [TimeInterval],
        quickNotes: [(time: String, text: String)]
    ) async {
        let dateString = currentDateString ?? DateFormatter.filenameFormatter.string(from: startDate)

        // Step 1: Export audio to .m4a
        var m4aURL: URL?
        if let recordingsURL = AppSettings.shared.recordingsURL {
            let dest = recordingsURL.appendingPathComponent("\(dateString)-recording.m4a")
            let exported = await audioService.exportToM4A(destination: dest)
            if exported {
                m4aURL = dest
            } else {
                print("[RecorderViewModel] M4A export failed")
            }
        }

        // Step 2: Resolve the locale (auto-detect or user preference)
        var segments: [TimedSegment] = []
        var usedLocale = Locale(identifier: "en-US")

        if let audioURL = m4aURL {
            let languagePref = AppSettings.shared.language
            let enginePref = AppSettings.shared.engine

            let locale: Locale
            if let explicit = languagePref.locale {
                locale = explicit
                print("[RecorderViewModel] Using explicit locale: \(locale.identifier)")
            } else if enginePref == .whisper && whisperService.isReady {
                locale = await whisperService.detectLanguage(fileURL: audioURL)
                print("[RecorderViewModel] Whisper auto-detected locale: \(locale.identifier)")
            } else {
                locale = await transcriptionService.detectLanguage(fileURL: audioURL)
                print("[RecorderViewModel] Apple auto-detected locale: \(locale.identifier)")
            }
            usedLocale = locale

            do {
                if enginePref == .whisper && whisperService.isReady {
                    print("[RecorderViewModel] Transcribing with WhisperKit")
                    segments = try await whisperService.transcribe(fileURL: audioURL, locale: locale)
                } else {
                    print("[RecorderViewModel] Transcribing with Apple SFSpeechRecognizer")
                    segments = try await transcriptionService.transcribe(fileURL: audioURL, locale: locale)
                }
            } catch {
                print("[RecorderViewModel] Transcription failed: \(error.localizedDescription)")
            }
        }

        // Cleanup temp .caf
        audioService.cleanupTemp()

        // Step 3: Build transcript with timestamps and marker highlights
        var transcript: String
        if segments.isEmpty {
            transcript = "[No speech detected]"
        } else {
            transcript = TranscriptionService.applyMarkers(to: segments, markers: markers)

            // Step 3b: LLM correction — fix misheard words while preserving ==markers==
            if await ollamaService.isAvailable() {
                if let corrected = try? await ollamaService.correctTranscript(transcript) {
                    transcript = corrected
                }
            }
        }

        // Step 4: Fill the transcript into the existing transcript file
        updateTranscriptFile(dateString: dateString, transcript: transcript)

        // Step 5: Generate title and rename note file
        var titleSlug = "note"
        if !segments.isEmpty, await ollamaService.isAvailable() {
            if let generated = try? await ollamaService.generateTitle(from: transcript, locale: usedLocale) {
                titleSlug = generated
            }
        }
        if titleSlug != "note" {
            renameNoteFile(dateString: dateString, newSlug: titleSlug)
        }

        state = .idle
        recordingStartDate = nil
        currentDateString = nil
        currentNoteURL = nil
    }

    /// Update the existing transcript file with actual transcript content.
    /// The file already has the header and audio embed from createInitialTranscriptFile.
    private func updateTranscriptFile(dateString: String, transcript: String) {
        guard let transcriptsURL = AppSettings.shared.transcriptsURL else { return }
        let filename = "\(dateString)-transcript.md"
        let fileURL = transcriptsURL.appendingPathComponent(filename)
        let audioEmbed = "![[\(dateString)-recording.m4a]]"
        let content = "#transcript\n\n\(audioEmbed)\n\n\(transcript)\n"
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        print("[RecorderViewModel] Updated transcript with content: \(filename)")
    }

    /// Rename the note file from the placeholder "note" slug to the generated title.
    /// Obsidian handles file renames gracefully.
    private func renameNoteFile(dateString: String, newSlug: String) {
        guard let vaultURL = AppSettings.shared.vaultRootURL else { return }
        guard let currentURL = currentNoteURL else { return }

        let newFilename = "\(dateString)-\(newSlug).md"
        let newURL = vaultURL.appendingPathComponent(newFilename)

        do {
            try FileManager.default.moveItem(at: currentURL, to: newURL)
            currentNoteURL = newURL
            print("[RecorderViewModel] Renamed note: \(currentURL.lastPathComponent) → \(newFilename)")
        } catch {
            print("[RecorderViewModel] Failed to rename note: \(error.localizedDescription)")
        }
    }

    var formattedTime: String {
        let minutes = Int(elapsedTime) / 60
        let seconds = Int(elapsedTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
