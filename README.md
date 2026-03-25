# 🎙️ Vitroscribe

**Vitroscribe** is an autonomous, privacy-first macOS application that automatically detects when you join online meetings, records the audio, and transcribes every word spoken — entirely on your device.

---

## ✨ Key Features

- **🤖 Whisper-Powered Transcription** — Powered by OpenAI's Whisper `small` multilingual model via WhisperKit, the same engine behind MacWhisper. Captures every word spoken in a meeting with high accuracy, including accents, fast speech, and overlapping dialogue. Supports 99+ languages including English, Hindi, Urdu, and more.
- **🔒 100% On-Device & Private** — All transcription runs locally via Apple Core ML. No audio, no text, and no metadata ever leaves your Mac. The model is downloaded once (~490 MB) and cached permanently in Application Support.
- **⚡️ Smart Meeting Link Discovery** — Scans calendar event descriptions, locations, and bodies for Google Meet, Zoom, and Teams links automatically.
- **🚀 Meeting Join HUD** — One minute before a scheduled meeting, a floating HUD appears with a 15-second countdown and a **"Join & Capture"** button to open the call and start transcription in one tap.
- **🤖 Context-Aware Ad-hoc Tracking** — For unplanned calls, Vitroscribe captures the meeting window title (e.g., "Project Sync (Zoom)") to label transcriptions instantly.
- **⏱ Zero-Gap Transcript Engine** — A rolling 25-second chunk strategy with catch-up transcription: audio that accumulates during a processing window is transcribed immediately when the previous chunk finishes — not at the next timer tick. Nothing is ever silently discarded.
- **📂 Optimized History Management**
  - **Global Search** — Search across meeting titles and full transcript content, with matched terms highlighted.
  - **Date Filtering** — Calendar picker to isolate any specific day's meetings.
  - **Smart Pagination** — Handles 1000+ sessions without lag.
  - **Recording Duration** — Each session shows exactly how long it ran.
  - **Intelligent Renaming** — Customize session titles.
- **📅 Dual-Calendar Sync** — Integrates with Google Calendar and Microsoft Outlook / Office 365 via secure PKCE OAuth2 flow.
- **🔄 Instant Sync** — "Sync Now" button in Settings forces a refresh across all connected calendars.

---

## 🛠️ Technology Stack

| Layer             | Technology                                                     |
| ----------------- | -------------------------------------------------------------- |
| UI                | SwiftUI — declarative, spring-animated, sidebar transitions    |
| Transcription     | WhisperKit + Apple Core ML (`openai_whisper-small`, multilingual) |
| Audio Capture     | AVAudioEngine — 16 kHz mono float32 pipeline                   |
| Calendar Auth     | OAuth2 PKCE — MS Graph & Google API                            |
| Persistence       | SQLite.swift — local database with automated schema migrations |
| Meeting Detection | CGWindowList + osascript — multi-threaded window inspection    |

---

## ⚙️ How It Works

### 1. The Detector

Lightweight threads poll active windows and hardware state every 2 seconds to spot active calls without impacting battery life.

### 2. The Scribe

When a meeting starts, audio is captured via AVAudioEngine and converted to 16 kHz mono float32 (Whisper's native format). Every 25 seconds the buffer is passed to WhisperKit for transcription. Results are mapped into an absolute-millisecond timeline ledger keyed by word timestamps — ensuring zero duplication when chunks overlap.

**Catch-up guarantee:** if Whisper takes 5–6 seconds to process a chunk, any audio that arrived during that window is transcribed immediately when the run finishes, not at the next 25-second tick.

**Stop guarantee:** when recording is stopped, the UI responds instantly. Vitroscribe then waits up to 30 seconds for any in-flight transcription to complete, does a final pass on the remaining buffer, and saves — so the last words of every meeting are always captured.

**Hallucination filtering:** Whisper occasionally emits meta-tokens such as `[BLANK_AUDIO]`, `(silence)`, or `[SPEAKING JAPANESE]`. Vitroscribe strips all `[…]` and `(…)` tokens — including split word fragments — before they reach the transcript. Consecutive duplicate words caused by Whisper's repetition loops or overlap boundaries are also removed automatically.

### 3. The History Vault

Sessions are stored with rich metadata — title, duration, start/end times — in a local SQLite database. The sidebar features Global Search (with keyword highlighting), Date Filtering, and per-session duration badges.

### 4. The Stop

Once the meeting window or URL closes, Vitroscribe commits a final transcription pass and shuts down the engine.

---

## 🚀 Getting Started

### Prerequisites

- macOS 14.0+
- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

### Build

```bash
git clone <repo>
cd Vitroscribe
xcodegen generate
open Vitroscribe.xcodeproj
```

Build and run. On first launch, Vitroscribe downloads the Whisper multilingual model (~490 MB) in the background — a one-time operation. A banner in the app shows progress. The model is cached in `~/Library/Application Support/com.nikkipunjabi.Vitroscribe/WhisperModels` and reused on every subsequent launch.

### Audio Setup

Vitroscribe captures from the **System Default Input Device**.

| Use Case                         | Setup                                                                                                                                       |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Capture your own voice           | Built-in mic or headset — works out of the box                                                                                              |
| Capture all meeting participants | Install [BlackHole 2ch](https://existential.audio/blackhole/), route meeting audio through it, and set BlackHole as the system input device |

---

## 🔑 Required Permissions

| Permission       | Purpose                                                |
| ---------------- | ------------------------------------------------------ |
| Microphone       | Audio capture                                          |
| Screen Recording | Auto-detect meeting windows (Google Meet, Zoom, Teams) |
| Calendars        | Show upcoming meetings and auto-start recordings       |

---

## 📜 License

MIT License — Copyright (c) 2026 Nikki Punjabi

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

---

_Built with ❤️ using **Vibecoding**. This project is free for the community._
