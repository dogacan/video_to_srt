import Foundation
import Speech
@preconcurrency import AVFoundation
import os

// MARK: - Errors

public enum AppleTranscriptionError: Error, LocalizedError {
    /// The locale requested by the caller is not supported on this device.
    case unsupportedLocale(Locale)
    /// The transcriber produced no output.
    case noSpeechDetected

    public var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let locale):
            return "The locale '\(locale.identifier)' is not supported by Apple Speech on this device."
        case .noSpeechDetected:
            return "No speech was detected in the file."
        }
    }
}

// Add conformance for Apple's result
extension SpeechTranscriber.Result: TranscriptionSegment {
    public var transcriptionText: String { String(self.text.characters) }
    public var transcriptionStartTime: Double { self.range.start.seconds }
    public var transcriptionEndTime: Double { (self.range.start + self.range.duration).seconds }
}

// MARK: - Engine

/// A ``TranscriptionEngine`` that uses Apple's on-device
/// `SpeechTranscriber` / `SpeechAnalyzer` APIs (macOS 26+).
///
/// ## Pipeline
///
/// 1. Resolve the requested locale against `SpeechTranscriber.supportedLocales`.
/// 2. Ensure the required speech-model assets are installed via `AssetInventory`.
/// 3. Export the audio track from the source file to a temporary `.caf` file
///    using `AVAssetExportSession` (handles video containers, multi-track files, etc.).
/// 4. Open the exported file as `AVAudioFile` and run
///    `SpeechAnalyzer.analyzeSequence(from:)`.
/// 5. Collect `SpeechTranscriber.Result` values — each carries a `CMTimeRange`
///    (`result.range`) that maps directly to SRT timestamps.
/// 6. Format and return the SRT string.
///
/// The `.timeIndexedTranscriptionWithAlternatives` preset is chosen because it:
/// - Returns **only final** (non-volatile) results, which is ideal for file
///   transcription where latency is not a concern.
/// - Includes **audio time-range attributes** on each result, enabling accurate
///   per-segment SRT timestamps.
public struct AppleTranscriptionEngine: TranscriptionEngine, Sendable {
    private let logger = Logger(subsystem: "com.video_to_srt", category: "AppleTranscriptionEngine")

    public init() {}

    // MARK: - TranscriptionEngine

    public func transcribe(fileURL: URL, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionResult, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                await self.performTranscription(fileURL: fileURL, options: options, continuation: continuation)
            }
            
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func performTranscription(
        fileURL: URL,
        options: TranscriptionOptions,
        continuation: AsyncThrowingStream<TranscriptionResult, Error>.Continuation
    ) async {
        do {
            // 1. Resolve locale
            let requestedLocale = options.locale ?? Locale.current
            guard let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
                throw AppleTranscriptionError.unsupportedLocale(requestedLocale)
            }

            // 2. Configure the transcriber
            let transcriber = SpeechTranscriber(
                locale: resolvedLocale,
                preset: .timeIndexedTranscriptionWithAlternatives
            )

            // 3. Download missing speech models if necessary
            if let installRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                logger.info("Downloading speech models for '\(resolvedLocale.identifier)'…")
                try await installRequest.downloadAndInstall()
            }

            // 4. Extract audio
            logger.info("Extracting audio from '\(fileURL.lastPathComponent)'…")
            let audioFileURL = try await AudioExtractor.extractAudioForApple(from: fileURL, ffmpegPath: options.ffmpegPath)
            defer {
                try? FileManager.default.removeItem(at: audioFileURL)
            }

            // Check for cancellation before expensive analysis
            try Task.checkCancellation()

            // 5. Setup Analyzer
            let audioFile = try AVAudioFile(forReading: audioFileURL)
            let totalDuration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            
            // Optimization: Preheat the analyzer
            logger.debug("Preheating SpeechAnalyzer...")
            try await analyzer.prepareToAnalyze(in: audioFile.processingFormat)

            // 6. Run analysis task
            async let analysisTask: Void = {
                do {
                    if let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) {
                        try await analyzer.finalizeAndFinish(through: lastSampleTime)
                    } else {
                        await analyzer.cancelAndFinishNow()
                    }
                } catch {
                    logger.error("SpeechAnalyzer failed: \(error, privacy: .public)")
                    throw error
                }
            }()

            // 7. Process results with segmenter
            var segmenter = ResultSegmenter(
                offset: options.subtitleOffsetSeconds,
                totalDuration: totalDuration
            )

            for try await result in transcriber.results {
                try Task.checkCancellation()
                
                if let transcriptionResult = segmenter.process(segment: result) {
                    continuation.yield(transcriptionResult)
                }
            }

            // Flush remaining text
            if let finalResult = segmenter.flush() {
                continuation.yield(finalResult)
            }

            // Ensure analysis task finished successfully
            try await analysisTask

            if segmenter.segmentCount == 0 {
                throw AppleTranscriptionError.noSpeechDetected
            }

            continuation.finish()
        } catch is CancellationError {
            logger.info("Transcription task was cancelled.")
            continuation.finish()
        } catch {
            logger.error("Transcription failed: \(error, privacy: .public)")
            continuation.finish(throwing: error)
        }
    }
}
