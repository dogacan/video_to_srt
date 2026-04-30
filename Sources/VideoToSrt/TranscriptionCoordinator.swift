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
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        let outputDir = outputURL.deletingLastPathComponent()
        
        // Ensure parent directory exists
        try FileManager.default.createDirectory(
            at: outputDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Verify output directory is writable
        guard FileManager.default.isWritableFile(atPath: outputDir.path) else {
            throw NSError(domain: "VideoToSrt", code: 1, userInfo: [NSLocalizedDescriptionKey: "Output directory '\(outputDir.path)' is not writable."])
        }

        var fullSrtText = ""
        let stream = engine.transcribe(fileURL: inputURL, options: options)
        
        for try await result in stream {
            fullSrtText.append(result.srtText)
            progressHandler(result.progress)
        }
        try fullSrtText.write(to: outputURL, atomically: true, encoding: .utf8)
    }
}
