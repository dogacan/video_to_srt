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
            Task {
                do {
                    // ── 1. Resolve locale ──────────────────────────────────────────────
                    let requestedLocale = options.locale ?? Locale.current
                    guard let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
                        throw AppleTranscriptionError.unsupportedLocale(requestedLocale)
                    }

                    // ── 2. Configure the transcriber ───────────────────────────────────
                    let transcriber = SpeechTranscriber(locale: resolvedLocale,
                                                        preset: .timeIndexedTranscriptionWithAlternatives)

                    // ── 3. Download missing speech models if necessary ─────────────────
                    if let installRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                        logger.info("Downloading speech models for '\(resolvedLocale.identifier)'…")
                        try await installRequest.downloadAndInstall()
                    }

                    logger.info("Extracting audio from '\(fileURL.lastPathComponent)'…")
                    // ── 4. Extract audio to a temporary file ───────────────────────────
                    let audioFileURL = try await AudioExtractor.extractAudioForApple(from: fileURL, ffmpegPath: options.ffmpegPath)
                    defer {
                        try? FileManager.default.removeItem(at: audioFileURL)
                    }

                    // ── 5. Open extracted audio and run analysis ───────────────────────
                    logger.debug("Opening audio file for analysis...")
                    let audioFile: AVAudioFile
                    do {
                        audioFile = try AVAudioFile(forReading: audioFileURL)
                    } catch {
                        logger.error("Failed to open AVAudioFile: \(error, privacy: .public)")
                        throw error
                    }
                    
                    let totalDuration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
                    let analyzer = SpeechAnalyzer(modules: [transcriber])

                    // Run the analyzer concurrently so it can feed the transcriber.results stream
                    let logger = self.logger
                    async let analysisTask: Void = {
                        logger.debug("Running SpeechAnalyzer...")
                        do {
                            let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile)
                            logger.debug("Finalizing SpeechAnalyzer...")
                            if let lastSampleTime {
                                try await analyzer.finalizeAndFinish(through: lastSampleTime)
                            } else {
                                await analyzer.cancelAndFinishNow()
                            }
                        } catch {
                            logger.error("SpeechAnalyzer.analyzeSequence failed: \(error, privacy: .public)")
                            throw error
                        }
                    }()

                    var currentText = ""
                    var currentStart: Double? = nil
                    var currentEnd: Double? = nil
                    var index = 1

                    for try await result in transcriber.results {
                        let plain = String(result.text.characters)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !plain.isEmpty else { continue }

                        let startSecs = result.range.start.seconds + options.subtitleOffsetSeconds
                        let endSecs   = (result.range.start + result.range.duration).seconds + options.subtitleOffsetSeconds

                        if currentText.isEmpty {
                            currentText = plain
                            currentStart = startSecs
                            currentEnd = endSecs
                        } else {
                            currentText += " " + plain
                            currentEnd = endSecs
                        }

                        let duration = (currentEnd ?? 0) - (currentStart ?? 0)
                        let lastRelevantChar = plain.last { char in
                            !char.isWhitespace && char != "\"" && char != "'" && char != "”" && char != "’" && char != "»"
                        }
                        let endsWithPunctuation = lastRelevantChar.map { [".", ",", "?", "!", ";", ":", "…"].contains($0) } ?? false

                        if endsWithPunctuation || duration >= 5.0 {
                            let segment = SRTSegment(text: currentText, startSeconds: currentStart!, endSeconds: currentEnd!)
                            let srtText = SRTFormatter.format(segment, index: index)
                            let progress = totalDuration > 0 ? min(1.0, currentEnd! / totalDuration) : 0.0
                            continuation.yield(TranscriptionResult(srtText: srtText, progress: progress))
                            
                            index += 1
                            currentText = ""
                            currentStart = nil
                            currentEnd = nil
                        }
                    }

                    // Flush any remaining text
                    if !currentText.isEmpty, let start = currentStart, let end = currentEnd {
                        let segment = SRTSegment(text: currentText, startSeconds: start, endSeconds: end)
                        let srtText = SRTFormatter.format(segment, index: index)
                        let progress = totalDuration > 0 ? min(1.0, end / totalDuration) : 0.0
                        continuation.yield(TranscriptionResult(srtText: srtText, progress: progress))
                        index += 1
                    }

                    // Wait for analysis to finish to surface any errors
                    try await analysisTask

                    if index == 1 {
                        throw AppleTranscriptionError.noSpeechDetected
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

}
