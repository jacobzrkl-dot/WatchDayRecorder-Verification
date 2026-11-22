import AVFoundation
import Foundation

enum AudioFileValidator {
    /// Decode to a bounded PCM buffer off the UI actor. Opening an AVURLAsset
    /// and reading its duration alone does not validate the entire recording.
    static func decodedDuration(of url: URL) async throws -> TimeInterval {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { () throws -> TimeInterval in
            try Task.checkCancellation()
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let expectedFrames = file.length
            guard expectedFrames > 0, format.sampleRate.isFinite, format.sampleRate > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
                throw AudioValidationError.undecodable
            }
            var decodedFrames: AVAudioFramePosition = 0
            while decodedFrames < expectedFrames {
                try Task.checkCancellation()
                let before = file.framePosition
                let count = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), expectedFrames - decodedFrames))
                try file.read(into: buffer, frameCount: count)
                guard buffer.frameLength > 0, file.framePosition > before else {
                    throw AudioValidationError.undecodable
                }
                decodedFrames += AVAudioFramePosition(buffer.frameLength)
            }
            try Task.checkCancellation()
            guard decodedFrames == expectedFrames else { throw AudioValidationError.undecodable }
            return Double(decodedFrames) / format.sampleRate
        }
        return try await withTaskCancellationHandler {
            let duration = try await worker.value
            try Task.checkCancellation()
            return duration
        } onCancel: {
            worker.cancel()
        }
    }
}

enum AudioValidationError: LocalizedError {
    case undecodable
    var errorDescription: String? { "系统无法完整解码该录音，原文件已保留" }
}
