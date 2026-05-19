import Testing
import Foundation
@testable import VideoToSrt

struct ResultSegmenterTests {
    
    struct MockSegment: TranscriptionEngineSegment {
        var transcriptionText: String
        var transcriptionStartTime: Double
        var transcriptionEndTime: Double
    }

    @Test func testSegmentCombining() {
        let segmenter = ResultSegmenter(offset: 0, totalDuration: 100, options: .default)
        
        // 1. Add a short segment
        let res1 = segmenter.process(segment: MockSegment(transcriptionText: "Hello", transcriptionStartTime: 0.0, transcriptionEndTime: 2.0))
        #expect(res1.isEmpty)
        
        // 2. Add another short segment that keeps it under 7s
        let res2 = segmenter.process(segment: MockSegment(transcriptionText: "world", transcriptionStartTime: 2.0, transcriptionEndTime: 4.0))
        #expect(res2.isEmpty)
        
        // 3. Add punctuation to flush
        let res3 = segmenter.process(segment: MockSegment(transcriptionText: "!", transcriptionStartTime: 4.0, transcriptionEndTime: 4.1))
        #expect(res3.count == 1)
        #expect(res3[0].formattedText.contains("Hello world !"))
    }
    
    @Test func testFlushBeforeCombine() {
        let segmenter = ResultSegmenter(offset: 0, totalDuration: 100, options: .default)
        
        // Add 4s segment
        _ = segmenter.process(segment: MockSegment(transcriptionText: "Start", transcriptionStartTime: 0.0, transcriptionEndTime: 4.0))
        
        // Add 4s segment. Total would be 8s (> 7s).
        // It should flush "Start" first, then "Next" should be its own segment (or buffered).
        let results = segmenter.process(segment: MockSegment(transcriptionText: "Next", transcriptionStartTime: 4.0, transcriptionEndTime: 8.0))
        
        #expect(results.count == 1)
        #expect(results[0].formattedText.contains("00:00:00,000 --> 00:00:04,000"))
        #expect(results[0].formattedText.contains("Start"))
        
        // Flush remaining
        if let final = segmenter.flush() {
            #expect(final.formattedText.contains("00:00:04,000 --> 00:00:08,000"))
            #expect(final.formattedText.contains("Next"))
        } else {
            Issue.record("Expected final segment to be non-nil")
        }
    }
    
    @Test func testSingleLongSegment() {
        let segmenter = ResultSegmenter(offset: 0, totalDuration: 100, options: .default)
        
        // A single 10s segment should be flushed immediately.
        let results = segmenter.process(segment: MockSegment(transcriptionText: "Long", transcriptionStartTime: 0.0, transcriptionEndTime: 10.0))
        
        #expect(results.count == 1)
        #expect(results[0].formattedText.contains("00:00:00,000 --> 00:00:10,000"))
    }

    @Test func testMultipleFlushesInOneProcess() {
        let segmenter = ResultSegmenter(offset: 0, totalDuration: 100, options: .default)
        
        // Add 4s segment
        _ = segmenter.process(segment: MockSegment(transcriptionText: "Start", transcriptionStartTime: 0.0, transcriptionEndTime: 4.0))
        
        // Add 8s segment. 
        // 1. "Start" is flushed because 4+8=12 > 7.
        // 2. "Very long addition" is added. It's 8s > 7s, so it's also flushed immediately.
        let results = segmenter.process(segment: MockSegment(transcriptionText: "Very long addition", transcriptionStartTime: 4.0, transcriptionEndTime: 12.0))
        
        #expect(results.count == 2)
        #expect(results[0].formattedText.contains("00:00:00,000 --> 00:00:04,000"))
        #expect(results[1].formattedText.contains("00:00:04,000 --> 00:00:12,000"))
    }

    @Test func testCustomLayoutConstraints() {
        let options = TranscriptionOptions(maxCharactersPerLine: 10, maxSegmentDuration: 3.0)
        let segmenter = ResultSegmenter(offset: 0, totalDuration: 100, options: options)

        // 1. Check max duration limit (3.0s)
        // Add a 4.0s segment, it should flush immediately because 4.0s > 3.0s limit
        let res1 = segmenter.process(segment: MockSegment(transcriptionText: "Short", transcriptionStartTime: 0.0, transcriptionEndTime: 4.0))
        #expect(res1.count == 1)
        #expect(res1[0].formattedText.contains("Short"))

        // 2. Check max CPL limit (10 characters)
        // Add a 2s segment with a 15-char string, it should flush immediately because 15 > 10 CPL
        let res2 = segmenter.process(segment: MockSegment(transcriptionText: "HelloVeryLongWord", transcriptionStartTime: 4.0, transcriptionEndTime: 6.0))
        #expect(res2.count == 1)
        #expect(res2[0].formattedText.contains("HelloVeryLongWord"))
    }

