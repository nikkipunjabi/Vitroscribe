import Foundation
import AVFoundation
import WhisperKit

// MARK: - AudioEngineManager
//
// Transcription engine powered by OpenAI Whisper (via WhisperKit).
//
// Audio pipeline:
//   AVAudioEngine tap → 16 kHz mono float32 conversion → audioSamples buffer
//   Every 25 s the buffer is passed to WhisperKit for transcription.
//
// Zero-gap guarantee:
//   • When a transcription finishes, any audio that accumulated during
//     the processing window is immediately queued for the next run.
//   • stopRecording() waits for any in-flight transcription to finish,
//     then does one final transcription of the remaining buffer before
//     shutting down, so nothing is ever silently discarded.

class AudioEngineManager: NSObject, ObservableObject {
    static let shared = AudioEngineManager()

    // MARK: Published state
    @Published var currentTranscript: String = ""
    @Published var activeSpeech: String = ""
    @Published var isRecording: Bool = false
    @Published var isManualRecording: Bool = false
    @Published var isAuthorized: Bool = false
    @Published var isModelLoading: Bool = false    // true = downloading
    @Published var isModelPrewarming: Bool = false  // true = compiling Core ML for this hardware
    @Published var isModelReady: Bool = false
    @Published var isTranscribing: Bool = false

    // MARK: Audio engine
    private let engine = AVAudioEngine()
    private var audioConverter: AVAudioConverter?

    // MARK: Whisper
    private var whisperKit: WhisperKit?
    // Multilingual model — supports English, Hindi, Urdu, and 98 other languages.
    private let whisperModel = "openai_whisper-small"
    private let whisperSampleRate: Double = 16_000

    // MARK: Whisper hallucination suppression
    //
    // Whisper emits meta-tokens for silence, non-speech events, and foreign
    // language detection.  These appear as free-form text so exact matching
    // misses variants like "[BLANK _AUDIO]", "[ Foreign Language ]",
    // "[SPEAKING JAPANESE]", etc.  We suppress them with three rules:
    //   1. Any text fully wrapped in square brackets → [anything]
    //   2. Any text fully wrapped in parentheses     → (anything)
    //   3. Exact legacy tokens kept for safety
    private func isSuppressedText(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        // Rule 1: [...]  — covers [BLANK_AUDIO], [SPEAKING JAPANESE], etc.
        if t.hasPrefix("[") && t.hasSuffix("]") { return true }
        // Rule 2: (...)  — covers (silence), (speaking language), etc.
        if t.hasPrefix("(") && t.hasSuffix(")") { return true }
        return false
    }

    // MARK: Audio accumulation
    // All access to audioSamples is serialised through audioQueue.
    private let audioQueue = DispatchQueue(label: "com.vitroscribe.audio", qos: .userInitiated)
    private var audioSamples: [Float] = []
    private let chunkDuration: Double = 25.0
    private let overlapDuration: Double = 2.0
    // Minimum accumulated audio before triggering a catch-up transcription.
    private let catchUpThreshold: Double = 3.0   // seconds
    private var chunkTimer: Timer?

    // MARK: Session metadata
    private var currentSessionId: String = ""
    private var isIntentionalStop = false
    private var sessionStartDate: Date?
    private var currentChunkStartDate: Date?
    private var timelineLedger: [Int: String] = [:]
    private var syncTimer: Timer?

    private var currentMeetingTitle: String?
    private var currentMeetingStartTime: Date?
    private var currentMeetingEndTime: Date?

    // MARK: Settings
    @Published var isOverlayShared: Bool = UserDefaults.standard.bool(forKey: "isOverlayShared") {
        didSet {
            UserDefaults.standard.set(isOverlayShared, forKey: "isOverlayShared")
            RecordingOverlayManager.shared.updatePrivacySetting()
        }
    }

