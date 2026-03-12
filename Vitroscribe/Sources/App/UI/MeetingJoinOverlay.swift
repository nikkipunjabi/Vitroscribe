import SwiftUI
import AppKit

class MeetingJoinOverlayManager {
    static let shared = MeetingJoinOverlayManager()
    
    private var window: NSPanel?
    
    func show(for event: CalendarEvent) {
        if window != nil {
            close()
        }
        
        let contentView = MeetingJoinPromptView(event: event) { [weak self] in
            self?.close()
        }
        
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 440, height: 160)
        
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = hostingView
        panel.isMovableByWindowBackground = true
        
        self.window = panel
        updatePrivacySetting()
        
        // Position at top right
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: screenRect.maxX - panel.frame.width - 20,
                y: screenRect.maxY - panel.frame.height - 20
            ))
        }
        
        panel.makeKeyAndOrderFront(nil)
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            panel.animator().alphaValue = 1
        }
    }
    
    func close() {
        guard let existingWindow = window else { return }
        // Nullify immediately to prevent multiple close animations
        self.window = nil
        
        DispatchQueue.main.async {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                existingWindow.animator().alphaValue = 0
            } completionHandler: {
                existingWindow.orderOut(nil)
            }
        }
    }
    
    func updatePrivacySetting() {
        DispatchQueue.main.async {
            guard let window = self.window else { return }
            let isShared = AudioEngineManager.shared.isJoinPromptShared
            if isShared {
                window.sharingType = .readOnly
            } else {
                window.sharingType = .none
            }
        }
    }
}

struct MeetingJoinPromptView: View {
    let event: CalendarEvent
    let onDismiss: () -> Void
    
    @State private var timeRemaining: Int = 15
    @State private var progress: Double = 1.0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    // Icon / Avatar
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 48, height: 48)
                        
                        Image(systemName: "video.fill")
                            .foregroundColor(.white)
                            .font(.system(size: 20))
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Meeting Starting Soon")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.blue)
                            .textCase(.uppercase)
                            .tracking(1)
                        
                        Text(event.summary ?? "Upcoming Meeting")
                            .font(.headline)
                            .lineLimit(1)
                            .foregroundColor(.primary)
                        
                        Text("Starts in 1 minute")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        onDismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, -15)
                    .padding(.trailing, -5)
                    .help("Dismiss Notification")
                }
                
                HStack(spacing: 12) {
                    // Option 1: Join & Capture (Key Feature)
                    Button(action: {
                        if let link = event.joinLink, let url = URL(string: link) {
                            NSWorkspace.shared.open(url)
                            // Start capturing transcript immediately
                            AudioEngineManager.shared.startRecording(
                                manual: false,
                                title: event.summary,
                                startTime: event.startDate,
                                endTime: event.endDate
                            )
                            // Suppress auto-detector for a while since we manually handled it
                            MeetingDetector.shared.suppressTemporary()
                        }
                        onDismiss()
                    }) {
                        HStack {
                            Image(systemName: "mic.badge.plus")
                            Text("Join & Capture")
                        }
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.blue)
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                    
                    // Option 2: Just Join
                    Button(action: {
                        if let link = event.joinLink, let url = URL(string: link) {
                            NSWorkspace.shared.open(url)
                            // Suppress auto-detector prompt since user interacted
                            MeetingDetector.shared.suppressTemporary()
                        }
                        onDismiss()
                    }) {
                        Text("Just Join")
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.primary.opacity(0.1))
                            .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            
            Spacer()
            
            // Progress Bar & Timer
            ZStack(alignment: .leading) {
                // Background track
                Rectangle()
                    .fill(Color.secondary.opacity(0.1))
                    .frame(height: 4)
                
                // Animated Progress
                Rectangle()
                    .fill(Color.blue)
                    .frame(width: 440 * progress, height: 4)
                    .animation(.linear(duration: 1), value: progress)
                
                // Seconds indicator
                Text("\(timeRemaining)s")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.blue)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color(NSColor.windowBackgroundColor))
                    .cornerRadius(4)
                    .offset(x: max(0, (440 * progress) - 25), y: -8)
            }
        }
        .frame(width: 440, height: 160)
        .background(
            VisualEffectView()
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
        )
        .onReceive(timer) { _ in
            if timeRemaining > 1 {
                timeRemaining -= 1
                withAnimation(.linear(duration: 1.0)) {
                    progress = Double(timeRemaining) / 15.0
                }
            } else if timeRemaining == 1 {
                // Final step to zero
                timeRemaining = 0
                progress = 0
                // Brief delay before dismissal to show 0s
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    onDismiss()
                }
            }
        }
    }
}
