import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hotkeyService: HotkeyService!
    private let recorderViewModel = RecorderViewModel()
    private var cancellables = Set<AnyCancellable>()

    private enum BlinkMode {
        case none
        case recording   // alternates MenuBarRecording <-> MenuBarRecordingDim
        case marking     // alternates MenuBarMarking <-> MenuBarMarkingDim
    }

    private var markingTimer: Timer?
    private var noteDroppedTimer: Timer?
    private var blinkTimer: Timer?
    private var blinkOn = true
    private var blinkMode: BlinkMode = .none
    private var settingsWindow: NSWindow?
    private var settingsWindowDelegate: SettingsWindowDelegate?
    private let menuBarIconMax: CGFloat = 22

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        setupHotkeys()
        observeState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Balance security-scoped bookmark: release the sandbox resource
        // token acquired by accessBaseFolder(). Without this, the token
        // leaks until the process exits (macOS reclaims it, but explicit
        // cleanup is correct practice for balanced start/stop).
        AppSettings.shared.stopAccessingBaseFolder()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = menuBarImage(named: "MenuBarIdle")
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func menuBarImage(named name: String) -> NSImage? {
        guard let image = NSImage(named: name) else { return nil }
        // Fit inside an (menuBarIconMax × menuBarIconMax) box while preserving
        // the SVG's intrinsic aspect ratio — i.e. the largest scale where both
        // dimensions still fit. Never stretch.
        let intrinsic = image.size
        if intrinsic.width > 0 && intrinsic.height > 0 {
            let scale = min(menuBarIconMax / intrinsic.width, menuBarIconMax / intrinsic.height)
            image.size = NSSize(width: intrinsic.width * scale, height: intrinsic.height * scale)
        }
        // Idle + Paused are pure black → template so they adapt to menu bar appearance.
        // Recording (blue dot), Marking (yellow diamond), NoteDropped (green triangle)
        // must render in their source colors so the colored accents stay visible.
        switch name {
        case "MenuBarIdle", "MenuBarPaused":
            image.isTemplate = true
        default:
            image.isTemplate = false
        }
        return image
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 60)
        popover.behavior = .transient
        popover.animates = true
        let contentView = ContentView()
            .environmentObject(recorderViewModel)
        popover.contentViewController = NSHostingController(rootView: contentView)
    }

    private func setupHotkeys() {
        hotkeyService = HotkeyService()
        hotkeyService.onToggleRecording = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.recorderViewModel.toggleRecording()
            }
        }
        hotkeyService.onPauseResume = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.recorderViewModel.togglePause()
            }
        }
        hotkeyService.onPlaceMarker = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.recorderViewModel.placeMarker()
            }
        }
        hotkeyService.onQuickNote = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.recorderViewModel.quickNoteRequested = true
                self.showPopover()
            }
        }
        hotkeyService.startListening()
    }

    private func observeState() {
        recorderViewModel.$state
            .sink { [weak self] state in
                guard let self else { return }
                self.updateMenuBarIcon(for: state)
            }
            .store(in: &cancellables)

        recorderViewModel.$shouldFlashMarker
            .filter { $0 }
            .sink { [weak self] _ in
                self?.showMarkerFlash()
            }
            .store(in: &cancellables)

        recorderViewModel.$shouldFlashNoteDropped
            .filter { $0 }
            .sink { [weak self] _ in
                self?.showNoteDroppedFlash()
            }
            .store(in: &cancellables)

        recorderViewModel.$openSettingsRequested
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self else { return }
                self.recorderViewModel.openSettingsRequested = false
                self.openSettingsWindow()
            }
            .store(in: &cancellables)
    }

    private func updateMenuBarIcon(for state: RecordingState) {
        guard let button = statusItem.button else { return }
        // Don't override an active marking blink or note-dropped flash —
        // they should run their own timed course.
        if blinkMode == .marking { return }
        if noteDroppedTimer != nil { return }
        switch state {
        case .recording:
            startBlink(mode: .recording)
        case .paused:
            stopBlink()
            button.image = menuBarImage(named: "MenuBarPaused")
        case .idle, .transcribing:
            stopBlink()
            button.image = menuBarImage(named: "MenuBarIdle")
        }
    }

    // MARK: - Blink

    private func startBlink(mode: BlinkMode) {
        guard let button = statusItem.button, mode != .none else { return }
        // Switching modes — stop the existing timer first.
        if blinkMode != mode {
            blinkTimer?.invalidate()
            blinkTimer = nil
        }
        blinkMode = mode
        blinkOn = true
        button.image = menuBarImage(named: onIconName(for: mode))
        guard blinkTimer == nil else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let button = self.statusItem.button else { return }
                guard self.blinkMode != .none else { return }
                self.blinkOn.toggle()
                let name = self.blinkOn
                    ? self.onIconName(for: self.blinkMode)
                    : self.offIconName(for: self.blinkMode)
                button.image = self.menuBarImage(named: name)
            }
        }
    }

    private func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkMode = .none
        blinkOn = true
    }

    private func onIconName(for mode: BlinkMode) -> String {
        switch mode {
        case .recording: return "MenuBarRecording"
        case .marking:   return "MenuBarMarking"
        case .none:      return "MenuBarIdle"
        }
    }

    private func offIconName(for mode: BlinkMode) -> String {
        switch mode {
        case .recording: return "MenuBarRecordingDim"
        case .marking:   return "MenuBarMarkingDim"
        case .none:      return "MenuBarIdle"
        }
    }

    // MARK: - Marker flash

    private func showMarkerFlash() {
        markingTimer?.invalidate()
        // Begin marking blink (overrides recording blink while active)
        startBlink(mode: .marking)

        let duration: TimeInterval = 10.0
        markingTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.endMarkerFlash() }
        }
    }

    private func endMarkerFlash() {
        markingTimer?.invalidate()
        markingTimer = nil
        recorderViewModel.shouldFlashMarker = false
        // Resume recording blink if still recording, otherwise reflect current state
        stopBlink()
        updateMenuBarIcon(for: recorderViewModel.state)
    }

    // MARK: - Note dropped flash

    private func showNoteDroppedFlash() {
        guard let button = statusItem.button else { return }
        noteDroppedTimer?.invalidate()
        // Pause any active blink while showing the transient note icon
        blinkTimer?.invalidate()
        blinkTimer = nil
        let previousMode = blinkMode
        blinkMode = .none

        button.image = menuBarImage(named: "MenuBarNoteDropped")

        let duration: TimeInterval = 2.0
        noteDroppedTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.endNoteDroppedFlash(previousMode: previousMode) }
        }
    }

    private func endNoteDroppedFlash(previousMode: BlinkMode) {
        noteDroppedTimer?.invalidate()
        noteDroppedTimer = nil
        recorderViewModel.shouldFlashNoteDropped = false
        // If marking was active before the note flash, resume marking blink
        // (its timer is still counting down). Otherwise reflect current state.
        if previousMode == .marking && markingTimer != nil {
            startBlink(mode: .marking)
        } else {
            updateMenuBarIcon(for: recorderViewModel.state)
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func openSettingsWindow() {
        popover.performClose(nil)

        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.setContentSize(NSSize(width: 400, height: 320))
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false

        let delegate = SettingsWindowDelegate { [weak self] in
            self?.settingsWindow = nil
            self?.settingsWindowDelegate = nil
        }
        window.delegate = delegate
        settingsWindowDelegate = delegate

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }
}

final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}