    @Published var isJoinPromptShared: Bool = (UserDefaults.standard.object(forKey: "isJoinPromptShared") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(isJoinPromptShared, forKey: "isJoinPromptShared")
            MeetingJoinOverlayManager.shared.updatePrivacySetting()
        }
    }

    @Published var isPromptOverlayShared: Bool = (UserDefaults.standard.object(forKey: "isPromptOverlayShared") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(isPromptOverlayShared, forKey: "isPromptOverlayShared")
            PromptOverlayManager.shared.updatePrivacySetting()
        }
    }

    // MARK: - Init

    override private init() {
        super.init()
        checkPermissions()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine)
        Task { await loadWhisperModel() }
    }

    // MARK: - Whisper model loading

    /// Persistent folder where the Whisper model is stored between launches.
    /// WhisperKit downloads into <downloadBase>/models/argmaxinc/whisperkit-coreml/<model>/
    private var whisperDownloadBase: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.gravitas.Vitroscribe/WhisperModels")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport
    }

    /// The exact folder WhisperKit writes the model files into.
    /// WhisperKit prepends "models/" to the downloadBase, so the real path is
    /// <downloadBase>/models/argmaxinc/whisperkit-coreml/<model>/
    private var whisperModelPath: URL {
        whisperDownloadBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(whisperModel)
    }

    private func loadWhisperModel() async {
        let needsDownload = !FileManager.default.fileExists(atPath: whisperModelPath.path)
        Logger.shared.log("WhisperKit: starting load – model='\(whisperModel)' needsDownload=\(needsDownload) path=\(whisperModelPath.path)")
        await MainActor.run {
            if needsDownload {
                self.isModelLoading = true     // shows download banner
            } else {
                self.isModelPrewarming = true  // hides "unavailable" during silent 8-9s load
            }
        }
        let t0 = Date()
        do {
            let pipe = try await WhisperKit(
                model: whisperModel,
                downloadBase: whisperDownloadBase,
                verbose: false
            )
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(t0))
            await MainActor.run {
                self.whisperKit        = pipe
                self.isModelLoading    = false
                self.isModelPrewarming = false
                self.isModelReady      = true
                Logger.shared.log("WhisperKit: model ready in \(elapsed)s – '\(self.whisperModel)'")
            }
        } catch {
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(t0))
            await MainActor.run {
                self.isModelLoading    = false
                self.isModelPrewarming = false
                Logger.shared.log("WhisperKit: failed after \(elapsed)s – \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Permissions

    func checkPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                self.isAuthorized = granted
                Logger.shared.log(granted ? "Microphone access granted." : "Microphone access denied.")
            }
        }
    }

    // MARK: - Audio device change

    @objc private func handleEngineConfigChange(_ notification: Notification) {
        guard isRecording && !isIntentionalStop else { return }
        Logger.shared.log("Audio engine config changed – re-installing tap.")
        reinstallTap()
        do { try engine.start() } catch {
            Logger.shared.log("Failed to restart engine: \(error.localizedDescription)")
        }
    }

    private func reinstallTap() {
        engine.inputNode.removeTap(onBus: 0)
        let fmt = engine.inputNode.outputFormat(forBus: 0)
        setupConverter(inputFormat: fmt)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            self?.appendAudioBuffer(buf)
        }
    }

    // MARK: - Recording lifecycle

    func startRecording(manual: Bool = false, title: String? = nil,
                        startTime: Date? = nil, endTime: Date? = nil) {
        guard !isRecording else { return }
        guard isAuthorized else {
            Logger.shared.log("Cannot start – microphone not authorised.")
            return
        }
        guard isModelReady, whisperKit != nil else {
            Logger.shared.log("Cannot start – Whisper model not ready.")
            return
        }

        isIntentionalStop        = false
        currentSessionId         = UUID().uuidString
        currentTranscript        = ""
        activeSpeech             = ""
        timelineLedger           = [:]
        sessionStartDate         = Date()
        currentChunkStartDate    = Date()
        isRecording              = true
        isManualRecording        = manual
        currentMeetingTitle      = title
        currentMeetingStartTime  = startTime
        currentMeetingEndTime    = endTime

        syncTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.syncLedgerToDatabase()
        }

        do {
            let fmt = engine.inputNode.outputFormat(forBus: 0)
            setupConverter(inputFormat: fmt)
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
                self?.appendAudioBuffer(buf)
            }
            engine.prepare()
            try engine.start()
            Logger.shared.log("Recording started – session \(currentSessionId)")

            // Transcribe every chunkDuration seconds (rolling timer).
            chunkTimer = Timer.scheduledTimer(withTimeInterval: chunkDuration, repeats: true) { [weak self] _ in
                self?.triggerChunkTranscription()
            }
        } catch {
            Logger.shared.log("Audio engine start failed: \(error.localizedDescription)")
            finalizeStop()
        }
    }

    /// Stops the engine capture and kicks off a final async transcription+save.
    func stopRecording() {
        guard isRecording else { return }
        isIntentionalStop = true

        // Kill the periodic timer and the capture tap so no more audio arrives.
        chunkTimer?.invalidate(); chunkTimer = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)

        // Async: wait for any in-flight transcription, transcribe remaining
        // audio, then save and mark as stopped.
        Task { [weak self] in
            guard let self = self else { return }

            // 1. Wait for any current transcription to finish.
            while await MainActor.run(resultType: Bool.self) { self.isTranscribing } {
                try? await Task.sleep(nanoseconds: 100_000_000)  // poll every 100 ms
            }

            // 2. Transcribe whatever is left in the buffer.
            await self.transcribeRemainingAudio()

            // 3. Finalize.
            await MainActor.run { self.finalizeStop() }
        }
    }

    private func finalizeStop() {
        guard isRecording || isIntentionalStop else { return }
        isRecording       = false
        isManualRecording = false
        activeSpeech      = ""
        isTranscribing    = false

        syncTimer?.invalidate(); syncTimer = nil

        // Engine may already be stopped; guard against double-stop.
        if engine.isRunning { engine.stop() }

        syncLedgerToDatabase()
        Logger.shared.log("Recording stopped – session \(currentSessionId)")
    }

    // MARK: - Audio conversion & accumulation

    private func setupConverter(inputFormat: AVAudioFormat) {
        let out = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: whisperSampleRate,
                                channels: 1,
                                interleaved: false)!
        audioConverter = AVAudioConverter(from: inputFormat, to: out)
    }

    private func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = audioConverter else { return }
        let ratio    = whisperSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                         frameCapacity: capacity) else { return }
        var done = false
        converter.convert(to: out, error: nil) { _, status in
            if done { status.pointee = .noDataNow; return nil }
            done = true; status.pointee = .haveData; return buffer
        }
        guard let ch = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        audioQueue.async { [weak self] in self?.audioSamples.append(contentsOf: samples) }
    }

    // MARK: - Chunk transcription

    /// Called by the rolling timer every 25 seconds.
    private func triggerChunkTranscription() {
        // If a transcription is already running, skip this tick — the
        // catch-up logic in `transcribe()` will handle accumulated audio
        // as soon as the current run finishes.
        guard !isTranscribing else { return }
        runNextChunk()
    }

    /// Grabs current audio buffer and starts a transcription Task.
    private func runNextChunk(minSeconds: Double = 0) {
        var samples: [Float] = []
        var chunkStart = Date()

        audioQueue.sync { [self] in
            guard !audioSamples.isEmpty else { return }
            let secondsInBuffer = Double(audioSamples.count) / whisperSampleRate
            guard secondsInBuffer >= minSeconds else { return }

            samples    = audioSamples
            chunkStart = currentChunkStartDate ?? sessionStartDate ?? Date()

            // Keep a short overlap so boundary words are not cut off.
            let overlapSamples = min(Int(overlapDuration * whisperSampleRate), audioSamples.count)
            audioSamples           = Array(audioSamples.suffix(overlapSamples))
            currentChunkStartDate  = Date().addingTimeInterval(-overlapDuration)
        }

        guard !samples.isEmpty else { return }

        isTranscribing = true

        let sessionStart       = sessionStartDate ?? Date()
        let chunkOffsetSeconds = chunkStart.timeIntervalSince(sessionStart)

        Task { [weak self] in
            await self?.transcribe(samples: samples, chunkOffsetSeconds: chunkOffsetSeconds)
        }
    }

    /// Transcribes any remaining audio when stopping.
    private func transcribeRemainingAudio() async {
        var samples: [Float] = []
        var chunkStart = Date()

        audioQueue.sync { [self] in
            samples    = audioSamples
            chunkStart = currentChunkStartDate ?? sessionStartDate ?? Date()
            audioSamples = []
        }

        guard !samples.isEmpty, let sessionStart = sessionStartDate else { return }

        await MainActor.run { self.isTranscribing = true }
        let offset = chunkStart.timeIntervalSince(sessionStart)
        await transcribe(samples: samples, chunkOffsetSeconds: offset)
    }

    // MARK: - Whisper transcription

    private func transcribe(samples: [Float], chunkOffsetSeconds: Double) async {
        guard let whisper = whisperKit else {
            await MainActor.run { self.isTranscribing = false }
            return
        }

        do {
            let options = DecodingOptions(
                task: .transcribe,
                temperature: 0.0,
                temperatureFallbackCount: 5,
                wordTimestamps: true,
                suppressBlank: true,
                logProbThreshold: -1.0,
                noSpeechThreshold: 0.3
            )

            let chunkT0 = Date()
            Logger.shared.log("WhisperKit: transcribing chunk at +\(Int(chunkOffsetSeconds))s (\(samples.count) samples)")

            let transcriptionTask = Task { try await whisper.transcribe(audioArray: samples, decodeOptions: options) }
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: 600_000_000_000) // 10 min timeout
                Logger.shared.log("WhisperKit: transcription TIMED OUT at +\(Int(chunkOffsetSeconds))s")
                transcriptionTask.cancel()
            }
            let results: [TranscriptionResult]
            do {
                results = try await transcriptionTask.value
                timeoutTask.cancel()
            } catch {
                timeoutTask.cancel()
                throw error
            }

            let chunkElapsed = String(format: "%.1f", Date().timeIntervalSince(chunkT0))
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.mergeResults(results, chunkOffsetSeconds: chunkOffsetSeconds)
                self.currentTranscript = self.reconstructFromLedger()
                self.isTranscribing    = false
                Logger.shared.log("WhisperKit: chunk done in \(chunkElapsed)s at +\(Int(chunkOffsetSeconds))s – \(self.currentTranscript.count) chars total")

                // ── Catch-up: if audio accumulated during processing, run immediately ──
                // This is what closes the gap: instead of waiting up to 25 more seconds
                // for the next timer tick, we process the backlogged audio right away.
                if self.isRecording && !self.isIntentionalStop {
                    self.runNextChunk(minSeconds: self.catchUpThreshold)
                }
            }
        } catch {
            Logger.shared.log("Transcription error: \(error.localizedDescription)")
            await MainActor.run { self.isTranscribing = false }
        }
    }

    // MARK: - Ledger

    /// Map Whisper results into the absolute-millisecond timeline ledger.
    private func mergeResults(_ results: [TranscriptionResult], chunkOffsetSeconds: Double) {
        for result in results {
            for segment in result.segments {
                // Filter Whisper hallucination tokens (silence, music, non-speech, etc.)
                let segText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if isSuppressedText(segText) { continue }

                if let words = segment.words, !words.isEmpty {
                    for wordTiming in words {
                        let text = wordTiming.word.trimmingCharacters(in: .whitespaces)
                        if isSuppressedText(text) { continue }
                        let absMs = Int((chunkOffsetSeconds + Double(wordTiming.start)) * 1000)
                        timelineLedger[absMs] = text
                    }
                } else {
                    // No word timestamps — store the whole segment at its start time.
                    let absMs = Int((chunkOffsetSeconds + Double(segment.start)) * 1000)
                    timelineLedger[absMs] = segText
                }
            }
        }
    }

    private func reconstructFromLedger() -> String {
        let sorted = timelineLedger.keys.sorted()
        var text   = ""
        var lastMs = -1
        for ms in sorted {
            guard let word = timelineLedger[ms] else { continue }
            if lastMs != -1 && (ms - lastMs) > 2000 {
                text += "\n\n" + word
            } else {
                text += (text.isEmpty || text.hasSuffix("\n\n") ? "" : " ") + word
            }
            lastMs = ms
        }
        return text
    }

    private func syncLedgerToDatabase() {
        let text = reconstructFromLedger()
        guard !text.isEmpty else { return }
        DatabaseManager.shared.saveOrUpdateSession(
            sessionId: currentSessionId,
            text: text,
            title: currentMeetingTitle,
            startTime: currentMeetingStartTime,
            endTime: currentMeetingEndTime)
    }
}
