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
    ///   - options: Engine-agnostic options such as locale and subtitle offset.
    /// - Returns: An `AsyncThrowingStream` yielding ``TranscriptionResult`` chunks as they become available.
    /// - Throws: An error if transcription fails, if the input file is inaccessible, or if required resources (like models) are missing.
    func transcribe(fileURL: URL, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionResult, Error>
}

// MARK: - Default parameter convenience

public extension TranscriptionEngine {
    /// Convenience overload that uses ``TranscriptionOptions.default``.
    func transcribe(fileURL: URL) -> AsyncThrowingStream<TranscriptionResult, Error> {
        transcribe(fileURL: fileURL, options: .default)
    }
}
