import SwiftUI

@main
struct VitroscribeApp: App {
    
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
                .background(VisualEffectView().ignoresSafeArea())
                .onReceive(AudioEngineManager.shared.$isRecording) { isRecording in
                    RecordingOverlayManager.shared.updateVisibility(isRecording: isRecording)
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Vitroscribe") {
                    openWindow(id: "about")
                }
            }
        }
        
        Window("About Vitroscribe", id: "about") {
            AboutView()
                .fixedSize()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set activation policy BEFORE the window appears — prevents dock icon flash
        // when starting in Menubar Only mode.
        MenuBarManager.shared.applyInitialActivationPolicy()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.shared.log("Vitroscribe launched.")

        _ = MeetingDetector.shared
        _ = GoogleCalendarService.shared
        _ = MicrosoftCalendarService.shared

        // Set up menu bar icon + menu
        MenuBarManager.shared.setup()

        // Become window delegate so we can intercept close in Menubar Only mode
        DispatchQueue.main.async {
            NSApp.windows.forEach { window in
                if !(window is NSPanel) { window.delegate = self }
            }
        }
    }

    // Re-show the main window when user clicks the dock icon while all windows are hidden
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            for window in NSApp.windows where !(window is NSPanel) {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }
}

extension AppDelegate: NSWindowDelegate {
    // In Menubar Only mode, pressing the red close button hides the window
    // instead of destroying it, so "Open Vitroscribe" can always bring it back.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if MenuBarManager.shared.visibilityMode == .menubarOnly {
            sender.orderOut(nil)
            return false
        }
        return true
    }
}

struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .underWindowBackground
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        // No update needed
    }
}
