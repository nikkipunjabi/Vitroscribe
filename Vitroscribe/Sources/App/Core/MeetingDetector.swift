import Foundation
import AppKit
import os.log
import UserNotifications

class MeetingDetector: ObservableObject {
    static let shared = MeetingDetector()
    
    @Published var isMeetingActive: Bool = false
    @Published var isScreenRecordingAuthorized: Bool = true
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
            
            // 1. Scan Visible Windows (High Performance)
            let windowOptions = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
            guard let windowList = CGWindowListCopyWindowInfo(windowOptions, kCGNullWindowID) as? [[String: Any]] else {
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
                
                // --- STRICT MATCHING LOGIC ---
                // We only match windows that signify an ACTIVE call.
                // Zoom: "Zoom Meeting" or "Zoom - Free Account" (during call)
                let isZoom = ownerName.contains("zoom") && (windowName.contains("meeting") || windowName.contains("call"))
                // Teams: "Meeting | Microsoft Teams" or "Call |"
                let isTeams = ownerName.contains("teams") && (windowName.contains("meeting") || windowName.contains("call"))
                // Webex/Slack: "Huddle", "Call", "Meeting"
                let isOthers = (ownerName.contains("webex") || ownerName.contains("slack") || ownerName.contains("cisco")) && 
                               (windowName.contains("meeting") || windowName.contains("call") || windowName.contains("huddle"))
                // Meet: "Meet - " is the prefix for active Google Meet tabs
                let isMeet = windowName.contains("meet - ")
                
                if isZoom || isTeams || isOthers || isMeet {
                    meetingFound = true
                    exactMeetingMatch = true
                    detectedTitle = windowName
                    break
                }
            }
            
            DispatchQueue.main.async { self.isScreenRecordingAuthorized = externalWindowFound }
            
            // 2. Browser Tab Check (Only if window scan didn't find a definitive match)
            if !exactMeetingMatch && isBrowserOpen {
                for browser in ["Google Chrome", "Arc", "Safari", "Microsoft Edge"] {
                    // Optimized: Only get URLs if the browser has Windows visible
                    if let urls = self.getURLs(from: browser) {
                        for url in urls {
                            if self.isMeetingURL(url) {
                                meetingFound = true
                                exactMeetingMatch = true
                                break
                            }
                        }
                    }
                    if exactMeetingMatch { break }
                }
            }
            
            // 3. Coordination & Decision Logic (v14.0 - Krisp Style)
            DispatchQueue.main.async {
                let audioManager = AudioEngineManager.shared
                let audioFlowing = AudioStreamMonitor.shared.isAudioFlowing
                
                // TRIGGER: Context (URL/Title) AND Audio Flowing
                let isCurrentlyInMeeting = meetingFound && audioFlowing
                
                if isCurrentlyInMeeting {
                    self.consecutiveMisses = 0
                    self.consecutiveHits += 1
                    
                        if self.consecutiveHits >= self.hitsRequiredToStart && !self.isMeetingActive && !audioManager.isRecording && !audioManager.isManualRecording {
                            self.isMeetingActive = true
                            Logger.shared.log("Auto-Detect: Meeting context found. Prompting user.")
                            self.sendRecordingPromptNotification(title: detectedTitle)
                        }
                } else {
                    self.consecutiveHits = 0
                    
                    // AUTO-STOP: 
                    // If we are recording (auto or managed), we stay active ONLY if the Context persists.
                    // We IGNORE audioFlowing here because our own recording makes it always true.
                    if audioManager.isRecording && !audioManager.isManualRecording {
                        self.consecutiveMisses += 1
                        
                        // If the Window/URL match is gone for 'missesRequiredToStop' checks, we stop.
                        // v11.3: Increased to 15 misses (30 seconds) to be more robust against temporary context loss.
                        if !meetingFound && self.consecutiveMisses >= 15 {
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
    
    private func getURLs(from appName: String) -> [String]? {
        // Light-weight AppleScript via Process to avoid app-level threading issues
        let scriptSource = "tell application \"\(appName)\" to return URL of every tab of every window"
        
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
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                return output.trimmingCharacters(in: .whitespacesAndNewlines)
                             .components(separatedBy: ", ")
                             .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                             .filter { !$0.isEmpty }
            }
        } catch {
            return nil
        }
        return nil
    }
    
    private func isMeetingURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        if lower.contains("meet.google.com/") {
            let components = lower.components(separatedBy: "meet.google.com/")
            if components.count > 1 {
                let fullPath = components[1]
                // Safely extract the meeting ID before any '?' or '#'
                let pathPart = fullPath.split { $0 == "?" || $0 == "#" }.first ?? ""
                let path = String(pathPart)
                
                // "landing", "home", "check" are NOT active meetings
                let noise = ["", "landing", "new", "check", "h", "home", "lookup"]
                return !noise.contains(path) && path.count >= 4
            }
        }
        return lower.contains("zoom.us/j/") || lower.contains("teams.microsoft.com/l/meetup-join") || lower.contains("webex.com/meet")
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
