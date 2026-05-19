import Testing
import Foundation
@testable import VideoToSrt

struct SubtitleParserTests {

    @Test func testParseTimestamp() {
        #expect(SubtitleParser.parseTimestamp("00:01:23,456") == 83.456)
        #expect(SubtitleParser.parseTimestamp("01:00:00.000") == 3600.0)
        #expect(SubtitleParser.parseTimestamp("02:30") == 150.0) // MM:SS
        #expect(SubtitleParser.parseTimestamp("invalid") == nil)
    }

    @Test func testParseSrt() throws {
        let srtContent = """
        1
        00:00:01,000 --> 00:00:03,500
        Hello world

        2
        00:00:03,500 --> 00:00:07,000
        This is a test
        of subtitle parsing.
        """
        
        let segments = try SubtitleParser.parse(srtContent)
        #expect(segments.count == 2)
        
        #expect(segments[0].index == 1)
        #expect(segments[0].startSeconds == 1.0)
        #expect(segments[0].endSeconds == 3.5)
        #expect(segments[0].text == "Hello world")
        
        #expect(segments[1].index == 2)
        #expect(segments[1].startSeconds == 3.5)
        #expect(segments[1].endSeconds == 7.0)
        #expect(segments[1].text == "This is a test\nof subtitle parsing.")
    }

    @Test func testParseVtt() throws {
        let vttContent = """
        WEBVTT

        00:01.000 --> 00:03.500
        First line

        00:00:03.500 --> 00:00:07.000
        Second line
        """
        
        let segments = try SubtitleParser.parse(vttContent)
        #expect(segments.count == 2)
        
        #expect(segments[0].index == 1) // Generated index
        #expect(segments[0].startSeconds == 1.0)
        #expect(segments[0].endSeconds == 3.5)
        #expect(segments[0].text == "First line")
        
        #expect(segments[1].index == 2)
        #expect(segments[1].startSeconds == 3.5)
        #expect(segments[1].endSeconds == 7.0)
        #expect(segments[1].text == "Second line")
    }
}
