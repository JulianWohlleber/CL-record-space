# record_space

Voice recording for your menu bar. Mark moments, take notes, get a transcript — all saved to your Obsidian vault.

![record_space — recording popover, Obsidian output, and settings](assets/app-overview.png)

---

Record a meeting. Press `⌃⌥⌘M` when something matters — those words show up `==highlighted==` in the transcript. Type a quick note without leaving the call. When you stop, the audio, transcript, and note land in your vault as linked markdown files.

Transcription runs on-device via Apple Speech or WhisperKit (CoreML). An optional local LLM (Ollama) corrects misheard words and generates the note title.

## Install

**DMG** — download from [Releases](https://github.com/JulianWohlleber/CL-record-space/releases), drag to Applications.

**Source** — requires Xcode 16+, macOS 14+:

```
git clone https://github.com/JulianWohlleber/CL-record-space.git
cd CL-record-space
make install
```

## How it works

Start recording from the menu bar or with `⌃⌥⌘R`. The app creates a note file immediately — quicknotes appear in the markdown as you type them. When you stop, it exports the audio, transcribes it, applies marker highlights, optionally runs LLM correction, generates a title, and renames the note.

Three files per recording:

```
your-vault/
├── 2026-06-23-0910-meeting-topic.md      ← note (frontmatter, quicknotes, backlinks)
├── transcripts/
│   └── 2026-06-23-0910-transcript.md     ← timestamped transcript with ==highlights==
└── recordings/
    └── 2026-06-23-0910-recording.m4a     ← audio
```

### Hotkeys

| Shortcut | Action |
|----------|--------|
| `⌃⌥⌘R` | Start / Stop |
| `⌃⌥⌘P` | Pause / Resume |
| `⌃⌥⌘M` | Mark moment |
| `⌃⌥⌘N` | Quick note |

## Setup

On first launch, pick your Obsidian vault folder. The app creates `recordings/` and `transcripts/` subdirectories.

For LLM-powered transcript correction, install [Ollama](https://ollama.com) and `ollama pull mistral`. Detected automatically on `localhost:11434`.

## Technical details

Built with SwiftUI and AppKit. Recording uses AVAudioEngine with M4A export. Transcription runs through Apple's SFSpeechRecognizer (3-minute chunks with overlap deduplication) or WhisperKit's CoreML Whisper implementation. Markers map to per-word timestamps within a configurable window. Language detection supports English and German.

<details>
<summary>Project structure</summary>

```
VoiceMemoBar/
├── AppDelegate.swift                        Menu bar, popover, blink modes
├── Models/
│   └── AppSettings.swift                    Preferences, security-scoped bookmarks
├── Services/
│   ├── AudioRecorderService.swift           AVAudioEngine, pause/resume, M4A export
│   ├── TranscriptionService.swift           SFSpeechRecognizer, chunking, markers
│   ├── WhisperTranscriptionService.swift    WhisperKit CoreML engine
│   ├── OllamaService.swift                  LLM correction, title generation
│   ├── HotkeyService.swift                  Global hotkeys
│   └── PermissionsService.swift             Mic + speech permissions
├── ViewModels/
│   ├── RecorderViewModel.swift              State machine, file pipeline
│   └── SetupViewModel.swift                 First-launch flow
└── Views/
    ├── RecorderView.swift                   Recording popover
    ├── SettingsView.swift                   Settings window
    ├── SetupView.swift                      Vault selection
    └── TranscribingView.swift               Progress indicator
```

</details>

## Requirements

- macOS 14.0+
- Xcode 16+ (build from source)
- Optional: [Ollama](https://ollama.com)

## License

MIT
