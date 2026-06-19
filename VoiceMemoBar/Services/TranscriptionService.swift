import Speech
import AVFoundation
import NaturalLanguage

struct TimedWord {
    let text: String
    let timestamp: TimeInterval  // seconds from start of recording
    let duration: TimeInterval
}

struct TimedSegment {
    let words: [TimedWord]
    let timestamp: TimeInterval  // seconds from start of recording (= first word)
    let duration: TimeInterval

    var text: String { words.map(\.text).joined(separator: " ") }
}

final class TranscriptionService {
    private let paragraphInterval: TimeInterval = 120.0  // 2 minutes
    private let chunkLength: TimeInterval = 180.0        // 3 minute chunks for long files
    private let chunkOverlap: TimeInterval = 5.0         // overlap between chunks to avoid splitting words at boundaries
    private let detectionSampleLength: TimeInterval = 25.0 // first N seconds used for language detection
    private let recognitionTimeout: TimeInterval = 120.0  // max wait per recognition request

    /// Domain-specific terms that bias recognition toward expected vocabulary
    /// (project names, technical jargon, proper nouns). Up to ~100 terms recommended.
    var contextualStrings: [String] = []

    // MARK: - Public API

    /// Transcribe an audio file with an explicit locale, splitting into chunks if long.
    func transcribe(fileURL: URL, locale: Locale) async throws -> [TimedSegment] {
        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration).seconds

        if duration <= chunkLength + 30 {
            let rawSegments = try await transcribeFile(url: fileURL, locale: locale, timeOffset: 0)
            return buildParagraphs(from: rawSegments)
        }

        var allRaw: [RawSegment] = []
        var offset: TimeInterval = 0

        while offset < duration {
            let end = min(offset + chunkLength, duration)
            do {
                let chunkURL = try await exportChunk(from: asset, start: offset, end: end)
                do {
                    let rawSegments = try await transcribeFile(url: chunkURL, locale: locale, timeOffset: offset)
                    allRaw.append(contentsOf: rawSegments)
                } catch {
                    print("[TranscriptionService] Chunk \(offset)-\(end) failed: \(error.localizedDescription)")
                }
                try? FileManager.default.removeItem(at: chunkURL)
            } catch {
                print("[TranscriptionService] Chunk export \(offset)-\(end) failed: \(error.localizedDescription)")
            }
            // Advance by chunkLength minus overlap so the next chunk's start
            // covers the tail of this chunk. Words in the overlap region will
            // be deduplicated below.
            let advance = end >= duration ? duration - offset : chunkLength - chunkOverlap
            offset += advance
        }

        // Deduplicate words in overlap regions: if two consecutive segments
        // have timestamps within 0.3s of each other and the same text,
        // drop the duplicate (the later one, which came from the next chunk).
        let deduped = deduplicateOverlapWords(allRaw)

