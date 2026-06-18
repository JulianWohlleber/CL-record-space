import Foundation

final class OllamaService {
    private let baseURL = "http://localhost:11434"
    private let model = "mistral"

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
            print("[OllamaService] Correction lost markers (\(originalMarkerCount) → \(correctedMarkerCount)), using raw transcript")
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
            Lies dieses Meeting-Transkript und erzeuge einen kurzen Titel (2–5 Wörter) \
            auf Deutsch, der das Hauptthema wiedergibt. Gib AUSSCHLIESSLICH den Titel \
            in kebab-case zurück (Kleinbuchstaben, Bindestriche statt Leerzeichen, \
            ohne Umlaute — schreibe ä→ae, ö→oe, ü→ue, ß→ss). Keine Anführungszeichen, \
            keine Erklärung. \
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
            .replacingOccurrences(of: "ä", with: "ae")
            .replacingOccurrences(of: "ö", with: "oe")
            .replacingOccurrences(of: "ü", with: "ue")
            .replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: " ", with: "-")
            .filter { ($0.isASCII && $0.isLetter) || $0.isNumber || $0 == "-" }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        guard !cleaned.isEmpty else { throw OllamaError.invalidResponse }
        // Cap at 60 chars
        return String(cleaned.prefix(60))
    }

    func isAvailable() async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

enum OllamaError: LocalizedError {
    case requestFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .requestFailed: return "Ollama request failed"
        case .invalidResponse: return "Invalid response from Ollama"
        }
    }
}
