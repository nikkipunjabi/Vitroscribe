import Foundation
import AppKit
import os.log
import UserNotifications

class MeetingDetector: ObservableObject {
    static let shared = MeetingDetector()
    
    @Published var isMeetingActive: Bool = false
    @Published var isScreenRecordingAuthorized: Bool = true
    /// True whenever a meeting window/URL is detected, regardless of audio state.
    /// Used by the menu bar to show a one-click "Start Recording" shortcut.
    @Published var isInMeetingContext: Bool = false
    private var checkTimer: Timer?
    private var isSuppressed: Bool = false
    /// Set when the user manually stops a recording while still in a meeting context.
    /// Prevents auto-restart until ALL meeting contexts are gone (user is done with all meetings).
    private var suppressedUntilMeetingEnds: Bool = false
    private var wasRecordingOnLastTick: Bool = false

    // Performance: Fast polling (2s) for responsive auto-stop, like Krisp/Fathom.
    private var consecutiveHits: Int = 0
    private var consecutiveMisses: Int = 0
    private let hitsRequiredToStart = 3   // 6 seconds of evidence to prompt
    private let missesRequiredToStop = 4   // 8 seconds of "Gone" to stop
    
    private init() {
        startMonitoring()
    }
    
    func startMonitoring() {
        checkTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkForActiveMeetings()
        }
        Logger.shared.log("Meeting detector: Monitoring started (2s interval).")
    }
    
    func stopMonitoring() {
        checkTimer?.invalidate()
        checkTimer = nil
    }
    
    private func checkForActiveMeetings() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            if self.isSuppressed { return }

            // 1a. Scan on-screen windows for Zoom, Teams, and Google Meet
            let onScreenOptions = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
            // 1b. Scan ALL windows (including minimised) for Slack/Webex whose call UI is often a small floating window
            let allWindowOptions = CGWindowListOption(arrayLiteral: .excludeDesktopElements)
            guard let windowList = CGWindowListCopyWindowInfo(onScreenOptions, kCGNullWindowID) as? [[String: Any]],
                  let allWindowList = CGWindowListCopyWindowInfo(allWindowOptions, kCGNullWindowID) as? [[String: Any]] else {
                return
            }

            let ownPID = ProcessInfo.processInfo.processIdentifier
            var externalWindowFound = false
            var meetingFound = false
            var exactMeetingMatch = false
            var isBrowserOpen = false
            var detectedTitle: String? = nil
            // Set to true when the Teams AX check confirms an active call.
            // In that case we skip the audioFlowing gate so "waiting for others" is detected.
            var teamsCallConfirmed = false

            let browsers = ["google chrome", "arc", "safari", "microsoft edge"]

            for window in windowList {
                let windowName = (window[kCGWindowName as String] as? String ?? "").lowercased()
                let ownerName = (window[kCGWindowOwnerName as String] as? String ?? "").lowercased()
                let windowPID = window[kCGWindowOwnerPID as String] as? Int32 ?? 0

                if windowPID != ownPID && !windowName.isEmpty {
                    externalWindowFound = true
                }

                if browsers.contains(ownerName) {
                    isBrowserOpen = true
                }

                // Zoom: window title contains "meeting" or "call"
                let isZoom = ownerName.contains("zoom") &&
                    (windowName.contains("meeting") || windowName.contains("call"))

                // Note: Google Meet is browser-based — handled by the AppleScript tab check below.
                // Note: Teams is handled separately below via PID-based detection.

                if isZoom {
                    meetingFound = true
                    exactMeetingMatch = true
                    detectedTitle = windowName
                    break
                }
            }

            // ── Microsoft Teams (native app) ─────────────────────────────────────────
            // Teams 2.0 does NOT expose kCGWindowName via CGWindowList — window titles are
            // empty strings, so any string-based match fails. Instead we find the Teams
            // process by bundle ID via NSRunningApplication, then match windows by PID and
            // check only the window size (the in-call UI is always a large window).
            if !exactMeetingMatch {
                let teamsApp = NSWorkspace.shared.runningApplications.first {
                    let name   = ($0.localizedName    ?? "").lowercased()
                    let bundle = ($0.bundleIdentifier ?? "").lowercased()
                    return name == "microsoft teams" || name == "teams" ||
                           bundle.contains("com.microsoft.teams")
                }
                if let teamsApp = teamsApp {
                    let teamsPID = teamsApp.processIdentifier
                    for window in windowList {
                        guard (window[kCGWindowOwnerPID as String] as? Int32) == teamsPID else { continue }
                        let bounds = window[kCGWindowBounds as String] as? [String: Any]
                        let w = bounds?["Width"]  as? CGFloat ?? 0
                        let h = bounds?["Height"] as? CGFloat ?? 0
                        if w > 600 && h > 400 {
                            meetingFound      = true
                            exactMeetingMatch = true
                            teamsCallConfirmed = true
                            let raw = window[kCGWindowName as String] as? String ?? ""
                            detectedTitle = raw.isEmpty ? "Microsoft Teams" : raw
                            break
                        }
                    }
                }
            }

            // Slack/Webex/Cisco: check ALL windows so minimised huddle/call windows are caught
            if !exactMeetingMatch {
                for window in allWindowList {
                    let windowName = (window[kCGWindowName as String] as? String ?? "").lowercased()
                    let ownerName = (window[kCGWindowOwnerName as String] as? String ?? "").lowercased()

                    let isSlack = ownerName.contains("slack") &&
                                  (windowName.contains("huddle") || windowName.contains("call") ||
                                   windowName.contains("meeting") || windowName.hasPrefix("slack call"))
                    let isWebex = (ownerName.contains("webex") || ownerName.contains("cisco")) &&
                                  (windowName.contains("meeting") || windowName.contains("call") || windowName.contains("huddle"))

                    if isSlack || isWebex {
                        meetingFound = true
                        exactMeetingMatch = true
                        detectedTitle = windowName
                        break
                    }
                }
            }

            DispatchQueue.main.async { self.isScreenRecordingAuthorized = externalWindowFound }

            // 2. Browser Tab Check — uses title + URL so a "meeting ended" page is not treated as active
            if !exactMeetingMatch && isBrowserOpen {
                for browser in ["Google Chrome", "Arc", "Safari", "Microsoft Edge"] {
                    if let tabs = self.getActiveMeetingTabs(from: browser) {
                        if !tabs.isEmpty {
                            meetingFound = true
                            exactMeetingMatch = true
                            detectedTitle = self.cleanMeetingTitle(tabs.first?.title)
                        }
                    }
                    if exactMeetingMatch { break }
                }
            }
            
            // 3. Coordination & Decision Logic (v14.0 - Krisp Style)
            DispatchQueue.main.async {
                let audioManager = AudioEngineManager.shared
                let audioFlowing = AudioStreamMonitor.shared.isAudioFlowing

                // Publish raw context so the menu bar can always show a "Start Recording" shortcut
                self.isInMeetingContext = meetingFound

                // Detect when recording just stopped while still in a meeting context —
                // this means the user explicitly stopped it. Suppress auto-restart until
                // ALL meetings have ended (meetingFound goes false).
                let justStopped = self.wasRecordingOnLastTick && !audioManager.isRecording
                if justStopped && meetingFound {
                    self.suppressedUntilMeetingEnds = true
                    self.isMeetingActive = false
                    self.consecutiveHits = 0
                    Logger.shared.log("Auto-Record: Recording stopped by user during meeting — suppressing auto-restart.")
                }
                if !meetingFound {
                    self.suppressedUntilMeetingEnds = false
                }
                self.wasRecordingOnLastTick = audioManager.isRecording

                // TRIGGER: Context confirmed AND (audio flowing OR Teams AX confirmed an active call).
                // For Teams we skip the audioFlowing gate because the Leave-button AX check
                // already proves we're in a real call — even before audio starts ("waiting for others").
                let isCurrentlyInMeeting = meetingFound && (audioFlowing || teamsCallConfirmed)

                if isCurrentlyInMeeting {
                    self.consecutiveMisses = 0
                    self.consecutiveHits += 1

                    if self.consecutiveHits >= self.hitsRequiredToStart
                        && !self.isMeetingActive
                        && !audioManager.isRecording
                        && !audioManager.isManualRecording
                        && !self.suppressedUntilMeetingEnds {
                        self.isMeetingActive = true
                        if UserDefaults.standard.bool(forKey: "autoRecordMeetings") {
                            Logger.shared.log("Auto-Record: Meeting detected, starting recording automatically.")
                            audioManager.startRecording(manual: false, title: detectedTitle)
                        } else {
                            Logger.shared.log("Auto-Detect: Meeting context found. Prompting user.")
                            self.sendRecordingPromptNotification(title: detectedTitle)
                        }
                    }
                } else {
                    self.consecutiveHits = 0

                    // AUTO-STOP:
                    // If we are recording (auto or managed), we stay active ONLY if the Context persists.
                    // We IGNORE audioFlowing here because our own recording makes it always true.
                    if audioManager.isRecording && !audioManager.isManualRecording {
                        self.consecutiveMisses += 1

                        // Stop after 5 consecutive checks (~10 seconds) with no meeting context.
                        if !meetingFound && self.consecutiveMisses >= 5 {
                            Logger.shared.log("Auto-Detect: Meeting ended. Stopping recording.")
                            self.isMeetingActive = false
                            self.consecutiveMisses = 0
                            audioManager.stopRecording()
                        }
                    } else {
                        self.consecutiveMisses = 0
                        if !self.suppressedUntilMeetingEnds {
                            self.isMeetingActive = false
                        }
                    }
                }
            }
        }
    }
    
    private struct BrowserTab {
        let url: String
        let title: String
        let bodySnippet: String   // first 300 chars of body text, for "left meeting" detection
    }

    /// Returns only tabs that represent an ACTIVE meeting.
    /// For Google Meet, document.title does NOT change when you leave — it keeps "Meet – Title"
    /// even on the "You've left the meeting" page. So we also run a tiny JS snippet to read
    /// the body text and check for the leave-state explicitly.
    private func getActiveMeetingTabs(from appName: String) -> [BrowserTab]? {
        // Each line: URL<TAB>Title<TAB>BodySnippet (body only fetched for meet.google.com tabs)
        let scriptSource = """
        tell application "\(appName)"
            set output to ""
            repeat with w in windows
                repeat with t in tabs of w
                    set tabURL to URL of t
                    set tabTitle to name of t
                    set bodySnip to ""
                    if tabURL contains "meet.google.com" then
                        try
                            set bodySnip to execute t javascript "document.body ? document.body.innerText.substring(0, 300) : ''"
                        end try
                    end if
                    set output to output & tabURL & "\t" & tabTitle & "\t" & bodySnip & "\n"
                end repeat
            end repeat
            return output
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", scriptSource]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8), !output.isEmpty else { return nil }

            return output
                .components(separatedBy: "\n")
                .compactMap { line -> BrowserTab? in
                    let parts = line.components(separatedBy: "\t")
                    guard parts.count >= 2 else { return nil }
                    let url = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    let body = parts.count >= 3 ? parts[2...].joined(separator: "\t").trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    guard !url.isEmpty, self.isActiveMeetingTab(url: url, title: title, body: body) else { return nil }
                    return BrowserTab(url: url, title: title, bodySnippet: body)
                }
        } catch {
            return nil
        }
    }

    private func isActiveMeetingTab(url: String, title: String, body: String = "") -> Bool {
        let lowerURL = url.lowercased()
        let lowerTitle = title.lowercased()
        let lowerBody = body.lowercased()

        // Google Meet: valid meeting URL AND not in a "left meeting" state.
        // document.title does NOT change after leaving — it stays "Meet – Title".
        // So we check the body text for the leave-screen copy as the reliable signal.
        if lowerURL.contains("meet.google.com/") {
            let components = lowerURL.components(separatedBy: "meet.google.com/")
            if components.count > 1 {
                let pathPart = components[1].split { $0 == "?" || $0 == "#" }.first.map(String.init) ?? ""
                let noise = ["", "landing", "new", "check", "h", "home", "lookup"]
                let validURL = !noise.contains(pathPart) && pathPart.count >= 4
                let hasTitle = lowerTitle.hasPrefix("meet - ") || lowerTitle.hasPrefix("meet – ")
                // If we have body text and it shows the leave screen, the meeting is over.
                let hasLeftMeeting = !lowerBody.isEmpty &&
                    (lowerBody.contains("you've left") || lowerBody.contains("you left the meeting") ||
                     lowerBody.contains("left the meeting"))
                return validURL && hasTitle && !hasLeftMeeting
            }
        }

        return lowerURL.contains("zoom.us/j/") ||
               lowerURL.contains("teams.microsoft.com/l/meetup-join") ||
               lowerURL.contains("webex.com/meet")
    }
    
    private func sendRecordingPromptNotification(title: String? = nil) {
        PromptOverlayManager.shared.show(title: title)
    }
    
    func suppressTemporary() {
        self.isSuppressed = true
        Logger.shared.log("Meeting detector: Suppressed for 5 minutes.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
            self.isSuppressed = false
            Logger.shared.log("Meeting detector: Suppression lifted.")
        }
    }

    // MARK: - Title Cleanup

    /// Strips platform prefixes/suffixes so only the actual meeting name is stored.
    /// e.g. "Meet – Gravitas Standup" → "Gravitas Standup"
    ///      "Gravitas Standup | Microsoft Teams" → "Gravitas Standup"
    private func cleanMeetingTitle(_ raw: String?) -> String? {
        guard var title = raw, !title.isEmpty else { return nil }

        // Google Meet: "Meet – Title" or "Meet - Title"
        for prefix in ["Meet – ", "Meet - "] {
            if title.hasPrefix(prefix) {
                title = String(title.dropFirst(prefix.count))
                break
            }
        }

        // Microsoft Teams browser: "Title | Microsoft Teams"
        if let range = title.range(of: " | Microsoft Teams", options: .caseInsensitive) {
            title = String(title[..<range.lowerBound])
        }

        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
