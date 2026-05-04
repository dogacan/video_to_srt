import Foundation
import ArgumentParser

@main
struct VideoToSrt: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "video_to_srt",
        abstract: "A utility for transcribing audio/video files to SRT.",
        version: "0.1.0"
    )

    @Argument(help: "The path to the audio or video file to transcribe.")
    var inputPath: String

    @Option(name: .shortAndLong, help: "The engine to use for transcription: 'apple', 'whisper', or 'qwen'.")
    var engine: String = "apple"

    @Option(
        name: .shortAndLong,
        help: "Path to write the output SRT file."
    )
    var output: String

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
        help: """
              Absolute path to the whisper model file (e.g. ggml-tiny.bin).
              """
    )
    var whisperModelPath: String?

    @Option(
        name: .long,
        help: """
              Absolute path to the whisper VAD model file (e.g. ggml-silero-v6.2.0.bin).
              """
    )
    var whisperVadPath: String?

    @Flag(
        name: .long,
        inversion: .prefixedNo,
        help: "Whisper-specific: Enable Voice Activity Detection (VAD) to suppress hallucinations in silence."
    )
    var whisperUseVad: Bool = true

    @Option(
        name: .long,
        help: "Whisper-specific: VAD probability threshold (0.0 to 1.0). Lower values are less aggressive. Default: 0.2"
    )
    var whisperVadThreshold: Float = 0.2

    @Option(
        name: .long,
        help: "Whisper-specific: No-speech probability threshold (0.0 to 1.0). If a segment exceeds this, it is considered silence. Default: 0.6"
    )
    var whisperNoSpeechThold: Float = 0.6

    @Option(
        name: .long,
        help: "Offset in seconds to apply to all subtitle timestamps (e.g., 0.5 to delay, -0.5 to advance). Default: 0.0"
    )
    var subtitleOffset: Double = 0.0

    @Option(
        name: .long,
        help: "Whisper-specific: Maximum segment length in characters."
    )
    var whisperMaxLen: Int?

    // MARK: - Qwen Options

    @Option(
        name: .long,
        help: "Qwen-specific: HuggingFace model repo ID for the Qwen3ASR model. Default: 'aufklarer/Qwen3-ASR-0.6B-4bit'"
    )
    var qwenModel: String = "aufklarer/Qwen3-ASR-0.6B-4bit"

    @Option(
        name: .long,
        help: "Qwen-specific: HuggingFace model repo ID for the Qwen3ForcedAligner model. Default: 'aufklarer/Qwen3-ForcedAligner-0.6B-4bit'"
    )
    var qwenAlignerModel: String = "aufklarer/Qwen3-ForcedAligner-0.6B-4bit"

    @Option(
        name: .long,
        help: "Qwen-specific: HuggingFace model repo ID for the SpeechVAD model used in diarization. Default: 'aufklarer/SpeechVAD'"
    )
    var qwenVadModel: String = "aufklarer/SpeechVAD"

    // MARK: - Diarization

    @Flag(
        name: .long,
        help: "Enable speaker diarization using Pyannote (requires python3 and pyannote.audio)."
    )
    var diarize: Bool = false

    @Option(
        name: .long,
        help: "HuggingFace token for Pyannote model. If omitted, HF_TOKEN environment variable will be used."
    )
    var hfToken: String?

    @Option(
        name: .long,
        help: "Path to the Python 3 executable to run the Pyannote script. Default: '/usr/bin/env python3'."
    )
    var pythonPath: String = "/usr/bin/env python3"

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
        case "whisper":
            transcriptionEngine = WhisperTranscriptionEngine(
                modelPath: whisperModelPath,
                vadModelPath: whisperVadPath,
                useVAD: whisperUseVad,
                vadThreshold: whisperVadThreshold,
                noSpeechThold: whisperNoSpeechThold,
                maxLen: whisperMaxLen
            )
        case "qwen":
            transcriptionEngine = Qwen3ASRTranscriptionEngine(
                modelId: qwenModel,
                alignerModelId: qwenAlignerModel,
                vadModelId: qwenVadModel
            )
        default:
            print("Error: Unknown engine '\(engine)'. Use 'apple', 'whisper', or 'qwen'.")
            throw ExitCode.failure
        }

        let options = TranscriptionOptions(
            locale: locale.map { Locale(identifier: $0) },
            ffmpegPath: ffmpegPath,
            subtitleOffsetSeconds: subtitleOffset
        )

        print("Using engine: \(engine)")
        if let localeId = locale {
            print("Requested locale: \(localeId)")
        }
        print("Transcribing \(fileURL.lastPathComponent)...")

        let outputURL = URL(fileURLWithPath: output)

        do {
            let coordinator = TranscriptionCoordinator()
            try await coordinator.transcribe(
                inputURL: fileURL,
                outputURL: outputURL,
                engine: transcriptionEngine,
                options: options,
                diarize: diarize,
                hfToken: hfToken,
                pythonPath: pythonPath,
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

        print("SRT written to \(outputURL.path)")
    }
}
