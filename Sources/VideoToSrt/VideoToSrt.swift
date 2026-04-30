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

    @Option(name: .shortAndLong, help: "The engine to use for transcription: 'apple' or 'whisper'.")
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
        help: "Offset in seconds to apply to all subtitle timestamps (e.g., 0.5 to delay, -0.5 to advance). Default: 0.0"
    )
    var subtitleOffset: Double = 0.0

    @Option(
        name: .long,
        help: "Whisper-specific: Maximum segment length in characters."
    )
    var whisperMaxLen: Int?

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
            transcriptionEngine = WhisperTranscriptionEngine(modelPath: whisperModelPath, maxLen: whisperMaxLen)
        default:
            print("Error: Unknown engine '\(engine)'. Use 'apple' or 'whisper'.")
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
                options: options
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
