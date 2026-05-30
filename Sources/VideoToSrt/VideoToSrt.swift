import Foundation
import ArgumentParser

@main
struct VideoToSrt: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "video-to-srt",
        abstract: "A utility to transcribe video/audio files or translate subtitle files.",
        version: "0.2.0",
        subcommands: [Transcribe.self, Translate.self],
        defaultSubcommand: Transcribe.self
    )
}

extension VideoToSrt {
    struct Transcribe: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "transcribe",
            abstract: "Transcribe audio/video files to subtitles."
        )

        @Argument(help: "The path to the audio or video file to transcribe.")
        var inputPath: String

        @Option(name: .shortAndLong, help: "The engine to use for transcription: 'apple' or 'qwen'.")
        var engine: String = "apple"

        @Option(
            name: .shortAndLong,
            help: "Path to write the output subtitle file. Defaults to <input file without extension>.<format>"
        )
        var output: String?

        @Option(
            name: .shortAndLong,
            help: "The output format: 'srt', 'vtt', 'txt', or 'json'. Default: 'srt'"
        )
        var format: String = "srt"

        @Option(
            name: .long,
            help: "The maximum number of characters allowed per subtitle segment line. Default: 80"
        )
        var maxCpl: Int = 80

        @Option(
            name: .long,
            help: "The maximum duration in seconds allowed for a single subtitle segment. Default: 7.0"
        )
        var maxDuration: Double = 7.0

        @Option(
            name: .long,
            help: "The minimum number of words required in a subtitle segment before it can be split due to duration. Default: 3"
        )
        var minWords: Int = 3

        @Option(
            name: .long,
            help: """
                  BCP-47 locale identifier for the transcription language (e.g. 'en-US', 'fr-FR').
                  Defaults to the system locale when omitted.
                  """
        )
        var locale: String?

        @Option(
            name: .long,
            help: """
                  Absolute path to the 'ffmpeg' executable.
                  If provided, this acts as a fallback to convert media formats unsupported
                  by Apple's native AVFoundation (such as MKV).
                  """
        )
        var ffmpegPath: String?

        @Option(
            name: .long,
            help: "Offset in seconds to apply to all subtitle timestamps (e.g., 0.5 to delay, -0.5 to advance). Default: 0.0"
        )
        var subtitleOffset: Double = 0.0

        // MARK: - Qwen Options

        @Option(
            name: .long,
            help: "Qwen-specific: HuggingFace model repo ID for the Qwen3ASR model. Default: 'aufklarer/Qwen3-ASR-0.6B-MLX-4bit'"
        )
        var qwenModel: String = "aufklarer/Qwen3-ASR-1.7B-MLX-4bit"

        @Option(
            name: .long,
            help: "Qwen-specific: HuggingFace model repo ID for the Qwen3ForcedAligner model. Default: 'aufklarer/Qwen3-ForcedAligner-0.6B-4bit'"
        )
        var qwenAlignerModel: String = "aufklarer/Qwen3-ForcedAligner-0.6B-8bit"

        @Option(
            name: .long,
            help: "HuggingFace model repo ID for the SpeechVAD model used in diarization. Default: 'aufklarer/Pyannote-Segmentation-MLX'"
        )
        var vadModel: String = "aufklarer/Pyannote-Segmentation-MLX"

        // MARK: - Diarization

        @Flag(
            name: .long,
            help: "Enable native speaker diarization using SpeechVAD."
        )
        var diarize: Bool = false

        @Option(
            name: .long,
            help: "Diarization latency shift in seconds (e.g. 0.5 to shift speaker boundaries earlier). Default: 0.5"
        )
        var diarizationShift: Double = 0.5

        // MARK: - Translation

        @Option(
            name: .long,
            help: "Translate final subtitles on-the-fly to this language code (e.g., 'tr', 'es'). Requires Apple Translation models."
        )
        var translateTo: String?

        @Option(
            name: .long,
            help: "The translation engine to use: 'apple' or 'openrouter'. Default: 'apple'"
        )
        var translationEngine: String = "apple"

        @Option(
            name: .long,
            help: "The OpenRouter model to use for translation. Default: 'openrouter/free'"
        )
        var openRouterModel: String = "openrouter/free"

        mutating func run() async throws {
            let fileURL = URL(fileURLWithPath: inputPath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                print("Error: File not found at path '\(inputPath)'")
                throw ExitCode.failure
            }

            if let localeId = locale {
                let testLocale = Locale(identifier: localeId)
                if testLocale.identifier.isEmpty || testLocale.identifier == "und" {
                    print("Error: Invalid locale identifier '\(localeId)'")
                    throw ExitCode.failure
                }
            }

            let transcriptionEngine: any TranscriptionEngine
            switch engine.lowercased() {
            case "apple":
                transcriptionEngine = AppleTranscriptionEngine()
            case "qwen":
                transcriptionEngine = Qwen3ASRTranscriptionEngine(
                    modelId: qwenModel,
                    alignerModelId: qwenAlignerModel,
                    vadModelId: vadModel
                )
            default:
                print("Error: Unknown engine '\(engine)'. Use 'apple' or 'qwen'.")
                throw ExitCode.failure
            }

            guard let subFormat = SubtitleFormat(rawValue: format.lowercased()) else {
                print("Error: Unknown format '\(format)'. Use 'srt', 'vtt', 'txt', or 'json'.")
                throw ExitCode.failure
            }

            let options = TranscriptionOptions(
                locale: locale.map { Locale(identifier: $0) },
                ffmpegPath: ffmpegPath,
                subtitleOffsetSeconds: subtitleOffset,
                diarizationShiftSeconds: diarizationShift,
                format: subFormat,
                maxCharactersPerLine: maxCpl,
                maxSegmentDuration: maxDuration,
                minWordsPerSegment: minWords,
                translateToLanguageCode: translateTo,
                translationEngine: translationEngine,
                openRouterModel: openRouterModel
            )

            print("Using engine: \(engine)")
            if let localeId = locale {
                print("Requested locale: \(localeId)")
            }
            print("Transcribing \(fileURL.lastPathComponent)...")

            let outputURL: URL
            if let out = output {
                outputURL = URL(fileURLWithPath: out)
            } else {
                let baseName = fileURL.deletingPathExtension().lastPathComponent
                let outputDirectory = fileURL.deletingLastPathComponent()
                outputURL = outputDirectory.appendingPathComponent("\(baseName).\(subFormat.rawValue)")
            }

            do {
                let coordinator = TranscriptionCoordinator()
                try await coordinator.transcribe(
                    inputURL: fileURL,
                    outputURL: outputURL,
                    engine: transcriptionEngine,
                    options: options,
                    diarize: diarize,
                    vadModelId: vadModel
                ) { progress in
                    let percent = Int(progress * 100)
                    let progressString = "\rProgress: \(percent)% transcribed..."
                    fputs(progressString, stderr)
                    fflush(stderr)
                }
                fputs("\n", stderr) // New line after progress
                print("Transcription complete!")
            } catch {
                print("\nError: \(error.localizedDescription)")
                throw ExitCode.failure
            }

            print("Subtitles written to \(outputURL.path)")
        }
    }

    struct Translate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "translate",
            abstract: "Translate an existing subtitle file (SRT or WebVTT) into another language."
        )

        @Option(name: .shortAndLong, help: "The path to the input subtitle file (SRT or WebVTT) to translate.")
        var input: String

        @Option(name: .shortAndLong, help: "The path to write the translated subtitle file. Defaults to <input-file-without-extension>.<target-locale>.<format>")
        var output: String?

        @Option(name: .shortAndLong, help: "The target BCP-47 language code for translation (e.g. 'tr', 'es', 'fr-FR').")
        var targetLocale: String

        @Option(name: .shortAndLong, help: "The source BCP-47 language code of the input subtitles (e.g. 'en'). Defaults to the system locale.")
        var sourceLocale: String?

        @Option(name: .shortAndLong, help: "The output format: 'srt', 'vtt', 'txt', or 'json'. Defaults to the input format.")
        var format: String?

        @Option(name: .long, help: "The translation engine to use: 'apple' or 'openrouter'. Default: 'apple'")
        var translationEngine: String = "apple"

        @Option(name: .long, help: "The OpenRouter model to use for translation. Default: 'openrouter/free'")
        var openRouterModel: String = "openrouter/free"

        mutating func run() async throws {
            let inputURL = URL(fileURLWithPath: input)
            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                print("Error: Input subtitle file not found at path '\(input)'")
                throw ExitCode.failure
            }

            let content = try String(contentsOf: inputURL, encoding: .utf8)
            
            let segments: [SubtitleSegment]
            do {
                segments = try SubtitleParser.parse(content)
            } catch {
                print("Error parsing subtitle file: \(error.localizedDescription)")
                throw ExitCode.failure
            }

            if segments.isEmpty {
                print("Warning: Input subtitle file is empty.")
                return
            }

            let inputFormatStr = inputURL.pathExtension.lowercased()
            let resolvedFormatStr = format?.lowercased() ?? inputFormatStr
            guard let resolvedFormat = SubtitleFormat(rawValue: resolvedFormatStr) else {
                print("Error: Unknown output format '\(resolvedFormatStr)'. Use 'srt', 'vtt', 'txt', or 'json'.")
                throw ExitCode.failure
            }

            let outputURL: URL
            if let out = output {
                outputURL = URL(fileURLWithPath: out)
            } else {
                let baseName = inputURL.deletingPathExtension().lastPathComponent
                let outputDirectory = inputURL.deletingLastPathComponent()
                outputURL = outputDirectory.appendingPathComponent("\(baseName).\(targetLocale).\(resolvedFormat.rawValue)")
            }

            print("Translating \(segments.count) segments to '\(targetLocale)'...")

            let engine: any TranslationEngine
            if translationEngine.lowercased() == "openrouter" {
                engine = OpenRouterTranslationEngine(model: openRouterModel)
            } else {
                engine = AppleTranslationEngine()
            }
            let translator = SubtitleTranslator(engine: engine)
            let translatedSegments = try await translator.translate(
                segments,
                sourceLanguageCode: sourceLocale ?? Locale.current.identifier,
                targetLanguageCode: targetLocale,
                progressHandler: { translated, total in
                    let progressString = "\rProgress: \(translated)/\(total) segments translated..."
                    fputs(progressString, stderr)
                    fflush(stderr)
                }
            )
            fputs("\n", stderr) // New line after progress

            print("Writing translated subtitles to \(outputURL.path)...")
            FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: nil)
            let fileHandle = try FileHandle(forWritingTo: outputURL)
            defer {
                try? fileHandle.close()
            }

            if resolvedFormat == .vtt {
                if let data = "WEBVTT\n\n".data(using: String.Encoding.utf8) {
                    try fileHandle.write(contentsOf: data)
                }
            } else if resolvedFormat == .json {
                if let data = "[\n".data(using: String.Encoding.utf8) {
                    try fileHandle.write(contentsOf: data)
                }
            }

            var isFirstSegment = true
            for segment in translatedSegments {
                var textToWrite = SubtitleFormatter.format(segment, format: resolvedFormat)
                if resolvedFormat == .json {
                    if !isFirstSegment {
                        textToWrite = ",\n" + textToWrite
                    }
                    isFirstSegment = false
                }
                if let data = textToWrite.data(using: String.Encoding.utf8) {
                    try fileHandle.write(contentsOf: data)
                }
            }

            if resolvedFormat == .json {
                if let data = "\n]\n".data(using: String.Encoding.utf8) {
                    try fileHandle.write(contentsOf: data)
                }
            }

            print("Translation complete!")
        }
    }
}
