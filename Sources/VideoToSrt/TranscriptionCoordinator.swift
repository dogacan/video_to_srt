import Foundation
import MADLADTranslation

/// The central orchestrator for the transcription process.
///
/// `TranscriptionCoordinator` is responsible for managing the high-level workflow of transcribing a file:
/// 1. Validating the output environment (ensuring directories exist and are writable).
/// 2. Executing the transcription via a provided ``TranscriptionEngine``.
/// 3. Handling real-time progress updates via a callback.
/// 4. Persisting the final SRT text to the filesystem.
///
/// This coordinator decouples the CLI interface from the business logic of transcription and file management.
public struct TranscriptionCoordinator {
    public init() {}

    public func transcribe(
        inputURL: URL,
        outputURL: URL,
        engine: any TranscriptionEngine,
        options: TranscriptionOptions,
        diarize: Bool = false,
        vadModelId: String = "aufklarer/Pyannote-Segmentation-MLX",
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        var finalOptions = options
        let outputDir = outputURL.deletingLastPathComponent()
        
        try FileManager.default.createDirectory(
            at: outputDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        guard FileManager.default.isWritableFile(atPath: outputDir.path) else {
            throw NSError(domain: "VideoToSrt", code: 1, userInfo: [NSLocalizedDescriptionKey: "Output directory '\(outputDir.path)' is not writable."])
        }

        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: nil)

        let fileHandle = try FileHandle(forWritingTo: outputURL)
        defer {
            try? fileHandle.close()
        }


        if diarize {
            let map = try await DiarizationRunner.run(
                inputURL: inputURL,
                ffmpegPath: finalOptions.ffmpegPath,
                vadModelId: vadModelId
            )
            finalOptions.diarizationMap = map.shifted(by: finalOptions.diarizationShiftSeconds)
        }

        let targetFormat = finalOptions.format
        if finalOptions.translateToLanguageCode != nil {
            // Force transcribing engine to output SRT so it's easily parsed
            finalOptions.format = .srt
        }

        // Only write headers immediately if NOT translating
        if finalOptions.translateToLanguageCode == nil {
            if targetFormat == .vtt {
                if let data = "WEBVTT\n\n".data(using: String.Encoding.utf8) {
                    try fileHandle.write(contentsOf: data)
                }
            } else if targetFormat == .json {
                if let data = "[\n".data(using: String.Encoding.utf8) {
                    try fileHandle.write(contentsOf: data)
                }
            }
        }

        let stream = engine.transcribe(fileURL: inputURL, options: finalOptions)
        var isFirstSegment = true
        var accumulatedText = ""
        
        for try await result in stream {
            if finalOptions.translateToLanguageCode != nil {
                accumulatedText += result.formattedText
            } else {
                var textToWrite = result.formattedText
                if targetFormat == .json {
                    if !isFirstSegment {
                        textToWrite = ",\n" + textToWrite
                    }
                    isFirstSegment = false
                }
                if let data = textToWrite.data(using: String.Encoding.utf8) {
                    try fileHandle.write(contentsOf: data)
                }
            }
            progressHandler(result.progress)
        }

        // If translating, translate the accumulated segments and write them to output
        if let targetLang = finalOptions.translateToLanguageCode {
            let segments = try SubtitleParser.parse(accumulatedText)
            if !segments.isEmpty {
                fputs("Translating \(segments.count) segments to '\(targetLang)'...\n", stderr)
                fflush(stderr)
                
                let translationEngine: any TranslationEngine
                if finalOptions.translationEngine.lowercased() == "openrouter" {
                    translationEngine = OpenRouterTranslationEngine(model: finalOptions.openRouterModel)
                } else if finalOptions.translationEngine.lowercased() == "madlad" {
                    let quantization = finalOptions.madladQuantization.lowercased() == "int8" ? MADLADTranslator.Quantization.int8 : MADLADTranslator.Quantization.int4
                    translationEngine = MADLADTranslationEngine(modelId: finalOptions.madladModel, quantization: quantization)
                } else {
                    translationEngine = AppleTranslationEngine()
                }
                let translator = SubtitleTranslator(engine: translationEngine)
                let translatedSegments = try await translator.translate(
                    segments,
                    sourceLanguageCode: finalOptions.locale?.identifier ?? Locale.current.identifier,
                    targetLanguageCode: targetLang,
                    progressHandler: { translated, total in
                        let progressString = "\rProgress: \(translated)/\(total) segments translated..."
                        fputs(progressString, stderr)
                        fflush(stderr)
                    }
                )
                fputs("\n", stderr) // New line after progress
                
                if targetFormat == .vtt {
                    if let data = "WEBVTT\n\n".data(using: String.Encoding.utf8) {
                        try fileHandle.write(contentsOf: data)
                    }
                } else if targetFormat == .json {
                    if let data = "[\n".data(using: String.Encoding.utf8) {
                        try fileHandle.write(contentsOf: data)
                    }
                }

                var isFirstTranslated = true
                for segment in translatedSegments {
                    var textToWrite = SubtitleFormatter.format(segment, format: targetFormat)
                    if targetFormat == .json {
                        if !isFirstTranslated {
                            textToWrite = ",\n" + textToWrite
                        }
                        isFirstTranslated = false
                    }
                    if let data = textToWrite.data(using: String.Encoding.utf8) {
                        try fileHandle.write(contentsOf: data)
                    }
                }

                if targetFormat == .json {
                    if let data = "\n]\n".data(using: String.Encoding.utf8) {
                        try fileHandle.write(contentsOf: data)
                    }
                }
            }
        } else {
            if targetFormat == .json {
                if let data = "\n]\n".data(using: String.Encoding.utf8) {
                    try fileHandle.write(contentsOf: data)
                }
            }
        }
    }
}
