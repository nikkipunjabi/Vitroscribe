import SwiftUI

struct SettingsView: View {
    @ObservedObject var googleAuth = GoogleAuthManager.shared
    @ObservedObject var googleCal = GoogleCalendarService.shared
    @ObservedObject var msAuth = MicrosoftAuthManager.shared
    @ObservedObject var msCal = MicrosoftCalendarService.shared
    @ObservedObject var audioManager = AudioEngineManager.shared
    @State private var isLaunchAtStartupEnabled: Bool = StartupManager.shared.isLaunchAtStartupEnabled()
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Settings")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Spacer()
                    
                    Button(action: {
                        googleCal.fetchEvents()
                        msCal.fetchEvents()
                    }) {
                        Label("Sync Now", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                
                Divider()
                
                // General Settings
                VStack(alignment: .leading, spacing: 12) {
                    Text("General")
                        .font(.headline)
                        .padding(.bottom, 4)
                    
                    Toggle("Launch at Startup", isOn: $isLaunchAtStartupEnabled)
                        .onChange(of: isLaunchAtStartupEnabled) { newValue in
                            StartupManager.shared.setLaunchAtStartup(newValue)
                        }
                    
                    Toggle("Show Recording Icon on Screen Share", isOn: $audioManager.isOverlayShared)
                        .help("If disabled, the red recording icon will be invisible to others when you share your screen.")
                    
                    Toggle("Show 'Join Meeting' HUD on Screen Share", isOn: $audioManager.isJoinPromptShared)
                        .help("If disabled, the meeting join prompt will be invisible to others during your screen share.")
                    
                    Toggle("Show 'Meeting Detected' Popup on Screen Share", isOn: $audioManager.isPromptOverlayShared)
                        .help("If disabled, the 'Meeting Detected' prompt will be invisible to others during your screen share.")
                }
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(12)
                
                // Google Section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "g.circle.fill")
                            .foregroundColor(.blue)
                        Text("Google Calendar")
                            .font(.headline)
                    }
                    
                    if googleAuth.isConnected {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Connected: \(googleAuth.connectedEmail)")
                                .font(.subheadline)
                            Spacer()
                            Button("Disconnect") {
                                googleAuth.disconnect()
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .controlSize(.small)
                        }
                    } else {
                        Text("Connect your Google account to sync meetings.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Button("Connect Google") {
                            googleAuth.connect()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(12)
                
                // Microsoft Section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "m.circle.fill")
                            .foregroundColor(.blue)
                        Text("Microsoft Outlook")
                            .font(.headline)
                    }
                    
                    if msAuth.isConnected {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Connected: \(msAuth.connectedEmail)")
                                .font(.subheadline)
                            Spacer()
                            Button("Disconnect") {
                                msAuth.disconnect()
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .controlSize(.small)
                        }
                    } else {
                        Text("Connect your Microsoft/Office 365 account to sync Teams meetings.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        if !msAuth.lastError.isEmpty {
                            Text(msAuth.lastError)
                                .font(.caption2)
                                .foregroundColor(.red)
                                .padding(8)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(4)
                        }
                        
                        Button("Connect Microsoft") {
                            msAuth.connect()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(12)
                
                // Combined Events List
                let allEvents = (googleCal.upcomingEvents + msCal.upcomingEvents).sorted { 
                    ($0.startDate ?? Date.distantFuture) < ($1.startDate ?? Date.distantFuture)
                }
                
                if !allEvents.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Upcoming Meetings (\(allEvents.count))")
                            .font(.headline)
                        
                        VStack(spacing: 8) {
                            ForEach(allEvents.prefix(25)) { event in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(event.summary ?? "No Title")
                                            .fontWeight(.medium)
                                        HStack {
                                            if let start = event.startDate {
                                                Text(start.formatted(date: .abbreviated, time: .shortened))
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                            Text("•")
                                            Text(event.source.rawValue.capitalized)
                                                .font(.caption)
                                                .foregroundColor(.blue)
                                        }
                                    }
                                    
                                    Spacer()
                                    
                                    if let link = event.joinLink, let url = URL(string: link) {
                                        Button("Join") {
                                            NSWorkspace.shared.open(url)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                }
                                .padding(8)
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(8)
                            }
                        }
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(12)
                }
                
                Spacer()
            }
            .padding()
        }
        .frame(minWidth: 450, minHeight: 600)
    }
}
