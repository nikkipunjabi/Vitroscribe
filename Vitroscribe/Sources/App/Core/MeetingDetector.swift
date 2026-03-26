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

                // Zoom: "Zoom Meeting" or "Zoom - Free Account" (during call)
                let isZoom = ownerName.contains("zoom") && (windowName.contains("meeting") || windowName.contains("call"))
                // Teams: "Meeting | Microsoft Teams" or "Call |"
                let isTeams = ownerName.contains("teams") && (windowName.contains("meeting") || windowName.contains("call"))
                // Note: Google Meet is browser-based — handled by the AppleScript tab check below,
                // NOT here. Chrome keeps "Meet – …" in the window title even after leaving,
                // so checking it here causes a false positive that prevents auto-stop.

                if isZoom || isTeams {
                    meetingFound = true
                    exactMeetingMatch = true
                    detectedTitle = windowName
                    break
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
                            detectedTitle = tabs.first?.title
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

                // TRIGGER: Context (URL/Title) AND Audio Flowing
                let isCurrentlyInMeeting = meetingFound && audioFlowing
                
                if isCurrentlyInMeeting {
                    self.consecutiveMisses = 0
                    self.consecutiveHits += 1
                    
                        if self.consecutiveHits >= self.hitsRequiredToStart && !self.isMeetingActive && !audioManager.isRecording && !audioManager.isManualRecording {
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
                            Logger.shared.log("Auto-Detect: Meeting ended (Context lost after 30s). Stopping recording.")
                            self.isMeetingActive = false
                            self.consecutiveMisses = 0
                            audioManager.stopRecording()
                        }
                    } else {
                        self.consecutiveMisses = 0
                        self.isMeetingActive = false
                    }
                }
            }
        }
    }
    
    private struct BrowserTab {
        let url: String
        let title: String
    }

    /// Returns only tabs that represent an ACTIVE meeting (URL + title both confirmed).
    /// For Google Meet, the tab title changes from "Meet - xxx" to "Google Meet" / "Your meeting has ended"
    /// when the call ends — so checking the title prevents false positives from the lingering URL.
    private func getActiveMeetingTabs(from appName: String) -> [BrowserTab]? {
        // Each line: URL<TAB>Title
        let scriptSource = """
        tell application "\(appName)"
            set output to ""
            repeat with w in windows
                repeat with t in tabs of w
                    set output to output & URL of t & "\t" & name of t & "\n"
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
                    let title = parts[1...].joined(separator: "\t").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !url.isEmpty, self.isActiveMeetingTab(url: url, title: title) else { return nil }
                    return BrowserTab(url: url, title: title)
                }
        } catch {
            return nil
        }
    }

    private func isActiveMeetingTab(url: String, title: String) -> Bool {
        let lowerURL = url.lowercased()
        let lowerTitle = title.lowercased()

        // Google Meet: valid meeting URL AND the tab title must still show "meet - "
        // (the title changes to "Google Meet" or "Your meeting has ended" once the call ends)
        if lowerURL.contains("meet.google.com/") {
            let components = lowerURL.components(separatedBy: "meet.google.com/")
            if components.count > 1 {
                let pathPart = components[1].split { $0 == "?" || $0 == "#" }.first.map(String.init) ?? ""
                let noise = ["", "landing", "new", "check", "h", "home", "lookup"]
                let validURL = !noise.contains(pathPart) && pathPart.count >= 4
                let activeTitle = lowerTitle.hasPrefix("meet - ") || lowerTitle.hasPrefix("meet – ")
                return validURL && activeTitle
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
}
