import Testing
import Foundation
@testable import VideoToSrt

struct SubtitleFormatterTests {

    @Test func testSrtTimestamp() {
        #expect(SubtitleFormatter.srtTimestamp(0.0) == "00:00:00,000")
        #expect(SubtitleFormatter.srtTimestamp(1.234) == "00:00:01,234")
        #expect(SubtitleFormatter.srtTimestamp(60.0) == "00:01:00,000")
        #expect(SubtitleFormatter.srtTimestamp(3600.0) == "01:00:00,000")
        #expect(SubtitleFormatter.srtTimestamp(3661.001) == "01:01:01,001")
        #expect(SubtitleFormatter.srtTimestamp(-5.0) == "00:00:00,000") // Clamped to 0
    }

    @Test func testVttTimestamp() {
        #expect(SubtitleFormatter.vttTimestamp(0.0) == "00:00:00.000")
        #expect(SubtitleFormatter.vttTimestamp(1.234) == "00:00:01.234")
        #expect(SubtitleFormatter.vttTimestamp(60.0) == "00:01:00.000")
        #expect(SubtitleFormatter.vttTimestamp(3600.0) == "01:00:00.000")
        #expect(SubtitleFormatter.vttTimestamp(3661.001) == "01:01:01.001")
        #expect(SubtitleFormatter.vttTimestamp(-5.0) == "00:00:00.000") // Clamped to 0
    }

    @Test func testFormatSegmentSRT() {
        let segment = SubtitleSegment(index: 1, text: "Hello world", startSeconds: 1.0, endSeconds: 5.5)
        let formatted = SubtitleFormatter.format(segment, format: .srt)
        
        let expected = "1\n00:00:01,000 --> 00:00:05,500\nHello world\n\n"
        #expect(formatted == expected)
    }

    @Test func testFormatSegmentVTT() {
        let segment = SubtitleSegment(index: 1, text: "Hello world", startSeconds: 1.0, endSeconds: 5.5)
        let formatted = SubtitleFormatter.format(segment, format: .vtt)
        
        let expected = "1\n00:00:01.000 --> 00:00:05.500\nHello world\n\n"
        #expect(formatted == expected)
    }

    @Test func testFormatSegmentTXT() {
        let segment = SubtitleSegment(index: 1, text: "Hello world", startSeconds: 1.0, endSeconds: 5.5)
        let formatted = SubtitleFormatter.format(segment, format: .txt)
        
        #expect(formatted == "Hello world\n")
    }

    @Test func testFormatSegmentJSON() {
        let segment = SubtitleSegment(index: 1, text: "Hello world", startSeconds: 1.0, endSeconds: 5.5)
        let formatted = SubtitleFormatter.format(segment, format: .json)
        
        // Assert json structure
        #expect(formatted.contains("\"endSeconds\":5.5"))
        #expect(formatted.contains("\"index\":1"))
        #expect(formatted.contains("\"startSeconds\":1"))
        #expect(formatted.contains("\"text\":\"Hello world\""))
    }
}
