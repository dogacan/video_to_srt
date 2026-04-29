import Foundation
import SwiftWhisper
import os

public enum WhisperTranscriptionError: Error, LocalizedError {
    case missingModelPath
    case modelNotFound(String)
    case transcriptionFailed(Error)
    
    public var errorDescription: String? {
        switch self {
        case .missingModelPath:
            return "A model path is required for the Whisper engine. Use --whisper-model-path."
        case .modelNotFound(let path):
            return "Whisper model not found at path: \(path)"
        case .transcriptionFailed(let error):
            return "Whisper transcription failed: \(error.localizedDescription)"
        }
    }
}

public struct WhisperTranscriptionEngine: TranscriptionEngine, Sendable {
    private let logger = Logger(subsystem: "com.video_to_srt", category: "WhisperTranscriptionEngine")

    public init() {}

    public func transcribe(fileURL: URL, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionResult, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let modelPath = options.whisperModelPath else {
                        throw WhisperTranscriptionError.missingModelPath
                    }
                    
                    let modelURL = URL(fileURLWithPath: modelPath)
                    guard FileManager.default.fileExists(atPath: modelURL.path) else {
                        throw WhisperTranscriptionError.modelNotFound(modelPath)
                    }

                    logger.info("Extracting and converting audio to 16kHz PCM for Whisper...")
                    let frames = try AudioExtractor.extractAudioForWhisper(from: fileURL, ffmpegPath: options.ffmpegPath)
                    
                    logger.info("Initializing Whisper with model...")
                    let whisper = Whisper(fromFileURL: modelURL)
                    
                    if let languageCode = options.locale?.language.languageCode?.identifier,
                       let language = WhisperLanguage(rawValue: languageCode) {
                        logger.info("Setting Whisper language to \(languageCode)...")
                        whisper.params.language = language
                    }
                    
                    let totalDuration = Double(frames.count) / 16000.0
                    let delegate = WhisperStreamDelegate(
                        continuation: continuation,
                        totalDuration: totalDuration,
                        offset: options.subtitleOffsetSeconds
                    )
                    whisper.delegate = delegate
                    
                    logger.info("Starting Whisper transcription...")
                    // We do not await the result array, we just await the process, and the delegate yields.
                    _ = try await whisper.transcribe(audioFrames: frames)
                    
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: WhisperTranscriptionError.transcriptionFailed(error))
                }
            }
        }
    }
}

private class WhisperStreamDelegate: WhisperDelegate, @unchecked Sendable {
    let continuation: AsyncThrowingStream<TranscriptionResult, Error>.Continuation
    let totalDuration: Double
    let offset: Double
    var currentIndex = 1

    init(continuation: AsyncThrowingStream<TranscriptionResult, Error>.Continuation, totalDuration: Double, offset: Double) {
        self.continuation = continuation
        self.totalDuration = totalDuration
        self.offset = offset
    }

    func whisper(_ aWhisper: Whisper, didProcessNewSegments segments: [Segment], atIndex index: Int) {
        for segment in segments {
            // SwiftWhisper Segment has startTime and endTime in 10ms steps
            let startSecs = (Double(segment.startTime) / 1000.0) + self.offset
            let endSecs = (Double(segment.endTime) / 1000.0) + self.offset
            
            let srtSegment = SRTSegment(text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                        startSeconds: startSecs,
                                        endSeconds: endSecs)
            
            let formatted = SRTFormatter.format(srtSegment, index: self.currentIndex)
            self.currentIndex += 1
            
            let progress = totalDuration > 0 ? min(1.0, endSecs / totalDuration) : 0.0
            continuation.yield(TranscriptionResult(srtText: formatted, progress: progress))
        }
    }
    
    func whisper(_ aWhisper: Whisper, didUpdateProgress progress: Double) {}
    
    func whisper(_ aWhisper: Whisper, didCompleteWithSegments segments: [Segment]) {}
    
    func whisper(_ aWhisper: Whisper, didErrorWith error: Error) {}
}
