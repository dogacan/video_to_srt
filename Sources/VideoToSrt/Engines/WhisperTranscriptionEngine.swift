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

/// A ``TranscriptionEngine`` implementation that uses the OpenAI Whisper model via the `SwiftWhisper` library.
///
/// This engine provides high-accuracy transcription by running local `.bin` models (e.g., `ggml-base.bin`).
///
/// ## Workflow
/// 1. **Model Bootstrapping**: Verifies the existence of the model at the specified path, downloading it if necessary via ``ModelDownloader``.
/// 2. **Audio Extraction**: Uses ``AudioExtractor`` to convert the source media into the specific 16kHz mono PCM format required by Whisper.
/// 3. **Streaming Transcription**: Initializes the Whisper model and processes audio in real-time, yielding results through a shared ``ResultSegmenter`` to ensure consistent SRT formatting.
///
/// This engine is suitable for environments where Apple's native Speech APIs are unavailable or where consistent cross-platform behavior is required.
public struct WhisperTranscriptionEngine: TranscriptionEngine, Sendable {
    private let logger = Logger(subsystem: "com.video_to_srt", category: "WhisperTranscriptionEngine")
    public let modelPath: String
    private let maxLen: Int?

    public init(modelPath: String, maxLen: Int? = nil) {
        self.modelPath = modelPath
        self.maxLen = maxLen
    }

    public func transcribe(fileURL: URL, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionResult, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    // Bootstrap model if missing
                    try await ModelDownloader.downloadIfNeeded(to: modelPath)
                    
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
                    
                    if let maxLen = self.maxLen {
                        logger.info("Setting Whisper max segment length to \(maxLen) characters...")
                        whisper.params.max_len = Int32(maxLen)
                        // max_len works best with token_timestamps enabled
                        whisper.params.token_timestamps = true
                    }
                    
                    // Word boundary splitting is almost always desired when character limits are active
                    whisper.params.split_on_word = true
                    
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
            let duration = (Double(segment.endTime) - Double(segment.startTime)) / 1000.0
            if duration > 7.0 {
                print("⚠️ [DEBUG] Long Whisper segment detected (\(String(format: "%.2f", duration))s): \(segment.text)")
                print("💡 Tip: Try using --whisper-max-len (e.g., --whisper-max-len 60) to force shorter segments.")
            }
            
            let results = segmenter.process(segment: segment)
            for result in results {
                continuation.yield(result)
            }
        }
    }
    
    func whisper(_ aWhisper: Whisper, didUpdateProgress progress: Double) {}
    
    func whisper(_ aWhisper: Whisper, didCompleteWithSegments segments: [Segment]) {}
    
    func whisper(_ aWhisper: Whisper, didErrorWith error: Error) {
        continuation.finish(throwing: error)
    }
}
