import Foundation

/// Represents a single subtitle entry.
public struct SubtitleSegment: Sendable, Codable {
    public let index: Int
    public let text: String
    public let startSeconds: Double
    public let endSeconds: Double

    public init(index: Int, text: String, startSeconds: Double, endSeconds: Double) {
        self.index = index
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

/// A utility for converting raw transcription timing and text into various subtitle/transcription formats.
public enum SubtitleFormatter {
    /// Formats a single subtitle segment based on the requested format.
    ///
    /// - Parameters:
    ///   - segment: The segment data (text, start, end).
    ///   - format: The output subtitle format.
    /// - Returns: A string representation of this segment.
    public static func format(_ segment: SubtitleSegment, format: SubtitleFormat) -> String {
        switch format {
        case .srt:
            return formatSRT(segment)
        case .vtt:
            return formatVTT(segment)
        case .txt:
            return formatTXT(segment)
        case .json:
            return formatJSON(segment)
        }
    }

    private static func formatSRT(_ segment: SubtitleSegment) -> String {
        var lines: [String] = []
        lines.append("\(segment.index)")
        lines.append("\(srtTimestamp(segment.startSeconds)) --> \(srtTimestamp(segment.endSeconds))")
        lines.append(segment.text)
        lines.append("\n")   // blank line between entries
        return lines.joined(separator: "\n")
    }

    private static func formatVTT(_ segment: SubtitleSegment) -> String {
        var lines: [String] = []
        lines.append("\(segment.index)")
        lines.append("\(vttTimestamp(segment.startSeconds)) --> \(vttTimestamp(segment.endSeconds))")
        lines.append(segment.text)
        lines.append("\n")   // blank line between entries
        return lines.joined(separator: "\n")
    }

    private static func formatTXT(_ segment: SubtitleSegment) -> String {
        return segment.text + "\n"
    }

    private static func formatJSON(_ segment: SubtitleSegment) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(segment),
           let jsonString = String(data: data, encoding: .utf8) {
            return jsonString
        }
        return ""
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

    /// Converts a `TimeInterval` (seconds) to the WebVTT format `HH:MM:SS.mmm`.
    public static func vttTimestamp(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let millis  = Int((clamped.truncatingRemainder(dividingBy: 1)) * 1000)
        let totalS  = Int(clamped)
        let s       = totalS % 60
        let m       = (totalS / 60) % 60
        let h       = totalS / 3600
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, millis)
    }
}
