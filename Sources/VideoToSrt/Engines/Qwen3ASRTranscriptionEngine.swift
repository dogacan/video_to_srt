import Foundation
import Qwen3ASR
import os

/// Internal wrapper to conform `AlignedWord` to `TranscriptionSegment`.
private struct QwenWordSegment: TranscriptionSegment {
    let word: String
    let start: Double
    let end: Double
    
    var transcriptionText: String { word }
    var transcriptionStartTime: Double { start }
    var transcriptionEndTime: Double { end }
}

public enum Qwen3TranscriptionError: Error, LocalizedError {
    case transcriptionFailed(Error)
    
    public var errorDescription: String? {
        switch self {
        case .transcriptionFailed(let error):
            return "Qwen3 transcription failed: \(error.localizedDescription)"
        }
    }
}

/// A ``TranscriptionEngine`` implementation that uses the Qwen3ASR model via `speech-swift`.
///
/// Because Qwen3ASR processes audio in batch mode and does not natively emit timestamps, this engine
/// runs a two-step pipeline:
/// 1. Runs `Qwen3ASRModel` on 16kHz audio to get the full transcribed text.
/// 2. Runs `Qwen3ForcedAligner` on 24kHz audio and the transcribed text to generate word-level timestamps.
public struct Qwen3ASRTranscriptionEngine: TranscriptionEngine, Sendable {
    private let logger = Logger(subsystem: "com.video_to_srt", category: "Qwen3ASRTranscriptionEngine")
    
    public let modelId: String
    public let alignerModelId: String
    public let vadModelId: String
    
    public init(
        modelId: String = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit",
        alignerModelId: String = "aufklarer/Qwen3-ForcedAligner-0.6B-4bit",
        vadModelId: String = "aufklarer/Pyannote-Segmentation-MLX"
    ) {
        self.modelId = modelId
        self.alignerModelId = alignerModelId
        self.vadModelId = vadModelId
    }
    
    public func transcribe(fileURL: URL, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionResult, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    logger.info("Extracting and converting audio to 16kHz PCM for Qwen3ASR...")
                    let audio16k = try await AudioExtractor.extractAudioFloat(from: fileURL, targetSampleRate: 16000.0, ffmpegPath: options.ffmpegPath)
                    
                    logger.info("Loading Qwen3ASR model (\(modelId))...")
                    let asrModel = try await Qwen3ASRModel.fromPretrained(modelId: modelId)
                    
                    logger.info("Transcribing full audio with Qwen3ASR...")
                    let decodeOptions = Qwen3DecodingOptions(repetitionPenalty: 1.15)
                    let text = asrModel.transcribe(audio: audio16k, sampleRate: 16000, options: decodeOptions)
                    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if trimmedText.isEmpty {
                        logger.warning("Qwen3ASR returned empty text. Skipping alignment.")
                        continuation.finish()
                        return
                    }
                    
                    logger.info("Extracting and converting audio to 24kHz PCM for Qwen3ForcedAligner...")
                    let audio24k = try await AudioExtractor.extractAudioFloat(from: fileURL, targetSampleRate: 24000.0, ffmpegPath: options.ffmpegPath)
                    
                    logger.info("Loading Qwen3ForcedAligner model (\(alignerModelId))...")
                    let alignerModel = try await Qwen3ForcedAligner.fromPretrained(modelId: alignerModelId)
                    logger.info("Aligning text to get timestamps...")
                    let alignedWords = alignerModel.align(audio: audio24k, text: trimmedText, sampleRate: 24000)
                    
                    let totalDuration = Double(audio16k.count) / 16000.0
                    let segmenter = ResultSegmenter(
                        offset: options.subtitleOffsetSeconds,
                        totalDuration: totalDuration,
                        diarizationMap: options.diarizationMap
                    )
                    
                    for word in alignedWords {
                        let wordSegment = QwenWordSegment(word: word.text, start: Double(word.startTime), end: Double(word.endTime))
                        let results = segmenter.process(segment: wordSegment)
                        for result in results {
                            continuation.yield(result)
                        }
                    }
                    
                    if let finalResult = segmenter.flush() {
                        continuation.yield(finalResult)
                    }
                    
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Qwen3TranscriptionError.transcriptionFailed(error))
                }
            }
        }
    }
}
