# record_space

A macOS menu bar app for voice recording with live transcription, marker highlights, and Obsidian integration.

Record meetings, lectures, or thoughts. Mark important moments with a hotkey. Get a timestamped, highlighted transcript saved directly to your Obsidian vault.

## Features

- **Menu bar recording** — start/stop from the menu bar or global hotkeys
- **Marker highlights** — press a hotkey to mark important moments; marked words appear as `==highlighted==` in the transcript
- **Live quicknotes** — type short notes during recording; they appear immediately in the markdown file
- **Dual transcription engines** — Apple Speech (fast) or WhisperKit/CoreML (accurate)
- **Auto language detection** — English and German, or set manually
- **LLM-powered corrections** — optional Ollama integration for transcript cleanup and auto-titling
- **Obsidian-native output** — markdown notes with frontmatter, transcript backlinks, and embedded audio

## Install

### From DMG (recommended)

1. Download `record_space.dmg` from [Releases](https://github.com/JulianWohlleber/CL-record-space/releases)
2. Open the DMG and drag **record_space** to **Applications**
3. Launch from Applications — the icon appears in your menu bar

### From source

Requires Xcode 16+ and macOS 14+.

```bash
git clone https://github.com/JulianWohlleber/CL-record-space.git
cd CL-record-space
make install
```

This builds the app and copies it to `/Applications`.

Other targets:

```bash
make build    # build only
make run      # build and launch
make dmg      # create a distributable DMG
make clean    # remove build artifacts
make uninstall
```

## Setup

On first launch, record_space asks you to select an **Obsidian vault folder**. It creates two subdirectories:

```
your-vault/
├── recordings/     ← .m4a audio files
├── transcripts/    ← timestamped transcript markdown
└── *.md            ← recording notes (linked to transcript + audio)
```

### Permissions

The app requests:
- **Microphone** — to record audio
- **Speech Recognition** — for Apple's on-device transcription

### Optional: Ollama

For LLM-powered transcript correction and auto-generated titles, install [Ollama](https://ollama.com) and pull a model:

```bash
ollama pull mistral
```

record_space detects Ollama automatically on `localhost:11434`.

## Global hotkeys

| Shortcut | Action |
|----------|--------|
| `⌃⌥⌘R` | Start / Stop recording |
| `⌃⌥⌘P` | Pause / Resume |
| `⌃⌥⌘M` | Place marker |
| `⌃⌥⌘N` | Focus quicknote field |

## Output format

Each recording produces three files:

**Note** (`2024-03-29-1430-meeting-title.md`):
```markdown
---
Created: 2024-03-29 14:30
---
[Transcript](transcripts/2024-03-29-1430-transcript.md)

## Notes

## Quicknotes
14:32 Remember to follow up on budget

## Summary
#insights

#actions
- [ ]

#Notes
```

**Transcript** (`transcripts/2024-03-29-1430-transcript.md`):
```markdown
#transcript

![[2024-03-29-1430-recording.m4a]]

[00:00] So let's start with the quarterly review.
[00:15] The ==main concern is the timeline== for the next release.
[02:00] Moving on to budget allocation...
```

**Audio** (`recordings/2024-03-29-1430-recording.m4a`)

## Architecture

```
VoiceMemoBar/
├── AppDelegate.swift              # Menu bar icon, blink modes, popover
├── VoiceMemoBarApp.swift          # App entry point
├── Models/
│   └── AppSettings.swift          # UserDefaults, security-scoped bookmarks
├── Services/
│   ├── AudioRecorderService.swift       # AVAudioEngine recording + M4A export
│   ├── TranscriptionService.swift       # Apple SFSpeechRecognizer + chunking
│   ├── WhisperTranscriptionService.swift # WhisperKit CoreML engine
│   ├── OllamaService.swift             # LLM transcript correction + titling
│   ├── HotkeyService.swift             # Global hotkey registration
│   └── PermissionsService.swift        # Mic + speech permission flow
├── ViewModels/
│   ├── RecorderViewModel.swift    # Recording state machine + file pipeline
│   └── SetupViewModel.swift       # First-launch vault selection
└── Views/
    ├── ContentView.swift          # Root view (setup vs recorder)
    ├── RecorderView.swift         # Recording popover UI
    ├── SettingsView.swift         # Settings window
    ├── SetupView.swift            # First-launch setup
    └── TranscribingView.swift     # Post-recording progress
```

## Requirements

- macOS 14.0+
- Xcode 16+ (to build from source)
- Apple Silicon or Intel Mac
- Optional: [Ollama](https://ollama.com) for transcript correction

## License

MIT
