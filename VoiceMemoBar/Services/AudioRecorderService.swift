import AVFoundation
import os

final class AudioRecorderService {
    private var audioEngine: AVAudioEngine?
    private var tempFileURL: URL?

    // All access to _audioFile must go through fileQueue.
    private var _audioFile: AVAudioFile?

    // Lock-protected pause flag — read on the real-time audio thread,
    // written from the main thread. os_unfair_lock is the lightest
    // correct primitive for this (no priority inversion, no syscall
    // in the uncontended case).
    private let pauseLock = OSAllocatedUnfairLock(initialState: false)

    // Serialise file writes so they finish before we release the file
    private let fileQueue = DispatchQueue(label: "record_space.audio.file")

    /// Callback for reporting current temp file size (bytes). Called on main queue.
    var onFileSizeUpdate: ((Int64) -> Void)?
    private var fileSizeTimer: Timer?

    /// Called on main queue when the audio engine stops unexpectedly
    /// (e.g. microphone disconnected). The recording is preserved up to
    /// the point of disconnection.
    var onUnexpectedStop: (() -> Void)?

    /// Observer for audio engine configuration changes (mic disconnect, etc.)
    private var configObserver: NSObjectProtocol?

    var isRecording: Bool {
        audioEngine?.isRunning ?? false
    }

    func startRecording() throws {
        // Reset state
        pauseLock.withLock { $0 = false }
        tempFileURL = nil
        fileQueue.sync { _audioFile = nil }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")
        let file = try AVAudioFile(forWriting: tempURL, settings: recordingFormat.settings)

        tempFileURL = tempURL
        fileQueue.sync { _audioFile = file }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Read pause flag safely via the lock
            let paused = self.pauseLock.withLock { $0 }
            if paused { return }

            // Reject zero-length buffers (can happen during device transitions)
            guard buffer.frameLength > 0 else { return }

            // Copy buffer data synchronously on the audio thread before
            // dispatching — the engine reuses the buffer's internal storage,
            // so the original data may be overwritten by the time the async
            // block executes.
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            let channelCount = Int(buffer.format.channelCount)
            for ch in 0..<channelCount {
                if let src = buffer.floatChannelData?[ch],
                   let dst = copy.floatChannelData?[ch] {
                    memcpy(dst, src, Int(buffer.frameLength) * MemoryLayout<Float>.size)
                }
            }

            // Serialise writes — now using the safe copy
            self.fileQueue.async { [weak self] in
                guard let self else { return }
                guard let file = self._audioFile else { return }
                do {
                    try file.write(from: copy)
                } catch {
                    print("[AudioRecorderService] Write error: \(error.localizedDescription)")
                }
            }
        }

        // Observe audio engine configuration changes (e.g. microphone disconnected).
        // When the input device is removed, AVAudioEngine stops automatically.
        // We detect this and notify the caller so the UI can react gracefully.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            // The engine has been reset — it is no longer running.
            // Drain pending writes and notify the caller.
            if !(self.audioEngine?.isRunning ?? false) {
                print("[AudioRecorderService] Audio engine stopped (device change)")
                self.handleUnexpectedStop()
            }
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine

        // Poll temp file size every 5 seconds for the UI indicator
        startFileSizePolling()
    }

    private func startFileSizePolling() {
        fileSizeTimer?.invalidate()
        fileSizeTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self, let url = self.tempFileURL else { return }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int64) ?? 0
            DispatchQueue.main.async { [weak self] in
                self?.onFileSizeUpdate?(size)
            }
        }
    }

    private func stopFileSizePolling() {
        fileSizeTimer?.invalidate()
        fileSizeTimer = nil
    }

    func pause() {
        pauseLock.withLock { $0 = true }
    }

    func resume() {
        pauseLock.withLock { $0 = false }
    }

    func stop() {
        stopFileSizePolling()
        removeConfigObserver()

        // 1. Stop accepting new buffers
        pauseLock.withLock { $0 = true }

        // 2. Remove the tap (synchronous — no new callbacks scheduled after this)
        if let engine = audioEngine, engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        } else {
            // Engine already stopped (e.g. device disconnected) — still remove tap
            // to clean up. removeTap is safe even if no tap is installed.
            audioEngine?.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil

        // 3. Wait for any in-flight writes to complete, then release the file.
        //    Setting _audioFile = nil inside the sync block ensures no concurrent
        //    read from the tap closure can race with this assignment.
        fileQueue.sync {
            _audioFile = nil
        }

        // Verify file exists and has data
        if let url = tempFileURL {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int) ?? 0
            print("[AudioRecorderService] Recorded file: \(url.lastPathComponent), \(size) bytes")
        }
    }

    /// Handle the audio engine stopping unexpectedly (mic disconnected, etc.).
    /// Drains in-flight writes and notifies the caller on the main queue.
    private func handleUnexpectedStop() {
        stopFileSizePolling()
        removeConfigObserver()
        pauseLock.withLock { $0 = true }

        // The engine already stopped — remove the tap to prevent dangling references
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        // Drain any in-flight writes so the file is complete
        fileQueue.sync {
            _audioFile = nil
        }

        if let url = tempFileURL {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int) ?? 0
            print("[AudioRecorderService] Unexpected stop — preserved \(size) bytes in \(url.lastPathComponent)")
        }

        DispatchQueue.main.async { [weak self] in
            self?.onUnexpectedStop?()
        }
    }

    private func removeConfigObserver() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
    }

    /// Convert recorded .caf to .m4a at destination. Returns true on success.
    func exportToM4A(destination: URL) async -> Bool {
        // Ensure no in-flight writes are pending before reading the file
        fileQueue.sync {}

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

        let asset = AVURLAsset(url: tempURL)

        // Validate the source file has readable audio tracks — catches
        // corrupted or truncated files before the export session tries to read.
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            print("[AudioRecorderService] Source file unreadable: \(error.localizedDescription)")
            return false
        }
        guard !tracks.isEmpty else {
            print("[AudioRecorderService] Source file has no audio tracks")
            return false
        }

        // Check duration is positive (zero-duration files crash the exporter)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            print("[AudioRecorderService] Cannot read source duration: \(error.localizedDescription)")
            return false
        }
        guard duration.seconds > 0 else {
            print("[AudioRecorderService] Source file has zero duration")
            return false
        }

        // Remove existing destination if any
        try? FileManager.default.removeItem(at: destination)

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            print("[AudioRecorderService] Could not create export session")
            return false
        }

        session.outputURL = destination
        session.outputFileType = .m4a
        await session.export()

        if session.status != .completed {
            print("[AudioRecorderService] Export failed: \(session.error?.localizedDescription ?? "unknown")")
            // Clean up partial output
            try? FileManager.default.removeItem(at: destination)
            return false
        }
        return true
    }

    var recordedFileURL: URL? {
        tempFileURL
    }

    func cleanupTemp() {
        // Ensure no in-flight writes are pending before deleting
        fileQueue.sync {}
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }
    }

    deinit {
        // Full cleanup: stop polling, remove observer, stop engine, drain writes
        fileSizeTimer?.invalidate()
        fileSizeTimer = nil
        removeConfigObserver()
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }
        audioEngine = nil
        fileQueue.sync { _audioFile = nil }
    }
}

enum AudioRecorderError: LocalizedError {
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No audio input device available."
        }
    }
}
