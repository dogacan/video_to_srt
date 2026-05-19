import Foundation

public final class SubtitleTranslator {
    
    private let engine: TranslationEngine
    
    public init(engine: TranslationEngine) {
        self.engine = engine
    }
    
    /// Translates an array of subtitle segments into a target language, keeping timings intact.
    public func translate(_ segments: [SubtitleSegment], sourceLanguageCode: String?, targetLanguageCode: String) async throws -> [SubtitleSegment] {
        if segments.isEmpty { return [] }
        
        // 1. Group segments into sentences
        let groups = groupSegments(segments)
        
        // 2. Prepare combined texts for translation
        let sentencesToTranslate = groups.map { group in
            group.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: " ")
        }
        
        // 3. Translate sentences
        let translatedSentences = try await engine.translate(sentencesToTranslate, sourceLanguageCode: sourceLanguageCode, targetLanguageCode: targetLanguageCode)
        
        // 4. Distribute translated text back into the original segments
        var resultSegments: [SubtitleSegment] = []
        
        for (i, group) in groups.enumerated() {
            let translatedText = i < translatedSentences.count ? translatedSentences[i] : ""
            let distributedTexts = distributeText(translatedText, across: group)
            
            for (j, segment) in group.enumerated() {
                let text = j < distributedTexts.count ? distributedTexts[j] : ""
                resultSegments.append(
                    SubtitleSegment(
                        index: segment.index,
                        text: text,
                        startSeconds: segment.startSeconds,
                        endSeconds: segment.endSeconds
                    )
                )
            }
        }
        
        return resultSegments
    }
    
    // MARK: - Sentence Grouping
    
    private func groupSegments(_ segments: [SubtitleSegment]) -> [[SubtitleSegment]] {
        var groups: [[SubtitleSegment]] = []
        var currentGroup: [SubtitleSegment] = []
        
        let sentenceEndings: Set<Character> = [".", "?", "!", "…"]
        
        for (index, segment) in segments.enumerated() {
            currentGroup.append(segment)
            
            var shouldEnd = false
            
            // Check if segment ends in a sentence boundary punctuation
            let trimmedText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let lastChar = trimmedText.last, sentenceEndings.contains(lastChar) {
                shouldEnd = true
            }
            
            // Check if there is a long pause before the next segment
            if index < segments.count - 1 {
                let nextSegment = segments[index + 1]
                let pause = nextSegment.startSeconds - segment.endSeconds
                if pause > 1.5 {
                    shouldEnd = true
                }
            }
            
            if shouldEnd {
                groups.append(currentGroup)
                currentGroup.removeAll()
            }
        }
        
        if !currentGroup.isEmpty {
            groups.append(currentGroup)
        }
        
        return groups
    }
    
    // MARK: - Proportional Timing Distribution
    
    private func distributeText(_ text: String, across segments: [SubtitleSegment]) -> [String] {
        if segments.isEmpty { return [] }
        if segments.count == 1 { return [text] }
        
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if words.isEmpty {
            return Array(repeating: "", count: segments.count)
        }
        
        let totalDuration = segments.last!.endSeconds - segments.first!.startSeconds
        if totalDuration <= 0 {
            // Equal word split fallback
            let wordsPerSegment = Double(words.count) / Double(segments.count)
            var result: [String] = []
            for i in 0..<segments.count {
                let start = Int(round(Double(i) * wordsPerSegment))
                let end = Int(round(Double(i + 1) * wordsPerSegment))
                let slice = Array(words[start..<min(end, words.count)])
                result.append(slice.joined(separator: " "))
            }
            return result
        }
        
        var result: [String] = []
        var remainingWords = words
        
        for i in 0..<(segments.count - 1) {
            let segment = segments[i]
            let duration = segment.endSeconds - segment.startSeconds
            let ratio = duration / totalDuration
            
            let totalRemainingChars = remainingWords.joined(separator: " ").count
            let targetLength = Double(totalRemainingChars) * ratio
            
            // Find the number of words that gets us closest to the target character length
            var bestWordCount = 0
            var bestDifference = Double.infinity
            
            for k in 0...remainingWords.count {
                let candidateString = remainingWords[0..<k].joined(separator: " ")
                let diff = abs(Double(candidateString.count) - targetLength)
                if diff < bestDifference {
                    bestDifference = diff
                    bestWordCount = k
                } else if candidateString.count > Int(targetLength) {
                    // Difference is increasing, we can stop
                    break
                }
            }
            
            // Make sure we leave at least one word for the remaining segments if possible
            let maxAllowedWords = remainingWords.count - (segments.count - 1 - i)
            let chosenWords = min(max(bestWordCount, 1), max(maxAllowedWords, 0))
            
            let segmentWords = Array(remainingWords[0..<chosenWords])
            result.append(segmentWords.joined(separator: " "))
            remainingWords.removeFirst(chosenWords)
        }
        
        // Add all remaining words to the last segment
        result.append(remainingWords.joined(separator: " "))
        
        return result
    }
}
