# 🎙️ Vitroscribe

**Vitroscribe** is an autonomous, privacy-first macOS application that automatically detects when you join online meetings, records the audio, and transcribes the dialogue directly on your device. It streamlines your workflow by syncing calendars, discovering meeting links, and organizing history with intelligent metadata.

## ✨ Key Features

*   **⚡️ Smart Meeting Link Discovery**: Never search for a link again. Vitroscribe scans **descriptions, locations, and bodies** of your calendar events to find Google Meet, Zoom, and Teams links, even if they aren't in the primary "location" field.
*   **🚀 Meeting Join HUD**: One minute before scheduled meetings, a premium floating notification appears with a 15-second countdown. Use the **"Join & Capture"** button to open your call and start the transcript in a single action.
*   **🤖 Context-Aware Ad-hoc Tracking**: For unplanned Zoom or Slack calls, Vitroscribe automatically captures the **Meeting Window Title** (e.g., "Project Sync (Zoom)") to label your transcriptions instantly.
*   **📂 Optimized History Management**:
    *   **Global Search**: Instantly find specific transcripts by searching through **Meeting Titles** or the **entire transcript content**, with matched terms **highlighted in the transcript view**.
    *   **Date Filtering**: Use the graphical calendar picker to isolate meetings from any specific day.
    *   **Smart Pagination**: Smooth performance with `Load More` logic designed to handle 1000+ meetings without lag.
    *   **Recording Duration**: Each session shows exactly **how long the recording ran** (e.g. `15m`, `1h 5m`) — visible both in the sidebar list and the transcript detail header.
    *   **Intelligent Renaming**: Customize session titles for personalized organization.
*   **📅 Dual-Calendar Sync**: Natively integrates with **Google Calendar** and **Microsoft Outlook / Office 365** (secure PKCE flow). It fetches up to 50 upcoming events to keep your dashboard full.
*   **🔄 Instant Sync Matrix**: A dedicated "Sync Now" button in settings allows you to force a refresh across all connected platforms.
*   **🔒 100% On-Device Privacy**: Transcriptions are processed entirely locally on your Mac using Apple's `SFSpeechRecognizer`. No audio or text data is ever sent to the cloud.
*   **🎨 Premium macOS Identity**: Featuring a customized **translucent glass icon** with a dynamic soundwave and pen-tip branding, designed to look stunning in your Dock.
*   **⏱ Infinite Timeline Matrix**: Uses an absolute-millisecond ledger to stitch audio buffers perfectly, ensuring zero word-loss during network stutters or context switches.

## 🛠️ Technology Stack

*   **SwiftUI** - Modern declarative UI with custom spring animations and sidebar transitions.
*   **OAuth2 PKCE (MS Graph & Google API)** - Secure, client-side authentication for calendar integration.
*   **AVAudioEngine & SFSpeech** - High-performance local audio capture and Apple-native ML transcription.
*   **SQLite.swift** - Robust local persistence with automated schema migrations (v13+).
*   **CGWindowList & osascript** - Multi-threaded process and window inspection for real-time meeting detection.

## ⚙️ How it Works

1.  **The Detector:** Lightweight threads poll your active windows and hardware state every 2 seconds to spot active calls without impacting battery life.
2.  **The Scribe:** When a meeting starts, audio is streamed into an absolute-timeline ledger. Vitroscribe automatically breaks dialogue into paragraphs based on natural speech pauses (>2s).
3.  **The History Vault:** Sessions are stored with rich metadata — including **recording duration** (derived from session start vs. last transcript save). The sidebar features a clean, chronological layout with **Global Search** (with keyword highlighting), **Date Filtering**, and per-session duration badges to keep your archive manageable at a glance.
4.  **The Stop:** Once the meeting window or URL is closed, the app commits a final save and shuts down the engine instantly.

## 🚀 Getting Started

1. Clone the repository.
2. Generate the project via XcodeGen:
    ```bash
    xcodegen
    ```
3. Open `Vitroscribe.xcodeproj`.
4. Build and run (requires macOS 14.0+).

### 🎙️ Audio Setup Note
Vitroscribe uses your **System Default Input Device**.
*   **Standard Use**: Capture your own voice via the built-in microphone or headset.
*   **Full Meeting Capture**: To capture others speaking, use a loopback driver like [BlackHole 2ch](https://existential.audio/blackhole/). Route your meeting output to BlackHole and set BlackHole as your system input.

## 📜 License

MIT License

Copyright (c) 2026 Nikki Punjabi

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---
*Built with ❤️ using **Vibecoding**. This project is free for the community.*