    @Test func testMinWordsConstraint() {
        let options = TranscriptionOptions(maxSegmentDuration: 3.0, minWordsPerSegment: 3)
        let segmenter = ResultSegmenter(offset: 0, totalDuration: 100, options: options)

        // Word 1: duration 1.0s, cumulative: 0.0s to 1.0s. (1 word)
        let res1 = segmenter.process(segment: MockSegment(transcriptionText: "One", transcriptionStartTime: 0.0, transcriptionEndTime: 1.0))
        #expect(res1.isEmpty)

        // Word 2: duration 1.0s, cumulative: 2.0s to 3.0s. (2 words)
        // Potential duration when adding this: 3.0s - 0.0s = 3.0s.
        // It should NOT flush before combine because wordCount (1) < 3.
        // It is accumulated.
        // shouldFlush check: duration = 3.0 >= 3.0, but wordCount (2) < 3, so it should NOT flush.
        let res2 = segmenter.process(segment: MockSegment(transcriptionText: "Two", transcriptionStartTime: 2.0, transcriptionEndTime: 3.0))
        #expect(res2.isEmpty)

        // Word 3: duration 1.0s, cumulative: 4.0s to 5.0s. (3 words)
        // Potential duration: 5.0s - 0.0s = 5.0s > 3.0s.
        // It should NOT flush before combine because wordCount (2) < 3.
        // It is accumulated.
        // shouldFlush check: duration = 5.0 >= 3.0, and wordCount (3) >= 3, so it SHOULD flush!
        let res3 = segmenter.process(segment: MockSegment(transcriptionText: "Three", transcriptionStartTime: 4.0, transcriptionEndTime: 5.0))
        #expect(res3.count == 1)
        #expect(res3[0].formattedText.contains("One Two Three"))
        #expect(res3[0].formattedText.contains("00:00:00,000 --> 00:00:05,000"))

        // Word 4: duration 1.0s, cumulative: 6.0s to 7.0s. (1 word)
        let res4 = segmenter.process(segment: MockSegment(transcriptionText: "Four", transcriptionStartTime: 6.0, transcriptionEndTime: 7.0))
        #expect(res4.isEmpty)

        // Word 5: ends with punctuation, cumulative: 8.0s to 9.0s. (2 words)
        // Even though wordCount is 2 (< 3), the punctuation should trigger shouldFlush().
        let res5 = segmenter.process(segment: MockSegment(transcriptionText: "Five.", transcriptionStartTime: 8.0, transcriptionEndTime: 9.0))
        #expect(res5.count == 1)
        #expect(res5[0].formattedText.contains("Four Five."))
        #expect(res5[0].formattedText.contains("00:00:06,000 --> 00:00:09,000"))
    }

    @Test func testClauseBoundaryMinWords() {
        let options = TranscriptionOptions(maxSegmentDuration: 3.0, minWordsPerSegment: 3)
        let segmenter = ResultSegmenter(offset: 0, totalDuration: 100, options: options)

        // Add "That's" (1 word)
        let r1 = segmenter.process(segment: MockSegment(transcriptionText: "That's", transcriptionStartTime: 0.0, transcriptionEndTime: 1.0))
        #expect(r1.isEmpty)

        // Add "OK," (2 words, ends with comma clause boundary, cumulative duration: 2.0s < 3.0s)
        let r2 = segmenter.process(segment: MockSegment(transcriptionText: "OK,", transcriptionStartTime: 1.5, transcriptionEndTime: 2.0))
        #expect(r2.isEmpty)

        // Add "we" (potential duration: 4.0 - 0.0 = 4.0 > 3.0).
        // Since "That's OK," ends in a clause boundary comma, we should allow splitting it even though it has only 2 words (< 3).
        // So "That's OK," is flushed before "we" is combined.
        let r3 = segmenter.process(segment: MockSegment(transcriptionText: "we", transcriptionStartTime: 3.5, transcriptionEndTime: 4.0))
        #expect(r3.count == 1)
        #expect(r3[0].formattedText.contains("That's OK,"))
        #expect(r3[0].formattedText.contains("00:00:00,000 --> 00:00:02,000"))
        
        // Add "will" (2 words under "we", cumulative duration: 5.0 - 3.5 = 1.5s < 3.0s)
        let r4 = segmenter.process(segment: MockSegment(transcriptionText: "will", transcriptionStartTime: 4.5, transcriptionEndTime: 5.0))
        #expect(r4.isEmpty)
        
        // Flush remaining
        if let final = segmenter.flush() {
            #expect(final.formattedText.contains("we will"))
            #expect(final.formattedText.contains("00:00:03,500 --> 00:00:05,000"))
        } else {
            Issue.record("Expected final segment to be non-nil")
        }
    }
}
