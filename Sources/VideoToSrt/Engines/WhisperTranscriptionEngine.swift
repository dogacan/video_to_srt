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
                var whisper: WhisperContext? = nil
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
                    whisper = try WhisperContext(modelPath: modelURL.path)

                    
                    var params = WhisperParams()
                    params.suppressNST = true
                    params.threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount))
                    
                    // Break hallucination feedback loops: don't use previous output
                    // as a prompt for the next segment. This is the single most
                    // effective setting against the "repeating phrase" problem.
                    params.noContext = true

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
                    
                    // Repetition filter — detects and suppresses hallucination loops.
                    // Wrapped in a class because the callback is @Sendable, but
                    // whisper_full calls it synchronously so this is safe.
                    let repeatFilter = RepetitionFilter(maxCycleLen: 6, minCycleRepetitions: 2)
                    
                    logger.info("Starting Whisper transcription...")
                    
                    _ = try await whisper!.transcribe(audio: frames, params: params) { newSegments in
                        for segment in newSegments {
                            let plain = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !plain.isEmpty else { continue }
                            
                            // Skip hallucinated repeats
                            guard repeatFilter.shouldKeep(plain) else { continue }
                            
                            // Diagnostic flag for long segments
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
                    
                    whisper?.free()
                    continuation.finish()
                } catch {
                    whisper?.free()
                    continuation.finish(throwing: WhisperTranscriptionError.transcriptionFailed(error))
                }
            }
        }
    }
}

/// Detects repeating cycles in Whisper output and suppresses hallucination loops.
///
/// Whisper hallucinations often manifest as repeating sequences of varying length:
/// - Single: "A, A, A, A, ..."
/// - Pair:   "A, B, A, B, A, B, ..."
/// - Triple: "A, B, C, A, B, C, ..."
///
/// The filter works in two modes:
/// 1. **Detection mode**: Accumulates segments and checks if the tail forms a repeating cycle.
///    Once detected, it enters suppression mode.
/// 2. **Suppression mode**: Rejects all segments that continue to match the detected cycle
///    pattern. Exits suppression only when new, non-matching text appears.
///
/// Marked `@unchecked Sendable` because `whisper_full` invokes its callback
/// synchronously on a single thread, so concurrent access cannot occur.
private final class RepetitionFilter: @unchecked Sendable {
    private var history: [String] = []
    private let maxCycleLen: Int
    private let minCycleRepetitions: Int
    
    // Suppression state
    private var activeCycle: [String]? = nil
    private var cyclePosition: Int = 0
    
    /// - Parameters:
    ///   - maxCycleLen: Maximum cycle length to check (e.g., 3 catches A, A-B, A-B-C patterns).
    ///   - minCycleRepetitions: How many full repetitions of a cycle before suppression kicks in.
    init(maxCycleLen: Int = 3, minCycleRepetitions: Int = 3) {
        self.maxCycleLen = maxCycleLen
        self.minCycleRepetitions = minCycleRepetitions
    }
    
    /// Returns `true` if the text should be kept, `false` if it's part of a hallucination loop.
    func shouldKeep(_ text: String) -> Bool {
        // If we're actively suppressing a detected cycle
        if let cycle = activeCycle {
            if text == cycle[cyclePosition % cycle.count] {
                cyclePosition += 1
                return false  // still matches the cycle, suppress
            } else {
                // New text breaks the cycle — exit suppression
                activeCycle = nil
                cyclePosition = 0
                history.removeAll()
                history.append(text)
                return true
            }
        }
        
        // Detection mode: accumulate and check
        history.append(text)
        
        for cycleLen in 1...maxCycleLen {
            let needed = cycleLen * minCycleRepetitions
            guard history.count >= needed else { continue }
            
            let tail = Array(history.suffix(needed))
            let cycle = Array(tail.prefix(cycleLen))
            
            var isRepeating = true
            for rep in 0..<minCycleRepetitions {
                for offset in 0..<cycleLen {
                    if tail[rep * cycleLen + offset] != cycle[offset] {
                        isRepeating = false
                        break
                    }
                }
                if !isRepeating { break }
            }
            
            if isRepeating {
                // Enter suppression mode
                activeCycle = cycle
                cyclePosition = 0
                
                // Remove the segments that were part of the cycle detection
                // (all but the first occurrence of the pattern)
                let keepCount = history.count - needed + cycleLen
                history = Array(history.prefix(keepCount))
                
                return false
            }
        }
        
        return true
    }
}
