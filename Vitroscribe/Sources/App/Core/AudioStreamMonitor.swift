import Foundation
import CoreAudio

class AudioStreamMonitor: ObservableObject {
    static let shared = AudioStreamMonitor()
    
    @Published var isAudioFlowing: Bool = false
    
    private var timer: Timer?
    
    private init() {
        startMonitoring()
    }
    
    func startMonitoring() {
        // Poll every 2 seconds for audio device activity
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkAudioActivity()
        }
    }
    
    private func checkAudioActivity() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        
        if status != noErr {
            return
        }
        
        // Check if anything is actively capturing from the mic (input scope only).
        // Using ScopeGlobal would also return true when audio is merely playing
        // through the same device (e.g. AirPods/headset), causing YouTube playback
        // to be mistaken for an active meeting.
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var isRunning: UInt32 = 0
        var isRunningSize = UInt32(MemoryLayout<UInt32>.size)
        
        let runningStatus = AudioObjectGetPropertyData(deviceID, &runningAddress, 0, nil, &isRunningSize, &isRunning)
        
        DispatchQueue.main.async {
            self.isAudioFlowing = (runningStatus == noErr && isRunning != 0)
        }
    }
}
