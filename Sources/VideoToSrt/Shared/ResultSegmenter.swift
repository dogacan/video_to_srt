import Foundation

/// A common protocol for engine-specific transcription results.
public protocol TranscriptionSegment {
    var transcriptionText: String { get }
    var transcriptionStartTime: Double { get }
    var transcriptionEndTime: Double { get }
}

/// Internal helper to accumulate transcription results into SRT-friendly segments.
public class ResultSegmenter: @unchecked Sendable {
    private let offset: Double
    private let totalDuration: Double
    private let maxSegmentDuration: Double = 7.0
    private let maxCharactersPerLine: Int = 80
    
    private static let sentenceEndings: Set<Character> = [".", "?", "!", "…"]

    private var currentText: String = ""
    private var currentStart: Double?
    private var currentEnd: Double?
    private var lastSpeaker: String?
    private let diarizationMap: DiarizationMap?
    public private(set) var segmentCount: Int = 0
    
    public init(offset: Double, totalDuration: Double, diarizationMap: DiarizationMap? = nil) {
        self.offset = offset
        self.totalDuration = totalDuration
        self.diarizationMap = diarizationMap
    }
    
    public func process(segment: any TranscriptionSegment) -> [TranscriptionResult] {
        var results: [TranscriptionResult] = []
        
        let plain = segment.transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return [] }
        
        let startSecs = segment.transcriptionStartTime + offset
        let endSecs = segment.transcriptionEndTime + offset
        
        var currentSpeaker: String? = nil
        if let map = diarizationMap {
            currentSpeaker = map.dominantSpeaker(from: startSecs, to: endSecs) ?? lastSpeaker
        }
        
        let speakerChanged = lastSpeaker != nil && currentSpeaker != nil && currentSpeaker != lastSpeaker
        
        // 1. Flush before combine if adding this segment would exceed max duration, OR if speaker changed
        if let start = currentStart, !currentText.isEmpty {
            let potentialDuration = endSecs - start
            if potentialDuration > maxSegmentDuration || speakerChanged {
                if let flushed = flush() {
                    results.append(flushed)
                }
            }
        }
        
        // Setup text with speaker prefix if necessary
        var segmentText = plain
        if let speaker = currentSpeaker {
            if lastSpeaker != nil && speaker != lastSpeaker {
                // Speaker actually changed → prefix with dash
                segmentText = "- " + segmentText
            }
            lastSpeaker = speaker
        }
        
        // 2. Accumulate
        if currentText.isEmpty {
            currentText = segmentText
            currentStart = startSecs
            currentEnd = endSecs
        } else {
            // Add a newline if speaker changed but we didn't flush (e.g. within a short segment)
            // Wait, we DO flush if speakerChanged according to step 1!
            // But just in case, we concatenate with space
            currentText += " " + segmentText
            currentEnd = endSecs
        }
        
        // 3. Flush if now over limit or ends with punctuation
        if shouldFlush() {
            if let flushed = flush() {
                results.append(flushed)
            }
        }
        
        return results
    }
    
    public func flush() -> TranscriptionResult? {
        guard !currentText.isEmpty, let start = currentStart, let end = currentEnd else {
            return nil
        }
        
        segmentCount += 1
        let segment = SRTSegment(text: currentText, startSeconds: start, endSeconds: end)
        let srtText = SRTFormatter.format(segment, index: segmentCount)
        let progress = totalDuration > 0 ? min(1.0, end / totalDuration) : 0.0
        
        // Reset for next segment
        currentText = ""
        currentStart = nil
        currentEnd = nil
        
        return TranscriptionResult(srtText: srtText, progress: progress)
    }
    
    private func shouldFlush() -> Bool {
        guard let start = currentStart, let end = currentEnd else { return false }
        
        let duration = end - start
        if duration >= maxSegmentDuration { return true }
        if currentText.count >= maxCharactersPerLine { return true }
        
        // Punctuation check - avoid trimming the whole string
        if let lastChar = currentText.last(where: { !$0.isWhitespace }),
           Self.sentenceEndings.contains(lastChar) {
            return true
        }
        
        return false
    }
}
