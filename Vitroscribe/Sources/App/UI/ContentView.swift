import SwiftUI

struct ContentView: View {
    @State private var selectedTab: Int = 0
    @ObservedObject var audioManager = AudioEngineManager.shared
    @ObservedObject var meetingDetector = MeetingDetector.shared
    
    var body: some View {
        TabView(selection: $selectedTab) {
            
            // Home / Realtime View
            VStack {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Vitroscribe")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        Text("Automated Meeting Transcription")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    
                    VStack(alignment: .trailing) {
                        HStack {
                            Circle()
                                .fill(meetingDetector.isMeetingActive ? Color.green : Color.orange)
                                .frame(width: 10, height: 10)
                            Text(meetingDetector.isMeetingActive ? "Meeting Detected" : "Waiting for Meeting...")
                                .font(.caption)
                        }
                        
                        HStack(spacing: 12) {
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
                            
                            Button(action: {
                                NSApplication.shared.terminate(nil)
                            }) {
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
                }
                
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if audioManager.currentTranscript.isEmpty && audioManager.activeSpeech.isEmpty {
                                    VStack {
                                        Spacer(minLength: 60)
                                        Image(systemName: "text.quote")
                                            .font(.largeTitle)
                                            .foregroundColor(.secondary.opacity(0.3))
                                        Text("Transcript will appear here as you speak...")
                                            .foregroundColor(.secondary)
                                            .font(.subheadline)
                                        Spacer()
                                    }
                                    .frame(maxWidth: .infinity)
                                } else {
                                    Text(audioManager.currentTranscript)
                                        .padding()
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                        .font(.system(.body, design: .rounded))
                                        .lineSpacing(4)
                                        .textSelection(.enabled)
                                    
                                    Color.clear
                                        .frame(height: 1)
                                        .id("HISTORY_BOTTOM")
                                }
                            }
                        }
                        .background(Color.black.opacity(0.04))
                        .cornerRadius(12)
                        .padding([.horizontal, .top])
                        .onChange(of: audioManager.currentTranscript) { _ in
                            scrollToBottom(proxy: proxy, id: "HISTORY_BOTTOM")
                        }
                    }
                    
                    if !audioManager.activeSpeech.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Circle().fill(Color.blue).frame(width: 8, height: 8)
                                Text("Now Speaking")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(.blue)
                                    .textCase(.uppercase)
                                    .tracking(1)
                            }
                            
                            Text(audioManager.activeSpeech)
                                .font(.system(.title3, design: .rounded))
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.blue.opacity(0.06))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(Color.blue.opacity(0.15), lineWidth: 1)
                                        )
                                )
                        }
                        .padding()
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity.combined(with: .scale(scale: 0.95))
                        ))
                    } else {
                        Spacer().frame(height: 20)
                    }
                }
            }
            .tabItem {
                Label("Live", systemImage: "mic.fill")
            }
            .tag(0)
            
            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock.fill")
                }
                .tag(1)
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(2)
        }
        .padding()
        .onAppear {
            _ = MeetingDetector.shared
        }
    }
    
    private func scrollToBottom(proxy: ScrollViewProxy, id: String) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.3)) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }
}
