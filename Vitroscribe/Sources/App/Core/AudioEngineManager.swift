import Foundation
import Speech
import AVFoundation

class AudioEngineManager: NSObject, ObservableObject {
    static let shared = AudioEngineManager()
    
    private let engine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    @Published var currentTranscript: String = ""
    @Published var activeSpeech: String = ""
    @Published var isRecording: Bool = false
    @Published var isManualRecording: Bool = false
    @Published var isAuthorized: Bool = false
    
    private var currentSessionId: String = ""
    private var isIntentionalStop = false
    
    // V11.2 Infinite Timeline Matrix (Absolute Addressing)
    private var timelineLedger: [Int: String] = [:] // Absolute Ms -> Word
    private var sessionStartTime: Date?
    private var currentTaskStartTime: Date?
    private var syncTimer: Timer?
    private var watchdogTimer: Timer?
    
    private var currentMeetingTitle: String?
    private var currentMeetingStartTime: Date?
    private var currentMeetingEndTime: Date?
    
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
    
    override private init() {
        super.init()
        checkPermissions()
    }
    
    func checkPermissions() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                switch authStatus {
                case .authorized:
                    self.isAuthorized = true
                    Logger.shared.log("Speech recognition authorized.")
                case .denied, .restricted, .notDetermined:
                    self.isAuthorized = false
                    Logger.shared.log("Speech recognition not authorized.")
                @unknown default:
                    self.isAuthorized = false
                }
            }
        }
        
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if granted {
                Logger.shared.log("Microphone access granted.")
            } else {
                Logger.shared.log("Microphone access denied.")
            }
        }
    }
    
    func startRecording(manual: Bool = false, title: String? = nil, startTime: Date? = nil, endTime: Date? = nil) {
        guard !isRecording else { return }
        guard isAuthorized else {
            Logger.shared.log("Cannot start recording, not authorized.")
            return
        }
        
        isIntentionalStop = false
        currentSessionId = UUID().uuidString
        currentTranscript = ""
        timelineLedger = [:]
        sessionStartTime = Date()
        activeSpeech = ""
        isRecording = true
        self.isManualRecording = manual
        self.currentMeetingTitle = title
        self.currentMeetingStartTime = startTime
        self.currentMeetingEndTime = endTime
        
        // 5-second database heartbeat (v11.2)
        syncTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.syncLedgerToDatabase()
        }
        
        do {
            let inputNode = engine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { buffer, _ in
                self.recognitionRequest?.append(buffer)
            }
            
            engine.prepare()
            try engine.start()
            Logger.shared.log("Started recording with session ID: \(currentSessionId)")
            
            startRecognitionTask()
            
        } catch {
            Logger.shared.log("Error starting audio engine: \(error.localizedDescription)")
            shutDownEngine()
        }
    }
    
    private func startRecognitionTask() {
        // Watchdog: If a task runs for > 70s without finalizing, force restart it.
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 70.0, repeats: false) { [weak self] _ in
            guard let self = self, self.isRecording && !self.isIntentionalStop else { return }
            Logger.shared.log("Watchdog: Recognition task hung for > 70s. Force restarting...")
            self.recognitionTask?.cancel()
            self.startRecognitionTask()
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            fatalError("Unable to create an SFSpeechAudioBufferRecognitionRequest object")
        }
        
        currentTaskStartTime = Date()
        recognitionRequest.shouldReportPartialResults = true
        
        if #available(macOS 13.0, *) {
            recognitionRequest.requiresOnDeviceRecognition = true
        }
        
        var isTaskFinished = false
        
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            if isTaskFinished { return }
            
            if let error = error {
                Logger.shared.log("Recognition task error: \(error.localizedDescription)")
            }
            
            if let result = result {
                guard let sessionStart = self.sessionStartTime,
                      let taskStart = self.currentTaskStartTime else { 
                    Logger.shared.log("Error: Missing session or task start time.")
                    return 
                }
                
                let taskOffset = taskStart.timeIntervalSince(sessionStart)
                
                // 1. Map every segment into the global Absolute Timeline
                if result.bestTranscription.segments.isEmpty && !result.bestTranscription.formattedString.isEmpty {
                    Logger.shared.log("Warning: Partial result has text but no segments.")
                }

                for segment in result.bestTranscription.segments {
                    let absoluteMs = Int((taskOffset + segment.timestamp) * 1000)
                    self.timelineLedger[absoluteMs] = segment.substring
                }
                
                // 2. Reconstruct from Matrix (Math guarantees zero-duplication)
                let fullText = self.reconstructFromLedger()
                
                DispatchQueue.main.async {
                    self.currentTranscript = fullText
                    self.activeSpeech = result.bestTranscription.formattedString
                }
                
                if result.isFinal {
                    Logger.shared.log("Recognition task finalized. Text length: \(result.bestTranscription.formattedString.count)")
                }
            }
            
            if error != nil || (result?.isFinal ?? false) {
                isTaskFinished = true
                self.watchdogTimer?.invalidate()
                self.watchdogTimer = nil
                self.recognitionRequest = nil
                self.recognitionTask = nil
                
                if !self.isIntentionalStop {
                    Logger.shared.log("Restarting recognition task...")
                    self.startRecognitionTask() // Seamlessly stitch next 60s
                } else {
                    self.shutDownEngine()
                }
            }
        }
        
        if recognitionTask == nil {
            Logger.shared.log("Failed to create recognition task. Speech recognizer might be unavailable.")
            // Try to recover after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                if self?.isRecording == true && !self!.isIntentionalStop {
                    self?.startRecognitionTask()
                }
            }
        }
    }
    
    private func reconstructFromLedger() -> String {
        let sortedKeys = timelineLedger.keys.sorted()
        var text = ""
        var lastMs: Int = -1
        
        for ms in sortedKeys {
            guard let word = timelineLedger[ms] else { continue }
            
            // Auto-Paragraphs for gaps > 2s
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
        if !text.isEmpty {
            DatabaseManager.shared.saveOrUpdateSession(
                sessionId: currentSessionId,
                text: text,
                title: currentMeetingTitle,
                startTime: currentMeetingStartTime,
                endTime: currentMeetingEndTime
            )
        }
    }
    
    private func solidifyActiveSpeech() {
        // Obsolete in v11.1 Matrix architecture
    }
    
    func stopRecording() {
        guard isRecording else { return }
        isIntentionalStop = true
        recognitionRequest?.endAudio()
        shutDownEngine()
    }
    
    private func shutDownEngine() {
        guard isRecording else { return }
        isRecording = false
        isManualRecording = false
        activeSpeech = ""
        
        syncTimer?.invalidate()
        syncTimer = nil
        
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        
        syncLedgerToDatabase()
        Logger.shared.log("Stopped recording session ID: \(currentSessionId)")
    }
}
