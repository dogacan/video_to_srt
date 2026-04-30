import Foundation
import WhisperCore
import os

extension WhisperSegment: TranscriptionSegment {
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

/// A ``TranscriptionEngine`` implementation that uses the OpenAI Whisper model via a local `WhisperCore` wrapper around `whisper.cpp`.
///
/// This engine provides high-accuracy transcription by running local `.bin` models (e.g., `ggml-base.bin`).
///
/// ## Workflow
/// 1. **Model Bootstrapping**: Verifies the existence of the model at the specified path, downloading it if necessary via ``ModelDownloader``.
/// 2. **Audio Extraction**: Uses ``AudioExtractor`` to convert the source media into the specific 16kHz mono PCM format required by Whisper.
/// 3. **Streaming Transcription**: Initializes the Whisper model and processes audio in real-time, yielding results through a shared ``ResultSegmenter`` to ensure consistent SRT formatting.
public struct WhisperTranscriptionEngine: TranscriptionEngine, Sendable {
    private let logger = Logger(subsystem: "com.video_to_srt", category: "WhisperTranscriptionEngine")
    public let modelPath: String
    private let maxLen: Int?
    private let shouldDownloadIfMissing: Bool

    public init(modelPath: String? = nil, maxLen: Int? = nil) {
        if let providedPath = modelPath, !providedPath.isEmpty {
            self.modelPath = providedPath
            self.shouldDownloadIfMissing = false
        } else {
            self.modelPath = "models/ggml-base.bin"
            self.shouldDownloadIfMissing = true
        }
        self.maxLen = maxLen
    }

    public func transcribe(fileURL: URL, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionResult, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    // Bootstrap model if missing and we are using the default path
                    if shouldDownloadIfMissing {
                        try await ModelDownloader.downloadIfNeeded(to: modelPath)
                    }
                    
                    let modelURL = URL(fileURLWithPath: modelPath)
                    guard FileManager.default.fileExists(atPath: modelURL.path) else {
                        throw WhisperTranscriptionError.modelNotFound(modelPath)
                    }

                    logger.info("Extracting and converting audio to 16kHz PCM for Whisper...")
                    let frames = try await AudioExtractor.extractAudioForWhisper(from: fileURL, ffmpegPath: options.ffmpegPath)
                    
                    logger.info("Initializing Whisper with model...")
                    let whisper = try WhisperContext(modelPath: modelURL.path)
                    
                    var params = WhisperParams()
                    params.suppressNST = true
                    params.threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount))

                    if let languageCode = options.locale?.language.languageCode?.identifier {
                        logger.info("Setting Whisper language to \(languageCode)...")
                        params.language = languageCode
                    }
                    
                    if let maxLen = self.maxLen {
                        logger.info("Setting Whisper max segment length to \(maxLen) characters...")
                        params.maxLen = Int32(maxLen)
                        // maxLen works best with tokenTimestamps enabled
                        params.tokenTimestamps = true
                    }
                    
                    // Word boundary splitting is almost always desired when character limits are active
                    params.splitOnWord = true
                    
                    let totalDuration = Double(frames.count) / 16000.0
                    let segmenter = ResultSegmenter(
                        offset: options.subtitleOffsetSeconds,
                        totalDuration: totalDuration
                    )
                    
                    logger.info("Starting Whisper transcription...")
                    
                    _ = try await whisper.transcribe(audio: frames, params: params) { newSegments in
                        for segment in newSegments {
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
                    
                    if let finalResult = segmenter.flush() {
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
