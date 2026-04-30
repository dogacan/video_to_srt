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
                
                if let transcriptionResult = segmenter.process(result: result) {
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

// MARK: - ResultSegmenter

/// Internal helper to accumulate transcription results into SRT-friendly segments.
private struct ResultSegmenter {
    private let offset: Double
    private let totalDuration: Double
    private let maxSegmentDuration: Double = 5.0
    private let maxCharactersPerLine: Int = 80
    
    private var currentText: String = ""
    private var currentStart: Double?
    private var currentEnd: Double?
    private(set) var segmentCount: Int = 0
    
    init(offset: Double, totalDuration: Double) {
        self.offset = offset
        self.totalDuration = totalDuration
    }
    
    mutating func process(result: SpeechTranscriber.Result) -> TranscriptionResult? {
        let plain = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return nil }
        
        let startSecs = result.range.start.seconds + offset
        let endSecs = (result.range.start + result.range.duration).seconds + offset
        
        if currentText.isEmpty {
            currentText = plain
            currentStart = startSecs
            currentEnd = endSecs
        } else {
            currentText += " " + plain
            currentEnd = endSecs
        }
        
        if shouldFlush() {
            return flush()
        }
        
        return nil
    }
    
    mutating func flush() -> TranscriptionResult? {
        guard !currentText.isEmpty, let start = currentStart, let end = currentEnd else {
            return nil
        }
        
        segmentCount += 1
        let segment = SRTSegment(text: currentText, startSeconds: start, endSeconds: end)
        let srtText = SRTFormatter.format(segment, index: segmentCount)
        let progress = totalDuration > 0 ? min(1.0, end / totalDuration) : 0.0
        
        // Reset for next segment
        currentText = ""
        currentStart = nil
        currentEnd = nil
        
        return TranscriptionResult(srtText: srtText, progress: progress)
    }
    
    private func shouldFlush() -> Bool {
        guard let start = currentStart, let end = currentEnd else { return false }
        
        let duration = end - start
        if duration >= maxSegmentDuration { return true }
        if currentText.count >= maxCharactersPerLine { return true }
        
        // Punctuation check
        let punctuation = CharacterSet.punctuationCharacters
        if let lastChar = currentText.trimmingCharacters(in: .whitespacesAndNewlines).last,
           punctuation.containsUnicodeScalar(lastChar.unicodeScalars.first!) {
            // We want to split on end-of-sentence punctuation mostly
            let sentenceEndings: Set<Character> = [".", "?", "!", "…"]
            if sentenceEndings.contains(lastChar) {
                return true
            }
        }
        
        return false
    }
}

private extension CharacterSet {
    func containsUnicodeScalar(_ scalar: Unicode.Scalar) -> Bool {
        return contains(scalar)
    }
}
