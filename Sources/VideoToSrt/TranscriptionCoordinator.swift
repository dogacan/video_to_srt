import Foundation

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
            fullSrtText += result.srtText
            progressHandler(result.progress)
        }
        
        try fullSrtText.write(to: outputURL, atomically: true, encoding: .utf8)
    }
}
