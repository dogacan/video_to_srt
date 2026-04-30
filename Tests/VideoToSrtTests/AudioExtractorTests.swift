import Testing
import Foundation
@testable import VideoToSrt

struct AudioExtractorTests {

    @Test func testValidateSourceURL() {
        let fileURL = URL(fileURLWithPath: "/tmp/test.mp4")
        let remoteURL = URL(string: "https://example.com/test.mp4")!
        
        #expect(throws: Never.self) {
            try AudioExtractor.validateSourceURL(fileURL)
        }
        
        #expect(throws: AudioExtractionError.invalidInputSource) {
            try AudioExtractor.validateSourceURL(remoteURL)
        }
    }

    @Test func testIsUnsupportedFormat() {
        #expect(AudioExtractor.isUnsupportedFormat("mkv") == true)
        #expect(AudioExtractor.isUnsupportedFormat("webm") == true)
        #expect(AudioExtractor.isUnsupportedFormat("avi") == true)
        #expect(AudioExtractor.isUnsupportedFormat("mp4") == false)
        #expect(AudioExtractor.isUnsupportedFormat("mov") == false)
        #expect(AudioExtractor.isUnsupportedFormat("m4a") == false)
    }

    @Test func testValidateFFmpegPath() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dummyFile = tempDir.appendingPathComponent("not_ffmpeg")
        let dummyDir = tempDir.appendingPathComponent("dummy_dir")
        
        // Create a dummy file and make it executable
        FileManager.default.createFile(atPath: dummyFile.path, contents: nil)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dummyFile.path)
        
        // Create a dummy directory
        try? FileManager.default.createDirectory(at: dummyDir, withIntermediateDirectories: true)
        
        #expect(throws: Never.self) {
            try AudioExtractor.validateFFmpegPath(dummyFile.path)
        }
        
        #expect(throws: AudioExtractionError.audioExportFailed("")) {
            try AudioExtractor.validateFFmpegPath(dummyDir.path)
        }
        
        #expect(throws: AudioExtractionError.audioExportFailed("")) {
            try AudioExtractor.validateFFmpegPath("/non/existent/path")
        }
        
        // Cleanup
        try? FileManager.default.removeItem(at: dummyFile)
        try? FileManager.default.removeItem(at: dummyDir)
    }
}