        return buildParagraphs(from: deduped)
    }

    /// Detect the spoken language by sampling the first N seconds, transcribing with
    /// both en-US and de-DE recognizers in parallel, and using NLLanguageRecognizer
    /// to see which resulting text is more coherent in its claimed language.
    func detectLanguage(fileURL: URL) async -> Locale {
        let en = Locale(identifier: "en-US")
        let de = Locale(identifier: "de-DE")

        let asset = AVURLAsset(url: fileURL)
        let duration: TimeInterval
        do {
            duration = try await asset.load(.duration).seconds
        } catch {
            print("[TranscriptionService] Could not read duration for detection: \(error)")
            return en
        }

        let sampleEnd = min(detectionSampleLength, duration)
        guard sampleEnd > 1 else { return en }

        let sampleURL: URL
        do {
            sampleURL = try await exportChunk(from: asset, start: 0, end: sampleEnd)
        } catch {
            print("[TranscriptionService] Sample export failed, using fallback: \(error)")
            return en
        }
        defer { try? FileManager.default.removeItem(at: sampleURL) }

        // Transcribe sample with both recognizers in parallel
        async let enText: String = transcribeSampleText(url: sampleURL, locale: en)
        async let deText: String = transcribeSampleText(url: sampleURL, locale: de)
        let (textEn, textDe) = await (enText, deText)

        print("[TranscriptionService] EN sample: \"\(textEn.prefix(100))\"")
        print("[TranscriptionService] DE sample: \"\(textDe.prefix(100))\"")

        // Score each result: how confident is NLLanguageRecognizer that the text
        // is actually in the language its recognizer claims it is?
        let scoreEn = nlLanguageProbability(text: textEn, targetLanguage: .english)
        let scoreDe = nlLanguageProbability(text: textDe, targetLanguage: .german)

        print("[TranscriptionService] NL score — EN coherent: \(String(format: "%.3f", scoreEn)), DE coherent: \(String(format: "%.3f", scoreDe))")

        // If one recognizer produced no text at all, the other wins
        if textEn.isEmpty && !textDe.isEmpty { return de }
        if textDe.isEmpty && !textEn.isEmpty { return en }
        if textEn.isEmpty && textDe.isEmpty { return en }

        // If both scores are essentially zero, fall back to word-count heuristic
        // (the recognizer matching the real language will produce more words)
        if scoreEn < 0.05 && scoreDe < 0.05 {
            let enWords = textEn.split(whereSeparator: { $0.isWhitespace }).count
            let deWords = textDe.split(whereSeparator: { $0.isWhitespace }).count
            print("[TranscriptionService] Falling back to word count — EN: \(enWords), DE: \(deWords)")
            return deWords > enWords ? de : en
        }

        return scoreDe > scoreEn ? de : en
    }

    /// Transcribe a sample file and return the plain text. Empty on failure.
    private func transcribeSampleText(url: URL, locale: Locale) async -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            print("[TranscriptionService] Recognizer unavailable for \(locale.identifier)")
            return ""
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false

        do {
            let result: SFSpeechRecognitionResult = try await withCheckedThrowingContinuation { continuation in
                var hasResumed = false
                recognizer.recognitionTask(with: request) { result, error in
                    guard !hasResumed else { return }
                    if let error {
                        hasResumed = true
                        continuation.resume(throwing: error)
                        return
                    }
                    if let result, result.isFinal {
                        hasResumed = true
                        continuation.resume(returning: result)
                    }
                }
            }
            return result.bestTranscription.formattedString
        } catch {
            print("[TranscriptionService] Sample transcribe failed for \(locale.identifier): \(error.localizedDescription)")
            return ""
        }
    }

    /// Return how likely NLLanguageRecognizer thinks `text` is in `targetLanguage`.
    private func nlLanguageProbability(text: String, targetLanguage: NLLanguage) -> Double {
        guard !text.isEmpty else { return 0 }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
        return hypotheses[targetLanguage] ?? 0
    }

    // MARK: - File-based Transcription

    private typealias RawSegment = TimedWord

    private func transcribeFile(url: URL, locale: Locale, timeOffset: TimeInterval) async throws -> [RawSegment] {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
        }
        if #available(macOS 13, *) {
            request.addsPunctuation = true
        }

        // Wrap the recognition in a timeout to catch cases where the
        // recognizer hangs (Apple's on-device recognizer can stall on
        // long or unusual audio).
        let result: SFSpeechRecognitionResult = try await withThrowingTaskGroup(of: SFSpeechRecognitionResult.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    var hasResumed = false
                    let task = recognizer.recognitionTask(with: request) { result, error in
                        guard !hasResumed else { return }
                        if let error {
                            hasResumed = true
                            continuation.resume(throwing: error)
                            return
                        }
                        if let result, result.isFinal {
                            hasResumed = true
                            continuation.resume(returning: result)
                        }
                    }
                    // If the parent task is cancelled, cancel the recognition too
                    Task {
                        await withTaskCancellationHandler {
                            // nothing on start
                        } onCancel: {
                            task.cancel()
                        }
                    }
                }
            }

            group.addTask { [recognitionTimeout] in
                try await Task.sleep(nanoseconds: UInt64(recognitionTimeout * 1_000_000_000))
                throw TranscriptionError.recognitionTimedOut
            }

            // Return the first result (recognition or timeout)
            let first = try await group.next()!
            group.cancelAll()
            return first
        }

        return result.bestTranscription.segments.map { seg in
            RawSegment(
                text: seg.substring,
                timestamp: seg.timestamp + timeOffset,
                duration: seg.duration
            )
        }
    }

    /// Remove duplicate words that appear in chunk overlap regions.
    /// Two words are considered duplicates if they have the same text
    /// (case-insensitive) and timestamps within 0.5s of each other.
    private func deduplicateOverlapWords(_ segments: [RawSegment]) -> [RawSegment] {
        guard segments.count > 1 else { return segments }

        var result: [RawSegment] = [segments[0]]
        for i in 1..<segments.count {
            let current = segments[i]
            let previous = result.last!
            let timeDelta = abs(current.timestamp - previous.timestamp)
            let sameText = current.text.lowercased() == previous.text.lowercased()
            if sameText && timeDelta < 0.5 {
                // Skip duplicate from overlap region
                continue
            }
            result.append(current)
        }
        return result
    }

    // MARK: - Chunk Export

    private func exportChunk(from asset: AVURLAsset, start: TimeInterval, end: TimeInterval) async throws -> URL {
        let chunkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.chunkExportFailed
        }

        let startTime = CMTime(seconds: start, preferredTimescale: 44100)
        let endTime = CMTime(seconds: end, preferredTimescale: 44100)
        session.timeRange = CMTimeRange(start: startTime, end: endTime)
        session.outputURL = chunkURL
        session.outputFileType = .m4a

        await session.export()

        guard session.status == .completed else {
            // Clean up partial output
            try? FileManager.default.removeItem(at: chunkURL)
            throw TranscriptionError.chunkExportFailed
        }

        return chunkURL
    }

    // MARK: - Paragraph Building (2-minute blocks)

    private func buildParagraphs(from segments: [RawSegment]) -> [TimedSegment] {
        guard !segments.isEmpty else { return [] }

        var result: [TimedSegment] = []
        var currentWords: [TimedWord] = []
        var paragraphStart: TimeInterval = 0
        var paragraphEnd: TimeInterval = 0

        for segment in segments {
            let segTime = segment.timestamp

            if !currentWords.isEmpty {
                let elapsed = segTime - paragraphStart
                if elapsed >= paragraphInterval {
                    result.append(TimedSegment(
                        words: currentWords,
                        timestamp: paragraphStart,
                        duration: paragraphEnd - paragraphStart
                    ))
                    currentWords = []
                }
            }

            if currentWords.isEmpty {
                paragraphStart = segTime
            }

            currentWords.append(segment)
            paragraphEnd = segTime + segment.duration
        }

        if !currentWords.isEmpty {
            result.append(TimedSegment(
                words: currentWords,
                timestamp: paragraphStart,
                duration: paragraphEnd - paragraphStart
            ))
        }

        return result
    }

    // MARK: - Output Formatting

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "[\(String(format: "%02d:%02d", mins, secs))]"
    }

    /// Build final transcript with [MM:SS] timestamps and ==highlight== around
    /// words whose timestamps fall within ±10s of any marker.
    static func applyMarkers(to segments: [TimedSegment], markers: [TimeInterval]) -> String {
        let highlightRanges: [(start: TimeInterval, end: TimeInterval)] =
            markers.map { (start: max(0, $0 - 10), end: $0 + 10) }

        func isMarked(_ time: TimeInterval) -> Bool {
            highlightRanges.contains { time >= $0.start && time <= $0.end }
        }

        var paragraphs: [String] = []
        for segment in segments {
            let timestamp = formatTimestamp(segment.timestamp)

            if highlightRanges.isEmpty {
                paragraphs.append("\(timestamp) \(segment.text)")
                continue
            }

            // Walk through words and emit runs of marked / unmarked text.
            var pieces: [String] = []
            var buffer: [String] = []
            var bufferMarked = false

            func flush() {
                guard !buffer.isEmpty else { return }
                let joined = buffer.joined(separator: " ")
                pieces.append(bufferMarked ? "==\(joined)==" : joined)
                buffer = []
            }

            for word in segment.words {
                let marked = isMarked(word.timestamp)
                if marked != bufferMarked {
                    flush()
                    bufferMarked = marked
                }
                buffer.append(word.text)
            }
            flush()

            paragraphs.append("\(timestamp) \(pieces.joined(separator: " "))")
        }

        return paragraphs.joined(separator: "\n\n")
    }
}

enum TranscriptionError: LocalizedError {
    case recognizerUnavailable
    case chunkExportFailed
    case recognitionTimedOut

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognizer is not available."
        case .chunkExportFailed:
            return "Failed to export audio chunk for transcription."
        case .recognitionTimedOut:
            return "Speech recognition timed out."
        }
    }
}
