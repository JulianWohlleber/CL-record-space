import Foundation

final class OllamaService {
    private let baseURL = "http://localhost:11434"

    /// Dedicated URLSession with ephemeral configuration — no persistent
    /// caches or cookies for local LLM requests. Connection pooling is
    /// handled automatically by URLSession; httpMaximumConnectionsPerHost
    /// is capped at 2 since all requests go to the same localhost endpoint.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForResource = 180  // hard cap for long LLM generation
        config.waitsForConnectivity = false       // fail fast if Ollama isn't running
        return URLSession(configuration: config)
    }()

    /// Resolved model name — reads from AppSettings on each call so changes
    /// take effect immediately without restarting.
    private var model: String {
        // AppSettings is @MainActor, but we only read a UserDefaults-backed
        // string — safe to access the raw default directly here.
        UserDefaults.standard.string(forKey: "ollamaModel") ?? "mistral"
    }

    func correctTranscript(_ rawText: String) async throws -> String {
        let prompt = """
        Fix any speech-to-text errors in the following transcript. \
        Correct misheard words, fix grammar, and improve punctuation. \
        Keep the original meaning and structure. \
        Only return the corrected text, nothing else.

        CRITICAL RULES:
        - Every ==highlighted section== MUST appear in your output exactly as-is. \
        Do NOT remove, rephrase, or merge any ==...== markers. You may fix words \
        inside the markers but the == delimiters must stay.
        - Preserve [MM:SS] timestamps at the start of paragraphs exactly as-is.
        - Preserve paragraph breaks exactly as they are.
        - Do NOT add commentary, headers, or preamble — output only the corrected transcript.

        Transcript:
        \(rawText)
        """

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false
        ]

        let data = try await ollamaRequest(body: body, timeout: 120)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let correctedText = json["response"] as? String else {
            throw OllamaError.invalidResponse
        }

        let trimmed = correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawText }

        // Safety check: count actual "==" delimiters (not split components).
        // Each marker pair uses exactly two "==" tokens (open + close), so the
        // corrected text must have at least as many as the original.
        let originalMarkerCount = countOccurrences(of: "==", in: rawText)
        let correctedMarkerCount = countOccurrences(of: "==", in: trimmed)
        if originalMarkerCount > 0 && correctedMarkerCount < originalMarkerCount {
            print("[OllamaService] Correction lost markers (\(originalMarkerCount) -> \(correctedMarkerCount)), using raw transcript")
            return rawText
        }

        return trimmed
    }

    /// Count non-overlapping occurrences of a substring.
    private func countOccurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }

    /// Generate a short kebab-case title from transcript text.
    /// If `locale` is German, the title will be in German.
    func generateTitle(from transcript: String, locale: Locale = Locale(identifier: "en-US")) async throws -> String {
        // Send first ~1500 chars to keep the prompt small
        let snippet = String(transcript.prefix(1500))
        let isGerman = locale.identifier.hasPrefix("de")
        let prompt: String
        if isGerman {
            prompt = """
            Lies dieses Meeting-Transkript und erzeuge einen kurzen Titel (2-5 Woerter) \
            auf Deutsch, der das Hauptthema wiedergibt. Gib AUSSCHLIESSLICH den Titel \
            in kebab-case zurueck (Kleinbuchstaben, Bindestriche statt Leerzeichen, \
            ohne Umlaute — schreibe ae, oe, ue, ss). Keine Anfuehrungszeichen, \
            keine Erklaerung. \
            Beispiele: "quartalsbudget-besprechung", "onboarding-flow-redesign", "api-migrationsplan"

            Transkript:
            \(snippet)
            """
        } else {
            prompt = """
            Read this meeting transcript and generate a short title (2-5 words) \
            in English that captures the main topic. Return ONLY the title in kebab-case \
            (lowercase, hyphens instead of spaces). No quotes, no explanation. \
            Examples: "quarterly-budget-review", "onboarding-flow-redesign", "api-migration-plan"

            Transcript:
            \(snippet)
            """
        }

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false
        ]

        let data = try await ollamaRequest(body: body, timeout: 30)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["response"] as? String else {
            throw OllamaError.invalidResponse
        }

        // LLMs sometimes return multi-line output with explanations.
        // Take only the first non-empty line.
        let firstLine = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? raw

        // Clean up: lowercase, transliterate German umlauts, keep only
        // ASCII alphanumerics and hyphens.
        let cleaned = firstLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\u{00E4}", with: "ae")
            .replacingOccurrences(of: "\u{00F6}", with: "oe")
            .replacingOccurrences(of: "\u{00FC}", with: "ue")
            .replacingOccurrences(of: "\u{00DF}", with: "ss")
            .replacingOccurrences(of: " ", with: "-")
            .filter { ($0.isASCII && $0.isLetter) || $0.isNumber || $0 == "-" }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            // Collapse consecutive hyphens (e.g. from stripped punctuation)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)

        guard !cleaned.isEmpty else { throw OllamaError.invalidResponse }

        // Security: the .filter above already strips "/" and "." (only ASCII
        // letters, digits, and "-" survive), but as defense-in-depth we
        // explicitly reject path-traversal patterns and control characters.
        // This guards against future refactors that might loosen the filter.
        let sanitized = cleaned
            .replacingOccurrences(of: "..", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "\\", with: "")
            .filter { !$0.isNewline && $0.asciiValue.map({ $0 >= 32 }) ?? false }

        guard !sanitized.isEmpty else { throw OllamaError.invalidResponse }

        // Cap at 60 chars — trim on a hyphen boundary if possible so we don't
        // produce a truncated word.
        if sanitized.count <= 60 { return sanitized }
        let truncated = String(sanitized.prefix(60))
        if let lastHyphen = truncated.lastIndex(of: "-") {
            return String(truncated[truncated.startIndex..<lastHyphen])
        }
        return truncated
    }

    /// Check if Ollama is running AND the configured model is available.
    func isAvailable() async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5  // Quick check — don't wait long
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }

            // Verify the configured model is actually pulled
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else {
                return false
            }

            let targetModel = model
            let modelExists = models.contains { entry in
                guard let name = entry["name"] as? String else { return false }
                // Ollama model names may include a tag suffix like ":latest"
                return name == targetModel || name.hasPrefix("\(targetModel):")
            }

            if !modelExists {
                print("[OllamaService] Model '\(targetModel)' not found in Ollama. Available: \(models.compactMap { $0["name"] as? String })")
            }

            return modelExists
        } catch {
            return false
        }
    }

    // MARK: - Shared Request

    /// Send a request to Ollama's /api/generate endpoint with proper error
    /// discrimination (connection refused vs timeout vs model not loaded).
    private func ollamaRequest(body: [String: Any], timeout: TimeInterval) async throws -> Data {
        let url = URL(string: "\(baseURL)/api/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut:
                throw OllamaError.timeout
            case .cannotConnectToHost, .cannotFindHost:
                throw OllamaError.connectionRefused
            default:
                throw OllamaError.networkError(urlError.localizedDescription)
            }
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.requestFailed
        }

        // Ollama returns 404 when the model isn't pulled
        if httpResponse.statusCode == 404 {
            throw OllamaError.modelNotFound(model)
        }

        guard httpResponse.statusCode == 200 else {
            throw OllamaError.requestFailed
        }

        return data
    }

    deinit {
        session.invalidateAndCancel()
    }
}

enum OllamaError: LocalizedError {
    case requestFailed
    case invalidResponse
    case modelNotFound(String)
    case timeout
    case connectionRefused
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .requestFailed: return "Ollama request failed."
        case .invalidResponse: return "Invalid response from Ollama."
        case .modelNotFound(let name): return "Model '\(name)' not found in Ollama. Run: ollama pull \(name)"
        case .timeout: return "Ollama request timed out — the model may still be loading."
        case .connectionRefused: return "Cannot connect to Ollama. Is it running? (ollama serve)"
        case .networkError(let msg): return "Network error: \(msg)"
        }
    }
}
