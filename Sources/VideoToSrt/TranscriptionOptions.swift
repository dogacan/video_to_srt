import Foundation

/// Engine-agnostic options that control transcription behaviour.
///
/// Pass a value of this type to ``TranscriptionEngine/transcribe(fileURL:options:)``.
/// Engines are free to ignore options they do not support.
public struct TranscriptionOptions: Sendable {

    // MARK: - Locale

    /// The locale (language / region) the engine should transcribe into.
    ///
    /// When `nil` the engine uses its own default, typically ``Locale.current``.
    public var locale: Locale?

    /// Optional path to the `ffmpeg` executable.
    ///
    /// If provided, engines can use this as a fallback to convert unsupported
    /// media formats (like MKV) before processing.
    public var ffmpegPath: String?

    /// Optional offset in seconds to apply to subtitle timestamps.
    public var subtitleOffsetSeconds: Double

    // MARK: - Initialiser

    public init(locale: Locale? = nil, ffmpegPath: String? = nil, subtitleOffsetSeconds: Double = 0.0) {
        self.locale = locale
        self.ffmpegPath = ffmpegPath
        self.subtitleOffsetSeconds = subtitleOffsetSeconds
    }

    // MARK: - Convenience presets

    /// Default options: the engine picks the locale.
    public static let `default` = TranscriptionOptions()
}
