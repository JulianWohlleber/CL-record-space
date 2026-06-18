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

        // 1. Stop accepting new buffers
        pauseLock.withLock { $0 = true }

        // 2. Remove the tap (synchronous — no new callbacks scheduled after this)
        audioEngine?.inputNode.removeTap(onBus: 0)

        // 3. Stop the engine
        audioEngine?.stop()
        audioEngine = nil

        // 4. Wait for any in-flight writes to complete, then release the file.
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
