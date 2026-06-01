import Foundation

public enum SubtitleFormat: String, CaseIterable, Sendable {
    case srt
    case vtt
    case txt
    case json
}

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

    // MARK: - Diarization

    /// An optional map of speaker segments used to inject speaker tags (e.g. "- Hello") into the SRT.
    public var diarizationMap: DiarizationMap?

    /// The temporal shift in seconds to compensate for diarization lateness.
    /// A positive value shifts diarization segments earlier in time (e.g. 0.5s).
    public var diarizationShiftSeconds: Double

    // MARK: - Layout & Output Format

    /// The desired output format of the subtitles/transcription.
    public var format: SubtitleFormat

    /// The maximum number of characters allowed per subtitle segment line.
    public var maxCharactersPerLine: Int

    /// The maximum duration (in seconds) allowed for a single subtitle segment.
    public var maxSegmentDuration: Double

    /// The minimum number of words required in a subtitle segment before it can be split due to duration.
    public var minWordsPerSegment: Int

    /// Optional target language code to translate the final subtitles into.
    public var translateToLanguageCode: String?

    /// The translation engine to use: "apple", "openrouter", or "madlad".
    public var translationEngine: String

    /// The OpenRouter model to use (e.g. "google/gemma-4-31b-it:free").
    public var openRouterModel: String

    /// The HuggingFace model repo ID for MADLAD translation.
    public var madladModel: String

    /// The quantization to use: "int4" or "int8".
    public var madladQuantization: String

    // MARK: - Initialiser

    public init(
        locale: Locale? = nil,
        ffmpegPath: String? = nil,
        subtitleOffsetSeconds: Double = 0.0,
        diarizationMap: DiarizationMap? = nil,
        diarizationShiftSeconds: Double = 0.0,
        format: SubtitleFormat = .srt,
        maxCharactersPerLine: Int = 80,
        maxSegmentDuration: Double = 7.0,
        minWordsPerSegment: Int = 1,
        translateToLanguageCode: String? = nil,
        translationEngine: String = "apple",
        openRouterModel: String = "openrouter/free",
        madladModel: String = "aufklarer/MADLAD400-3B-MT-MLX",
        madladQuantization: String = "int4"
    ) {
        self.locale = locale
        self.ffmpegPath = ffmpegPath
        self.subtitleOffsetSeconds = subtitleOffsetSeconds
        self.diarizationMap = diarizationMap
        self.diarizationShiftSeconds = diarizationShiftSeconds
        self.format = format
        self.maxCharactersPerLine = maxCharactersPerLine
        self.maxSegmentDuration = maxSegmentDuration
        self.minWordsPerSegment = minWordsPerSegment
        self.translateToLanguageCode = translateToLanguageCode
        self.translationEngine = translationEngine
        self.openRouterModel = openRouterModel
        self.madladModel = madladModel
        self.madladQuantization = madladQuantization
    }

    // MARK: - Convenience presets

    /// Default options: the engine picks the locale.
    public static let `default` = TranscriptionOptions()
}
