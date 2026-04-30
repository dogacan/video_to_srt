import Testing
import Foundation
@testable import VideoToSrt

struct ResultSegmenterTests {
    
    struct MockSegment: TranscriptionSegment {
        var transcriptionText: String
        var transcriptionStartTime: Double
        var transcriptionEndTime: Double
    }

    @Test func testSegmentCombining() {
        var segmenter = ResultSegmenter(offset: 0, totalDuration: 100)
        
        // 1. Add a short segment
        let res1 = segmenter.process(segment: MockSegment(transcriptionText: "Hello", transcriptionStartTime: 0.0, transcriptionEndTime: 2.0))
        #expect(res1.isEmpty)
        
        // 2. Add another short segment that keeps it under 7s
        let res2 = segmenter.process(segment: MockSegment(transcriptionText: "world", transcriptionStartTime: 2.0, transcriptionEndTime: 4.0))
        #expect(res2.isEmpty)
        
        // 3. Add punctuation to flush
        let res3 = segmenter.process(segment: MockSegment(transcriptionText: "!", transcriptionStartTime: 4.0, transcriptionEndTime: 4.1))
        #expect(res3.count == 1)
        #expect(res3[0].srtText.contains("Hello world !"))
    }
    
    @Test func testFlushBeforeCombine() {
        var segmenter = ResultSegmenter(offset: 0, totalDuration: 100)
        
        // Add 4s segment
        _ = segmenter.process(segment: MockSegment(transcriptionText: "Start", transcriptionStartTime: 0.0, transcriptionEndTime: 4.0))
        
        // Add 4s segment. Total would be 8s (> 7s).
        // It should flush "Start" first, then "Next" should be its own segment (or buffered).
        let results = segmenter.process(segment: MockSegment(transcriptionText: "Next", transcriptionStartTime: 4.0, transcriptionEndTime: 8.0))
        
        #expect(results.count == 1)
        #expect(results[0].srtText.contains("00:00:00,000 --> 00:00:04,000"))
        #expect(results[0].srtText.contains("Start"))
        
        // Flush remaining
        if let final = segmenter.flush() {
            #expect(final.srtText.contains("00:00:04,000 --> 00:00:08,000"))
            #expect(final.srtText.contains("Next"))
        } else {
            Issue.record("Expected final segment to be non-nil")
        }
    }
    
    @Test func testSingleLongSegment() {
        var segmenter = ResultSegmenter(offset: 0, totalDuration: 100)
        
        // A single 10s segment should be flushed immediately.
        let results = segmenter.process(segment: MockSegment(transcriptionText: "Long", transcriptionStartTime: 0.0, transcriptionEndTime: 10.0))
        
        #expect(results.count == 1)
        #expect(results[0].srtText.contains("00:00:00,000 --> 00:00:10,000"))
    }

    @Test func testMultipleFlushesInOneProcess() {
        var segmenter = ResultSegmenter(offset: 0, totalDuration: 100)
        
        // Add 4s segment
        _ = segmenter.process(segment: MockSegment(transcriptionText: "Start", transcriptionStartTime: 0.0, transcriptionEndTime: 4.0))
        
        // Add 8s segment. 
        // 1. "Start" is flushed because 4+8=12 > 7.
        // 2. "Very long addition" is added. It's 8s > 7s, so it's also flushed immediately.
        let results = segmenter.process(segment: MockSegment(transcriptionText: "Very long addition", transcriptionStartTime: 4.0, transcriptionEndTime: 12.0))
        
        #expect(results.count == 2)
        #expect(results[0].srtText.contains("00:00:00,000 --> 00:00:04,000"))
        #expect(results[1].srtText.contains("00:00:04,000 --> 00:00:12,000"))
    }
}
