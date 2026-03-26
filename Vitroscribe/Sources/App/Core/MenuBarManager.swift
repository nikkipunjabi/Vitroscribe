import AppKit
import Combine

// MARK: - Visibility Mode

enum AppVisibilityMode: String, CaseIterable {
    case dockAndMenubar
    case menubarOnly
    case dockOnly

    var displayName: String {
        switch self {
        case .dockAndMenubar: return "Dock & Menubar"
        case .menubarOnly:    return "Menubar Only"
        case .dockOnly:       return "Dock Only"
        }
    }
}

// MARK: - MenuBarManager

class MenuBarManager: NSObject, ObservableObject {
    static let shared = MenuBarManager()

    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private let visibilityKey = "appVisibilityMode"

    @Published private(set) var visibilityMode: AppVisibilityMode = {
        let raw = UserDefaults.standard.string(forKey: "appVisibilityMode") ?? AppVisibilityMode.menubarOnly.rawValue
        return AppVisibilityMode(rawValue: raw) ?? .menubarOnly
    }()

    override private init() { super.init() }

    // Called in applicationWillFinishLaunching — before the window appears — so
    // there is zero dock-icon flash when starting in Menubar Only mode.
    func applyInitialActivationPolicy() {
        if visibilityMode == .menubarOnly {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func setup() {
        // Observe recording state → update icon + rebuild menu
        AudioEngineManager.shared.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusIcon()
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        // Observe meeting context → rebuild menu so the "Meeting Detected" shortcut appears/disappears
        MeetingDetector.shared.$isInMeetingContext
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)

        applyVisibilityMode(visibilityMode, animated: false)
    }

    func setVisibilityMode(_ mode: AppVisibilityMode) {
        guard mode != visibilityMode else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: visibilityKey)
        visibilityMode = mode
        applyVisibilityMode(mode, animated: true)
    }

    // MARK: - Private

    private func applyVisibilityMode(_ mode: AppVisibilityMode, animated: Bool) {
        switch mode {
        case .dockAndMenubar:
            NSApp.setActivationPolicy(.regular)
            ensureStatusItem()
        case .menubarOnly:
            NSApp.setActivationPolicy(.accessory)
            ensureStatusItem()
        case .dockOnly:
            NSApp.setActivationPolicy(.regular)
            removeStatusItem()
        }
    }

    private func ensureStatusItem() {
        guard statusItem == nil else {
            rebuildMenu()
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        rebuildMenu()
    }

    private func removeStatusItem() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let recording = AudioEngineManager.shared.isRecording
        // Template images are automatically white on dark menu bars and black on light ones,
        // matching every other system icon. Red tint signals an active recording.
        let symbol = recording ? "waveform.badge.mic" : "waveform"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Vitroscribe")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = recording ? .systemRed : nil
    }

    func rebuildMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        let audio = AudioEngineManager.shared

        let detector = MeetingDetector.shared
        let inMeeting = detector.isInMeetingContext

        // ── Status ────────────────────────────────────────────────────
        let statusLine = NSMenuItem(
            title: audio.isRecording ? "● Recording Active" : (inMeeting ? "● Meeting Detected" : "○ Waiting for Meeting…"),
            action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        menu.addItem(.separator())

        // ── Meeting detected but not recording → one-click shortcut ───
        if inMeeting && !audio.isRecording {
            let promptItem = NSMenuItem(
                title: "Meeting Detected — Start Recording",
                action: #selector(startRecording),
                keyEquivalent: "")
            promptItem.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
            promptItem.target = self
            menu.addItem(promptItem)
            menu.addItem(.separator())
        }

        // ── Record toggle ─────────────────────────────────────────────
        if audio.isRecording {
            let item = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: nil)
            item.target = self
            menu.addItem(item)
        } else {
            let item = NSMenuItem(title: "Start Manual Recording", action: #selector(startRecording), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "mic.badge.plus", accessibilityDescription: nil)
            item.target = self
            menu.addItem(item)
        }

        // ── Next meeting today (if any) ───────────────────────────────
        if let event = nextMeetingToday() {
            menu.addItem(.separator())
            let fmt = DateFormatter()
            fmt.dateFormat = "h:mm a"
            let time = event.startDate.map { fmt.string(from: $0) } ?? ""
            let title = "📅  \(event.summary ?? "Meeting")  ·  \(time)"

            if let link = event.joinLink, let url = URL(string: link) {
                let item = NSMenuItem(title: title, action: #selector(joinMeeting(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
                menu.addItem(item)
            } else {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        // ── Open app ─────────────────────────────────────────────────
        let openItem = NSMenuItem(title: "Open Vitroscribe", action: #selector(openApp), keyEquivalent: "")
        openItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        // ── Quit ─────────────────────────────────────────────────────
        menu.addItem(NSMenuItem(title: "Quit Vitroscribe",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func startRecording() {
        AudioEngineManager.shared.startRecording(manual: true)
    }

    @objc private func stopRecording() {
        AudioEngineManager.shared.stopRecording()
    }

    @objc private func openApp() {
        NSApp.activate(ignoringOtherApps: true)
        // Bring the first non-panel window to front (the main ContentView window)
        for window in NSApp.windows where !(window is NSPanel) {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    @objc private func joinMeeting(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func changeVisibility(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = AppVisibilityMode(rawValue: raw) else { return }
        setVisibilityMode(mode)
    }

    // MARK: - Helpers

    private func nextMeetingToday() -> CalendarEvent? {
        let now = Date()
        let cal = Calendar.current
        guard let endOfDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) else { return nil }

        return (GoogleCalendarService.shared.upcomingEvents + MicrosoftCalendarService.shared.upcomingEvents)
            .filter { ($0.startDate ?? .distantPast) > now && ($0.startDate ?? .distantFuture) < endOfDay }
            .min { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    }
}
