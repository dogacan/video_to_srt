import Foundation
import SwiftWhisper
import os

extension Segment: TranscriptionSegment {
    public var transcriptionText: String { self.text }
    public var transcriptionStartTime: Double { Double(self.startTime) / 1000.0 }
    public var transcriptionEndTime: Double { Double(self.endTime) / 1000.0 }
}

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
    public let modelPath: String

    public init(modelPath: String) {
        self.modelPath = modelPath
    }

    public func transcribe(fileURL: URL, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionResult, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let modelURL = URL(fileURLWithPath: modelPath)
                    guard FileManager.default.fileExists(atPath: modelURL.path) else {
                        throw WhisperTranscriptionError.modelNotFound(modelPath)
                    }

                    logger.info("Extracting and converting audio to 16kHz PCM for Whisper...")
                    let frames = try await AudioExtractor.extractAudioForWhisper(from: fileURL, ffmpegPath: options.ffmpegPath)
                    
                    logger.info("Initializing Whisper with model...")
                    let whisper = Whisper(fromFileURL: modelURL)
                    
                    if let languageCode = options.locale?.language.languageCode?.identifier,
                       let language = WhisperLanguage(rawValue: languageCode) {
                        logger.info("Setting Whisper language to \(languageCode)...")
                        whisper.params.language = language
                    }
                    
                    let totalDuration = Double(frames.count) / 16000.0
                    let segmenter = ResultSegmenter(
                        offset: options.subtitleOffsetSeconds,
                        totalDuration: totalDuration
                    )
                    let delegate = WhisperStreamDelegate(
                        continuation: continuation,
                        segmenter: segmenter
                    )
                    whisper.delegate = delegate
                    
                    logger.info("Starting Whisper transcription...")
                    // We do not await the result array, we just await the process, and the delegate yields.
                    _ = try await whisper.transcribe(audioFrames: frames)
                    
                    if let finalResult = delegate.segmenter.flush() {
                        continuation.yield(finalResult)
                    }
                    
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
    var segmenter: ResultSegmenter

    init(continuation: AsyncThrowingStream<TranscriptionResult, Error>.Continuation, segmenter: ResultSegmenter) {
        self.continuation = continuation
        self.segmenter = segmenter
    }

    func whisper(_ aWhisper: Whisper, didProcessNewSegments segments: [Segment], atIndex index: Int) {
        for segment in segments {
            if let result = segmenter.process(segment: segment) {
                continuation.yield(result)
            }
        }
    }
    
    func whisper(_ aWhisper: Whisper, didUpdateProgress progress: Double) {}
    
    func whisper(_ aWhisper: Whisper, didCompleteWithSegments segments: [Segment]) {}
    
    func whisper(_ aWhisper: Whisper, didErrorWith error: Error) {}
}
