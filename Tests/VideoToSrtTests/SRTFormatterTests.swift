import Testing
import Foundation
@testable import VideoToSrt

struct SRTFormatterTests {

    @Test func testSrtTimestamp() {
        #expect(SRTFormatter.srtTimestamp(0.0) == "00:00:00,000")
        #expect(SRTFormatter.srtTimestamp(1.234) == "00:00:01,234")
        #expect(SRTFormatter.srtTimestamp(60.0) == "00:01:00,000")
        #expect(SRTFormatter.srtTimestamp(3600.0) == "01:00:00,000")
        #expect(SRTFormatter.srtTimestamp(3661.001) == "01:01:01,001")
        #expect(SRTFormatter.srtTimestamp(-5.0) == "00:00:00,000") // Clamped to 0
    }

    @Test func testFormatSegment() {
        let segment = SRTSegment(text: "Hello world", startSeconds: 1.0, endSeconds: 5.5)
        let formatted = SRTFormatter.format(segment, index: 1)
        
        let expected = "1\n00:00:01,000 --> 00:00:05,500\nHello world\n\n"
        #expect(formatted == expected)
    }

    @Test func testFormatMultipleSegments() {
        let s1 = SRTSegment(text: "First", startSeconds: 0.0, endSeconds: 2.0)
        let s2 = SRTSegment(text: "Second", startSeconds: 2.5, endSeconds: 4.0)
        
        let f1 = SRTFormatter.format(s1, index: 1)
        let f2 = SRTFormatter.format(s2, index: 2)
        
        #expect(f1.contains("1\n00:00:00,000 --> 00:00:02,000\nFirst\n"))
        #expect(f2.contains("2\n00:00:02,500 --> 00:00:04,000\nSecond\n"))
    }
}
