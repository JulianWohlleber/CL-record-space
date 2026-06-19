import Foundation
import Combine

enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case apple = "apple"
    case whisper = "whisper"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .apple: return "Apple (fast)"
        case .whisper: return "Whisper (accurate)"
        }
    }
}

enum TranscriptionLanguage: String, CaseIterable, Identifiable {
    case auto = "auto"
    case english = "en-US"
    case german = "de-DE"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .english: return "EN"
        case .german: return "DE"
        }
    }

    var locale: Locale? {
        switch self {
        case .auto: return nil
        case .english: return Locale(identifier: "en-US")
        case .german: return Locale(identifier: "de-DE")
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private var scopedURL: URL?

    private enum Keys {
        static let baseFolderPath = "baseFolderPath"
        static let baseFolderBookmark = "baseFolderBookmark"
        static let language = "language"
        static let engine = "transcriptionEngine"
        static let ollamaModel = "ollamaModel"
    }

    @Published var isSetupComplete: Bool = false
    @Published var language: TranscriptionLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }
    @Published var engine: TranscriptionEngine {
        didSet { defaults.set(engine.rawValue, forKey: Keys.engine) }
    }
    @Published var ollamaModel: String {
        didSet { defaults.set(ollamaModel, forKey: Keys.ollamaModel) }
    }

    private init() {
        isSetupComplete = defaults.data(forKey: Keys.baseFolderBookmark) != nil
        let raw = defaults.string(forKey: Keys.language) ?? TranscriptionLanguage.auto.rawValue
        language = TranscriptionLanguage(rawValue: raw) ?? .auto
        let engineRaw = defaults.string(forKey: Keys.engine) ?? TranscriptionEngine.apple.rawValue
        engine = TranscriptionEngine(rawValue: engineRaw) ?? .apple
        ollamaModel = defaults.string(forKey: Keys.ollamaModel) ?? "mistral"
    }

    var baseFolderPath: String? {
        defaults.string(forKey: Keys.baseFolderPath)
    }

    private var baseFolderBookmark: Data? {
        defaults.data(forKey: Keys.baseFolderBookmark)
    }

    /// Save a folder URL from NSOpenPanel (which has implicit security scope).
    func saveBaseFolder(_ url: URL) {
        // Release the old security scope before switching to a new folder —
        // prevents leaking sandbox resource tokens.
        stopAccessingBaseFolder()

        defaults.set(url.path, forKey: Keys.baseFolderPath)
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmark, forKey: Keys.baseFolderBookmark)
            isSetupComplete = true
        } catch {
            print("Failed to create bookmark: \(error)")
        }
    }

    /// Resolve the security-scoped bookmark and start accessing. Call once, cache result.
    func accessBaseFolder() -> URL? {
        // Return cached URL if already accessing — but verify it still exists on disk
        if let scopedURL {
            if FileManager.default.fileExists(atPath: scopedURL.path) {
                return scopedURL
            }
            // Folder was moved/deleted — drop the cached reference and re-resolve
            scopedURL.stopAccessingSecurityScopedResource()
            self.scopedURL = nil
            print("[AppSettings] Cached vault URL no longer valid, re-resolving bookmark")
        }

        guard let bookmarkData = baseFolderBookmark else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            print("[AppSettings] Bookmark resolution failed — vault may have been moved")
            return nil
        }

        if isStale {
            // Re-save the bookmark from the resolved URL
            print("[AppSettings] Bookmark is stale, refreshing")
            saveBaseFolder(url)
        }

        guard url.startAccessingSecurityScopedResource() else {
            print("[AppSettings] Failed to start accessing security-scoped resource")
            return nil
        }

        // Final check: does the resolved path actually exist?
        guard FileManager.default.fileExists(atPath: url.path) else {
            url.stopAccessingSecurityScopedResource()
            print("[AppSettings] Resolved URL does not exist on disk: \(url.path)")
            return nil
        }

        scopedURL = url
        return url
    }

    func stopAccessingBaseFolder() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    var recordingsURL: URL? {
        accessBaseFolder()?.appendingPathComponent("recordings")
    }

    var transcriptsURL: URL? {
        accessBaseFolder()?.appendingPathComponent("transcripts")
    }

    var vaultRootURL: URL? {
        accessBaseFolder()
    }
}
