import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

// MARK: - SystemAudioCapture
//
// Taps system audio output via ScreenCaptureKit (macOS 14+).
// Delivers 16 kHz mono Float32 samples via `onSamples` — ready to
// feed into the same audioSamples queue the mic tap uses.
//
// Strategy: tell SCStream to output mono audio, then extract the raw
// Float32 frames directly from the CMSampleBuffer and downsample with
// a simple polyphase-style linear interpolation to 16 kHz.

@available(macOS 14.0, *)
class SystemAudioCapture: NSObject {

    static let shared = SystemAudioCapture()

    /// Called on an internal serial queue with 16 kHz mono Float32 samples.
    var onSamples: (([Float]) -> Void)?

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.vitroscribe.sysaudio", qos: .userInitiated)
    private let targetSampleRate: Double = 16_000

    private override init() { super.init() }

    // MARK: - Start

    func start() async throws {
        guard stream == nil else { return }

        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                           onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display,
                                     excludingApplications: [],
                                     exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio               = true
        config.excludesCurrentProcessAudio = true
        config.channelCount                = 1      // mono — one buffer, no mixing needed
        config.sampleRate                  = 48_000 // standard hardware rate
        // Minimise video overhead — we only need audio.
        config.width                 = 2
        config.height                = 2
        config.minimumFrameInterval  = CMTime(value: 1, timescale: 1)
        config.queueDepth            = 5

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
        Logger.shared.log("SystemAudioCapture: started.")
    }

    // MARK: - Stop

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        Logger.shared.log("SystemAudioCapture: stopped.")
    }

    // MARK: - Errors

    enum CaptureError: Error {
        case noDisplay
    }
}

// MARK: - SCStreamOutput

@available(macOS 14.0, *)
extension SystemAudioCapture: SCStreamOutput {

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let samples = extractAndDownsample(sampleBuffer) else { return }
        onSamples?(samples)
    }

    /// Extracts mono Float32 samples from the CMSampleBuffer and
    /// downsamples from 48 kHz → 16 kHz via linear interpolation.
    private func extractAndDownsample(_ sampleBuffer: CMSampleBuffer) -> [Float]? {
        let frameCount = sampleBuffer.numSamples
        guard frameCount > 0 else { return nil }

        // Determine the actual sample rate reported by the buffer.
        guard let fmtDesc = sampleBuffer.formatDescription else { return nil }
        let nativeRate = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)!.pointee.mSampleRate
        guard nativeRate > 0 else { return nil }

        // Get the required AudioBufferList allocation size.
        var ablSizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &ablSizeNeeded,
            bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: nil)
        guard ablSizeNeeded > 0 else { return nil }

        // Allocate and populate the AudioBufferList.
        let ablRaw = UnsafeMutableRawPointer.allocate(
            byteCount: ablSizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablRaw.deallocate() }
        let ablPtr = ablRaw.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        let fillStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr, bufferListSize: ablSizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &blockBuffer)
        guard fillStatus == noErr else { return nil }

        // SCStream with channelCount=1 gives us exactly one buffer of Float32.
        // mBuffers is the first (and only) element of the trailing C array.
        let firstBuffer = ablPtr.pointee.mBuffers
        guard let rawData = firstBuffer.mData, firstBuffer.mDataByteSize > 0 else { return nil }

        let nativeCount = Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size
        guard nativeCount > 0 else { return nil }
        let nativePtr = rawData.bindMemory(to: Float.self, capacity: nativeCount)

        // Downsample to 16 kHz via linear interpolation.
        if nativeRate == targetSampleRate {
            return Array(UnsafeBufferPointer(start: nativePtr, count: nativeCount))
        }

        let ratio = nativeRate / targetSampleRate            // e.g. 3.0 for 48k→16k
        let outputCount = Int(Double(nativeCount) / ratio)
        guard outputCount > 0 else { return nil }

        var output = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let srcPos = Double(i) * ratio
            let lo     = Int(srcPos)
            let hi     = min(lo + 1, nativeCount - 1)
            let frac   = Float(srcPos - Double(lo))
            output[i]  = nativePtr[lo] * (1 - frac) + nativePtr[hi] * frac
        }
        return output
    }
}

// MARK: - SCStreamDelegate

@available(macOS 14.0, *)
extension SystemAudioCapture: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Logger.shared.log("SystemAudioCapture: stream stopped with error — \(error.localizedDescription)")
        self.stream = nil
    }
}
