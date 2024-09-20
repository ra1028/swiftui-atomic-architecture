import AVFoundation
import os

protocol AudioRecorderProtocol {
    var currentTime: TimeInterval { get }

    func record(url: URL) throws
    func stop()
}

final class AudioRecorder: NSObject, AVAudioRecorderDelegate, AudioRecorderProtocol, @unchecked Sendable {
    private var recorder = OSAllocatedUnfairLock<AVAudioRecorder?>(uncheckedState: nil)
    private let onFail: () -> Void

    init(onFail: @escaping () -> Void) {
        self.onFail = onFail
        super.init()
    }

    var currentTime: TimeInterval {
        recorder.withLock(\.?.currentTime) ?? .zero
    }

    func record(url: URL) throws {
        try recorder.withLock { recorder in
            recorder = try AVAudioRecorder(
                url: url,
                settings: [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ]
            )
            recorder?.delegate = self
            recorder?.record()
        }
    }

    func stop() {
        recorder.withLock { recorder in
            recorder?.stop()
            recorder = nil
        }
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            onFail()
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        onFail()
    }
}

final class MockAudioRecorder: AudioRecorderProtocol, @unchecked Sendable {
    var isRecording = false
    var recordingError: Error?
    var currentTime: TimeInterval = 10

    func record(url: URL) throws {
        if let recordingError = recordingError {
            throw recordingError
        }

        isRecording = true
    }
    func stop() {
        isRecording = false
    }
}
