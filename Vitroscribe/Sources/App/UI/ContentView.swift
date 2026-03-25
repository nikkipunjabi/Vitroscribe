import SwiftUI

struct ContentView: View {
    @State private var selectedTab: Int = 0
    @ObservedObject var audioManager = AudioEngineManager.shared
    @ObservedObject var meetingDetector = MeetingDetector.shared

    var body: some View {
        TabView(selection: $selectedTab) {

            // ── Live / Realtime View ──────────────────────────────────────────
            VStack(spacing: 0) {

                // Header
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Vitroscribe")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        Text("Automated Meeting Transcription")
                            .foregroundColor(.secondary)
                    }
                    Spacer()

                    VStack(alignment: .trailing, spacing: 8) {
                        // Meeting detection status
                        HStack(spacing: 6) {
                            Circle()
                                .fill(meetingDetector.isMeetingActive ? Color.green : Color.orange)
                                .frame(width: 9, height: 9)
                            Text(meetingDetector.isMeetingActive ? "Meeting Detected" : "Waiting for Meeting...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        // Record / Stop button
                        HStack(spacing: 10) {
                            Button(action: {
                                if audioManager.isRecording {
                                    audioManager.stopRecording()
                                } else {
                                    audioManager.startRecording(manual: true)
                                }
                            }) {
                                Text(audioManager.isRecording ? "Stop Recording" : "Start Manual Recording")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(audioManager.isRecording ? .red : .blue)
                            .disabled(!audioManager.isModelReady && !audioManager.isRecording)

                            Button(action: { NSApplication.shared.terminate(nil) }) {
                                Image(systemName: "power")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(6)
                                    .background(Color.red.opacity(0.8))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Quit Vitroscribe")
                        }
                    }
                }
                .padding()

                // ── Banners ───────────────────────────────────────────────────

                // Whisper model downloading banner (first launch only)
                if audioManager.isModelLoading {
                    HStack(spacing: 12) {
                        ProgressView().scaleEffect(0.75)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Downloading AI Transcription Engine")
                                .fontWeight(.semibold)
                                .font(.subheadline)
                            Text("Downloading Whisper large-v3 turbo model (~1.6 GB). One-time download — runs fully on-device after this.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Color.blue.opacity(0.10))
                    .cornerRadius(10)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                }

                // Whisper model prewarming banner (shown on every launch until model is compiled)
                if audioManager.isModelPrewarming {
                    HStack(spacing: 12) {
                        ProgressView().scaleEffect(0.75)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Preparing AI Transcription Engine")
                                .fontWeight(.semibold)
                                .font(.subheadline)
                            Text("Optimising model for your Mac. This takes a moment on first launch — won't happen again.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.10))
                    .cornerRadius(10)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                }

                // Screen-recording permission warning
                if !meetingDetector.isScreenRecordingAuthorized {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.white)
                        VStack(alignment: .leading) {
                            Text("Screen Recording Permission Required")
                                .fontWeight(.bold)
                            Text("To auto-detect Google Meet and Zoom, please grant permission in System Settings.")
                                .font(.caption)
                        }
                        Spacer()
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }
                    .padding()
                    .background(Color.red.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                }

                // ── Transcript area + status footer ───────────────────────────
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if audioManager.currentTranscript.isEmpty {
                                    LiveEmptyStateView(
                                        isRecording: audioManager.isRecording,
                                        isModelReady: audioManager.isModelReady,
                                        isModelLoading: audioManager.isModelLoading || audioManager.isModelPrewarming)
                                } else {
                                    Text(audioManager.currentTranscript)
                                        .padding()
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                        .font(.system(.body, design: .rounded))
                                        .lineSpacing(5)
                                        .textSelection(.enabled)

                                    Color.clear.frame(height: 1).id("BOTTOM")
                                }
                            }
                        }
                        .onChange(of: audioManager.currentTranscript) { _ in
                            DispatchQueue.main.async {
                                withAnimation(.easeOut(duration: 0.3)) {
                                    proxy.scrollTo("BOTTOM", anchor: .bottom)
                                }
                            }
                        }
                    }
                    .background(Color.black.opacity(0.04))
                    .cornerRadius(12)
                    .padding([.horizontal, .top])

                    // Status footer — replaces the old "Now Speaking" section
                    RecordingStatusBar(
                        isRecording: audioManager.isRecording,
                        isTranscribing: audioManager.isTranscribing)
                }
            }
            .tabItem { Label("Live", systemImage: "mic.fill") }
            .tag(0)

            HistoryView()
                .tabItem { Label("History", systemImage: "clock.fill") }
                .tag(1)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(2)
        }
        .padding()
        .onAppear { _ = MeetingDetector.shared }
    }
}

// MARK: - Empty State

private struct LiveEmptyStateView: View {
    let isRecording: Bool
    let isModelReady: Bool
    let isModelLoading: Bool

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 60)
            Image(systemName: isRecording ? "waveform" : "mic.slash")
                .font(.system(size: 36))
                .foregroundColor(.secondary.opacity(0.35))

            if isModelLoading {
                Text("AI model is loading — recording will be available shortly.")
                    .foregroundColor(.secondary)
                    .font(.subheadline)
            } else if !isModelReady {
                Text("Whisper model unavailable. Please restart the app.")
                    .foregroundColor(.secondary)
                    .font(.subheadline)
            } else if isRecording {
                Text("Listening… transcript appears every ~25 seconds.")
                    .foregroundColor(.secondary)
                    .font(.subheadline)
            } else {
                Text("Start recording to capture the meeting transcript.")
                    .foregroundColor(.secondary)
                    .font(.subheadline)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding()
    }
}

// MARK: - Recording Status Bar

private struct RecordingStatusBar: View {
    let isRecording: Bool
    let isTranscribing: Bool

    @State private var pulse = false

    var body: some View {
        Group {
            if isRecording {
                HStack(spacing: 8) {
                    if isTranscribing {
                        // Spinner while Whisper is processing a chunk
                        ProgressView()
                            .scaleEffect(0.65)
                            .frame(width: 14, height: 14)
                        Text("Processing audio…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        // Pulsing dot while capturing audio
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                            .opacity(pulse ? 0.3 : 1.0)
                            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                            .onAppear { pulse = true }
                            .onDisappear { pulse = false }

                        Text("Recording — transcript updates every 25 seconds")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()

                    // Privacy badge
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                        Text("On-Device · Private")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary.opacity(0.6))
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            } else {
                // Not recording — keep spacing consistent
                Color.clear.frame(height: 36)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isRecording)
        .animation(.easeInOut(duration: 0.2), value: isTranscribing)
    }
}
