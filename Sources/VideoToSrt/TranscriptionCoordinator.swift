import Foundation

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
            finalOptions.diarizationMap = try await DiarizationRunner.run(
                inputURL: inputURL,
                ffmpegPath: finalOptions.ffmpegPath,
                vadModelId: vadModelId
            )
        }

        if finalOptions.format == .vtt {
            if let data = "WEBVTT\n\n".data(using: .utf8) {
                try fileHandle.write(contentsOf: data)
            }
        } else if finalOptions.format == .json {
            if let data = "[\n".data(using: .utf8) {
                try fileHandle.write(contentsOf: data)
            }
        }

        let stream = engine.transcribe(fileURL: inputURL, options: finalOptions)
        var isFirstSegment = true
        
        for try await result in stream {
            var textToWrite = result.formattedText
            if finalOptions.format == .json {
                if !isFirstSegment {
                    textToWrite = ",\n" + textToWrite
                }
                isFirstSegment = false
            }
            if let data = textToWrite.data(using: .utf8) {
                try fileHandle.write(contentsOf: data)
            }
            progressHandler(result.progress)
        }

        if finalOptions.format == .json {
            if let data = "\n]\n".data(using: .utf8) {
                try fileHandle.write(contentsOf: data)
            }
        }
    }
}
