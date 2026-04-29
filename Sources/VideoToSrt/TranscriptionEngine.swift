import Foundation

public struct TranscriptionResult: Sendable {
    public let srtText: String
    public let progress: Double

    public init(srtText: String, progress: Double) {
        self.srtText = srtText
        self.progress = progress
    }
}

public protocol TranscriptionEngine {
    /// Transcribe the given audio or video file to SRT format.
    /// - Parameters:
    ///   - fileURL: The file URL pointing to the local video or audio file.
    ///   - options: Engine-agnostic options such as locale. Defaults to ``TranscriptionOptions.default``.
    /// - Returns: An async stream yielding transcription chunks and progress.
    func transcribe(fileURL: URL, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionResult, Error>
}

// MARK: - Default parameter convenience

public extension TranscriptionEngine {
    /// Convenience overload that uses ``TranscriptionOptions.default``.
    func transcribe(fileURL: URL) -> AsyncThrowingStream<TranscriptionResult, Error> {
        transcribe(fileURL: fileURL, options: .default)
    }
}
