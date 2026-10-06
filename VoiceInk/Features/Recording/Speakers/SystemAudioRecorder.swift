import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Records system output audio (e.g. Teams remote participants) to a WAV file.
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let shared = SystemAudioRecorder()

    private let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.systemAudio")
    private var stream: SCStream?
    private var file: AVAudioFile?
    private var outputURL: URL?
    private var firstBufferDate: Date?

    enum CaptureError: Error { case permissionDenied, noDisplay }

    func start(to url: URL) async throws {
        var allowed = CGPreflightScreenCaptureAccess()
        if !allowed { allowed = await ScreenCaptureService.requestScreenCapturePermissionRegistration() }
        guard allowed else { throw CaptureError.permissionDenied }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)

        queue.sync {
            self.outputURL = url
            self.file = nil
            self.firstBufferDate = nil
        }
        try await stream.startCapture()
        self.stream = stream
    }

    /// Stops capture. Returns the date of the first audio buffer, or nil if nothing was captured.
    func stop() async -> Date? {
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        return queue.sync {
            file = nil
            let date = firstBufferDate
            firstBufferDate = nil
            return date
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let outputURL else { return }
        guard let format = sampleBuffer.formatDescription.flatMap({ AVAudioFormat(cmAudioFormatDescription: $0) }),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer)))
        else { return }
        buffer.frameLength = buffer.frameCapacity
        guard
            CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer, at: 0, frameCount: Int32(buffer.frameLength), into: buffer.mutableAudioBufferList) == noErr
        else { return }

        do {
            if file == nil {
                file = try AVAudioFile(
                    forWriting: outputURL,
                    settings: [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: format.sampleRate,
                        AVNumberOfChannelsKey: format.channelCount,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false,
                    ],
                    commonFormat: format.commonFormat,
                    interleaved: format.isInterleaved)
                firstBufferDate = Date()
            }
            try file?.write(from: buffer)
        } catch {
            file = nil
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {}
}
