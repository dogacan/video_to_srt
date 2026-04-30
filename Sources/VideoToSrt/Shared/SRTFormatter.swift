import Foundation

/// Represents a single subtitle entry in an SRT file.
public struct SRTSegment: Sendable {
    public let text: String
    public let startSeconds: Double
    public let endSeconds: Double

    public init(text: String, startSeconds: Double, endSeconds: Double) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

/// A utility for converting raw transcription timing and text into standard SubRip Subtitle (SRT) format.
///
/// This formatter handles the conversion of `TimeInterval` (seconds) into the precise `HH:MM:SS,mmm`
/// timestamp format required by SRT readers.
public enum SRTFormatter {
    /// Formats a single SRT segment into the standard SRT string format.
    /// Example output:
    /// 1
    /// 00:00:00,000 --> 00:00:05,000
    /// Hello world
    ///
    /// - Parameters:
    ///   - segment: The segment data (text, start, end).
    ///   - index: The 1-based index of this segment.
    /// - Returns: A string representing this block, ending with two newlines.
    public static func format(_ segment: SRTSegment, index: Int) -> String {
        var lines: [String] = []
        lines.append("\(index)")
        lines.append("\(srtTimestamp(segment.startSeconds)) --> \(srtTimestamp(segment.endSeconds))")
        lines.append(segment.text)
        lines.append("\n")   // blank line between entries
        return lines.joined(separator: "\n")
    }

    /// Converts a `TimeInterval` (seconds) to the SRT format `HH:MM:SS,mmm`.
    public static func srtTimestamp(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let millis  = Int((clamped.truncatingRemainder(dividingBy: 1)) * 1000)
        let totalS  = Int(clamped)
        let s       = totalS % 60
        let m       = (totalS / 60) % 60
        let h       = totalS / 3600
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, millis)
    }
}
