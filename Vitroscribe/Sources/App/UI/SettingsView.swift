import SwiftUI

struct SettingsView: View {
    @ObservedObject var googleAuth = GoogleAuthManager.shared
    @ObservedObject var googleCal = GoogleCalendarService.shared
    @ObservedObject var msAuth = MicrosoftAuthManager.shared
    @ObservedObject var msCal = MicrosoftCalendarService.shared
    @ObservedObject var audioManager = AudioEngineManager.shared
    @ObservedObject var menuBar = MenuBarManager.shared
    @State private var isLaunchAtStartupEnabled: Bool = StartupManager.shared.isLaunchAtStartupEnabled()
    @AppStorage("autoRecordMeetings") private var autoRecordMeetings: Bool = true
    
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
                VStack(alignment: .leading, spacing: 16) {
                    Text("General")
                        .font(.headline)
                        .padding(.bottom, 2)

                    SettingsRow(
                        icon: "record.circle",
                        iconColor: autoRecordMeetings ? .red : .secondary,
                        title: "Auto-Record Meetings",
                        subtitle: autoRecordMeetings
                            ? "Enabled — Recording starts automatically when a meeting is detected."
                            : "Disabled — You will be asked before each meeting is recorded."
                    ) {
                        Toggle("", isOn: $autoRecordMeetings)
                            .labelsHidden()
                    }

                    Divider()

                    SettingsRow(
                        icon: "menubar.rectangle",
                        iconColor: .blue,
                        title: "App Visibility",
                        subtitle: menuBar.visibilityMode.displayName
                    ) {
                        Picker("", selection: Binding(
                            get: { menuBar.visibilityMode },
                            set: { menuBar.setVisibilityMode($0) }
                        )) {
                            ForEach(AppVisibilityMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 160)
                    }

                    Divider()

                    SettingsRow(
                        icon: "bolt.fill",
                        iconColor: isLaunchAtStartupEnabled ? .green : .secondary,
                        title: "Launch at Startup",
                        subtitle: isLaunchAtStartupEnabled
                            ? "Enabled — Vitroscribe starts automatically when you log in."
                            : "Disabled — Launch Vitroscribe manually when needed."
                    ) {
                        Toggle("", isOn: $isLaunchAtStartupEnabled)
                            .onChange(of: isLaunchAtStartupEnabled) { newValue in
                                StartupManager.shared.setLaunchAtStartup(newValue)
                            }
                            .labelsHidden()
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(12)

                // Screen Share Privacy
                VStack(alignment: .leading, spacing: 12) {
                    Text("Screen Share Privacy")
                        .font(.headline)
                        .padding(.bottom, 4)

                    Toggle("Show Recording Icon on Screen Share", isOn: $audioManager.isOverlayShared)
                        .help("If disabled, the red recording icon will be invisible to others when you share your screen.")

                    Toggle("Show 'Join Meeting' HUD on Screen Share", isOn: $audioManager.isJoinPromptShared)
                        .help("If disabled, the meeting join prompt will be invisible to others during your screen share.")

                    Toggle("Show 'Meeting Detected' Popup on Screen Share", isOn: $audioManager.isPromptOverlayShared)
                        .help("If disabled, the 'Meeting Detected' prompt will be invisible to others during your screen share.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
                
                // Combined Events — today + next 2 days only
                UpcomingMeetingsSection(
                    googleEvents: googleCal.upcomingEvents,
                    msEvents: msCal.upcomingEvents
                )
                
                Spacer()
            }
            .padding()
        }
        .frame(minWidth: 450, minHeight: 600)
    }
}

// MARK: - Upcoming Meetings Section

private struct UpcomingMeetingsSection: View {
    let googleEvents: [CalendarEvent]
    let msEvents: [CalendarEvent]

    private var dayGroups: [(label: String, date: Date, events: [CalendarEvent])] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let allEvents = (googleEvents + msEvents).sorted {
            ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture)
        }

        return (0...2).compactMap { offset -> (String, Date, [CalendarEvent])? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: day)!
            let events = allEvents.filter {
                guard let s = $0.startDate else { return false }
                return s >= day && s < dayEnd
            }
            guard !events.isEmpty else { return nil }
            let label: String
            switch offset {
            case 0: label = "Today"
            case 1: label = "Tomorrow"
            default:
                let fmt = DateFormatter()
                fmt.dateFormat = "EEEE, MMM d"
                label = fmt.string(from: day)
            }
            return (label, day, events)
        }
    }

    var body: some View {
        if dayGroups.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 16) {
                Text("Upcoming Meetings")
                    .font(.headline)

                ForEach(dayGroups, id: \.date) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        // Day header
                        HStack(spacing: 6) {
                            Text(group.label)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(group.label == "Today" ? .accentColor : .primary)
                            Text("· \(group.events.count) meeting\(group.events.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.bottom, 2)

                        // Events
                        VStack(spacing: 4) {
                            ForEach(group.events) { event in
                                MeetingRow(event: event)
                            }
                        }
                    }
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(12)
        }
    }
}

private struct MeetingRow: View {
    let event: CalendarEvent

    private var timeString: String {
        guard let start = event.startDate else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return fmt.string(from: start)
    }

    var body: some View {
        HStack(spacing: 10) {
            // Time badge
            Text(timeString)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .leading)

            // Title + source
            VStack(alignment: .leading, spacing: 1) {
                Text(event.summary ?? "No Title")
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(event.source.rawValue.capitalized)
                    .font(.caption2)
                    .foregroundColor(.blue)
            }

            Spacer()

            if let link = event.joinLink, let url = URL(string: link) {
                Button("Join") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
    }
}

// MARK: - Settings Row

private struct SettingsRow<Control: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(iconColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            control()
        }
    }
}
