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
              Defaults to 'models/ggml-base.bin' if it exists.
              """
    )
    var whisperModelPath: String?

    @Option(
        name: .long,
        help: "Offset in seconds to apply to all subtitle timestamps (e.g., 0.5 to delay, -0.5 to advance)."
    )
    var subtitleOffset: Double = 0.5

    mutating func run() async throws {
        let fileURL = URL(fileURLWithPath: inputPath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("Error: File not found at path '\(inputPath)'")
            throw ExitCode.failure
        }

        let transcriptionEngine: any TranscriptionEngine
        switch engine.lowercased() {
        case "apple":
            transcriptionEngine = AppleTranscriptionEngine()
        case "whisper":
            transcriptionEngine = WhisperTranscriptionEngine()
        default:
            print("Error: Unknown engine '\(engine)'. Use 'apple' or 'whisper'.")
            throw ExitCode.failure
        }

        // Build engine-agnostic options from CLI flags.
        var finalWhisperModelPath = whisperModelPath
        if finalWhisperModelPath == nil && engine.lowercased() == "whisper" {
            let defaultPath = "models/ggml-base.bin"
            if FileManager.default.fileExists(atPath: defaultPath) {
                finalWhisperModelPath = defaultPath
            }
        }

        let options = TranscriptionOptions(
            locale: locale.map { Locale(identifier: $0) },
            ffmpegPath: ffmpegPath,
            whisperModelPath: finalWhisperModelPath,
            subtitleOffsetSeconds: subtitleOffset
        )

        print("Using engine: \(engine)")
        if let localeId = locale {
            print("Requested locale: \(localeId)")
        }
        print("Transcribing \(fileURL.lastPathComponent)...")

        let outputURL = URL(fileURLWithPath: output)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: nil)
        guard let fileHandle = try? FileHandle(forWritingTo: outputURL) else {
            print("Error: Failed to open output file for writing.")
            throw ExitCode.failure
        }

        do {
            let stream = transcriptionEngine.transcribe(fileURL: fileURL, options: options)
            for try await result in stream {
                if let data = result.srtText.data(using: .utf8) {
                    try fileHandle.seekToEnd()
                    try fileHandle.write(contentsOf: data)
                }
                let percent = Int(result.progress * 100)
                print("\rProgress: \(percent)% transcribed...", terminator: "")
                fflush(stdout)
            }
            print("\nTranscription complete!")
            try fileHandle.close()
        } catch {
            print("\nError: \(error.localizedDescription)")
            try? fileHandle.close()
            throw ExitCode.failure
        }

        print("SRT written to \(outputURL.path)")
    }
}
