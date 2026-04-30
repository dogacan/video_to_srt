import Foundation

/// A common protocol for engine-specific transcription results.
public protocol TranscriptionSegment {
    var transcriptionText: String { get }
    var transcriptionStartTime: Double { get }
    var transcriptionEndTime: Double { get }
}

/// Internal helper to accumulate transcription results into SRT-friendly segments.
public struct ResultSegmenter {
    private let offset: Double
    private let totalDuration: Double
    private let maxSegmentDuration: Double = 5.0
    private let maxCharactersPerLine: Int = 80
    
    private var currentText: String = ""
    private var currentStart: Double?
    private var currentEnd: Double?
    private(set) var segmentCount: Int = 0
    
    public init(offset: Double, totalDuration: Double) {
        self.offset = offset
        self.totalDuration = totalDuration
    }
    
    public mutating func process(segment: any TranscriptionSegment) -> TranscriptionResult? {
        let plain = segment.transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return nil }
        
        let startSecs = segment.transcriptionStartTime + offset
        let endSecs = segment.transcriptionEndTime + offset
        
        if currentText.isEmpty {
            currentText = plain
            currentStart = startSecs
            currentEnd = endSecs
        } else {
            currentText += " " + plain
            currentEnd = endSecs
        }
        
        if shouldFlush() {
            return flush()
        }
        
        return nil
    }
    
    public mutating func flush() -> TranscriptionResult? {
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
        
        // Punctuation check
        let punctuation = CharacterSet.punctuationCharacters
        if let lastChar = currentText.trimmingCharacters(in: .whitespacesAndNewlines).last,
           punctuation.containsUnicodeScalar(lastChar.unicodeScalars.first!) {
            // We want to split on end-of-sentence punctuation mostly
            let sentenceEndings: Set<Character> = [".", "?", "!", "…"]
            if sentenceEndings.contains(lastChar) {
                return true
            }
        }
        
        return false
    }
}

private extension CharacterSet {
    func containsUnicodeScalar(_ scalar: Unicode.Scalar) -> Bool {
        return contains(scalar)
    }
}
