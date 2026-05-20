import Foundation

/// A common protocol for engine-specific transcription results.
public protocol TranscriptionEngineSegment {
    var transcriptionText: String { get }
    var transcriptionStartTime: Double { get }
    var transcriptionEndTime: Double { get }
}

/// Internal helper to accumulate transcription results into SRT-friendly segments.
public class ResultSegmenter: @unchecked Sendable {
    private let offset: Double
    private let totalDuration: Double
    private let maxSegmentDuration: Double
    private let maxCharactersPerLine: Int
    private let minWordsPerSegment: Int
    private let options: TranscriptionOptions
    
    private static let sentenceEndings: Set<Character> = [".", "?", "!", "…"]
    private static let clauseBoundaries: Set<Character> = [".", "?", "!", "…", ",", ";", ":"]

    private var currentText: String = ""
    private var currentStart: Double?
    private var currentEnd: Double?
    private var lastSpeaker: String?
    private let diarizationMap: DiarizationMap?
    public private(set) var segmentCount: Int = 0
    
    public init(offset: Double, totalDuration: Double, options: TranscriptionOptions) {
        self.offset = offset
        self.totalDuration = totalDuration
        self.options = options
        self.maxSegmentDuration = options.maxSegmentDuration
        self.maxCharactersPerLine = options.maxCharactersPerLine
        self.minWordsPerSegment = options.minWordsPerSegment
        self.diarizationMap = options.diarizationMap
    }
    
    public func process(segment: any TranscriptionEngineSegment) -> [TranscriptionResult] {
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
        
        // 1. Flush before combine if adding this segment would exceed max duration
        if let start = currentStart, !currentText.isEmpty {
            let potentialDuration = endSecs - start
            let wordCount = currentText.split(whereSeparator: { $0.isWhitespace }).count
            var isTooShortToSplit = wordCount < minWordsPerSegment
            
            if let lastChar = currentText.last(where: { !$0.isWhitespace }),
               Self.clauseBoundaries.contains(lastChar) {
                isTooShortToSplit = false
            }
            
            let shouldFlushDuration = potentialDuration > maxSegmentDuration && !isTooShortToSplit
            
            if shouldFlushDuration {
                if let flushed = flush() {
                    results.append(flushed)
                }
            }
        }
        
        // 2. Accumulate
        if currentText.isEmpty {
            currentText = plain
            currentStart = startSecs
            currentEnd = endSecs
        } else {
            if speakerChanged {
                // Speaker changed within the same segment -> format with newline and dash
                currentText += "\n- " + plain
            } else {
                currentText += " " + plain
            }
            currentEnd = endSecs
        }
        
        if let speaker = currentSpeaker {
            lastSpeaker = speaker
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
        let segment = SubtitleSegment(index: segmentCount, text: currentText, startSeconds: start, endSeconds: end)
        let formattedText = SubtitleFormatter.format(segment, format: options.format)
        let progress = totalDuration > 0 ? min(1.0, end / totalDuration) : 0.0
        
        // Reset for next segment
        currentText = ""
        currentStart = nil
        currentEnd = nil
        
        return TranscriptionResult(formattedText: formattedText, progress: progress)
    }
    
    private func shouldFlush() -> Bool {
        guard let start = currentStart, let end = currentEnd else { return false }
        
        let duration = end - start
        
        let wordCount = currentText.split(whereSeparator: { $0.isWhitespace }).count
        var isTooShortToSplit = wordCount < minWordsPerSegment
        
        if let lastChar = currentText.last(where: { !$0.isWhitespace }),
           Self.clauseBoundaries.contains(lastChar) {
            isTooShortToSplit = false
        }
        
        if duration >= maxSegmentDuration && !isTooShortToSplit { return true }
        if currentText.count >= maxCharactersPerLine { return true }
        
        // Punctuation check - avoid trimming the whole string
        if let lastChar = currentText.last(where: { !$0.isWhitespace }),
           Self.sentenceEndings.contains(lastChar) {
            return true
        }
        
        return false
    }
}
