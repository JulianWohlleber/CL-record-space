import Foundation

final class OllamaService {
    private let baseURL = "http://localhost:11434"

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

        let url = URL(string: "\(baseURL)/api/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OllamaError.requestFailed
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let correctedText = json["response"] as? String else {
            throw OllamaError.invalidResponse
        }

        let trimmed = correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawText }

        // Safety check: if the original had ==markers== but correction lost them,
        // fall back to the raw transcript to avoid silently dropping highlights.
        let originalMarkerCount = rawText.components(separatedBy: "==").count
        let correctedMarkerCount = trimmed.components(separatedBy: "==").count
        if originalMarkerCount > 1 && correctedMarkerCount < originalMarkerCount {
            print("[OllamaService] Correction lost markers (\(originalMarkerCount) -> \(correctedMarkerCount)), using raw transcript")
            return rawText
        }

        return trimmed
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

        let url = URL(string: "\(baseURL)/api/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OllamaError.requestFailed
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["response"] as? String else {
            throw OllamaError.invalidResponse
        }

        // Clean up: lowercase, transliterate German umlauts, keep only
        // ASCII alphanumerics and hyphens.
        let cleaned = raw
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

        guard !cleaned.isEmpty else { throw OllamaError.invalidResponse }
        // Cap at 60 chars
        return String(cleaned.prefix(60))
    }

    /// Check if Ollama is running AND the configured model is available.
    func isAvailable() async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
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
}

enum OllamaError: LocalizedError {
    case requestFailed
    case invalidResponse
    case modelNotFound(String)

    var errorDescription: String? {
        switch self {
        case .requestFailed: return "Ollama request failed"
        case .invalidResponse: return "Invalid response from Ollama"
        case .modelNotFound(let name): return "Model '\(name)' not found in Ollama"
        }
    }
}
