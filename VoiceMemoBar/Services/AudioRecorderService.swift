import AVFoundation

final class AudioRecorderService {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?
    private var _isPaused = false

    // Serialise file writes so they finish before we release the file
    private let fileQueue = DispatchQueue(label: "record_space.audio.file")

    var isRecording: Bool {
        audioEngine?.isRunning ?? false
    }

    func startRecording() throws {
        // Reset state
        _isPaused = false
        tempFileURL = nil
        audioFile = nil

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")
        let file = try AVAudioFile(forWriting: tempURL, settings: recordingFormat.settings)

        tempFileURL = tempURL
        audioFile = file

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // Capture pause state on this thread to avoid races
            if self._isPaused { return }
            // Serialise writes
            self.fileQueue.async {
                guard let file = self.audioFile else { return }
                do {
                    try file.write(from: buffer)
                } catch {
                    print("[AudioRecorderService] Write error: \(error.localizedDescription)")
                }
            }
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine
    }

    func pause() {
        _isPaused = true
    }

    func resume() {
        _isPaused = false
    }

    func stop() {
        // 1. Stop accepting new buffers
        _isPaused = true

        // 2. Remove the tap (synchronous — no new callbacks scheduled after this)
        audioEngine?.inputNode.removeTap(onBus: 0)

        // 3. Stop the engine
        audioEngine?.stop()
        audioEngine = nil

        // 4. Wait for any in-flight writes to complete (barrier on the file queue)
        fileQueue.sync { }

        // 5. Release the AVAudioFile so its destructor flushes the file header
        audioFile = nil

        // Verify file exists and has data
        if let url = tempFileURL {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int) ?? 0
            print("[AudioRecorderService] Recorded file: \(url.lastPathComponent), \(size) bytes")
        }
    }

    /// Convert recorded .caf to .m4a at destination. Returns true on success.
    func exportToM4A(destination: URL) async -> Bool {
        guard let tempURL = tempFileURL else {
            print("[AudioRecorderService] No temp file to export")
            return false
        }

        // Make sure source file exists and is non-empty
        let attrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path)
        let size = (attrs?[.size] as? Int) ?? 0
        guard size > 0 else {
            print("[AudioRecorderService] Source file empty, cannot export")
            return false
        }

        // Remove existing destination if any
        try? FileManager.default.removeItem(at: destination)

        let asset = AVURLAsset(url: tempURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            print("[AudioRecorderService] Could not create export session")
            return false
        }

        session.outputURL = destination
        session.outputFileType = .m4a
        await session.export()

        if session.status != .completed {
            print("[AudioRecorderService] Export failed: \(session.error?.localizedDescription ?? "unknown")")
            return false
        }
        return true
    }

    var recordedFileURL: URL? {
        tempFileURL
    }

    func cleanupTemp() {
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }
    }
}
