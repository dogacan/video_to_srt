import Testing
import Foundation
@testable import VideoToSrt

struct TranscriptionCoordinatorTests {

    class MockTranscriptionEngine: TranscriptionEngine {
        var segmentsToEmit: [TranscriptionResult] = []
        var errorToThrow: Error?
        var lastOptions: TranscriptionOptions?

        func transcribe(fileURL: URL, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionResult, Error> {
            self.lastOptions = options
            return AsyncThrowingStream { continuation in
                if let error = errorToThrow {
                    continuation.finish(throwing: error)
                    return
                }
                for segment in segmentsToEmit {
                    continuation.yield(segment)
                }
                continuation.finish()
            }
        }
    }

    @Test func testSuccessfulTranscription() async throws {
        let coordinator = TranscriptionCoordinator()
        let engine = MockTranscriptionEngine()
        
        let srt1 = "1\n00:00:00,000 --> 00:00:02,000\nHello\n\n"
        let srt2 = "2\n00:00:02,000 --> 00:00:04,000\nWorld\n\n"
        
        engine.segmentsToEmit = [
            TranscriptionResult(srtText: srt1, progress: 0.5),
            TranscriptionResult(srtText: srt2, progress: 1.0)
        ]
        
        let tempDir = FileManager.default.temporaryDirectory
        let inputURL = tempDir.appendingPathComponent("input.mp4")
        let outputURL = tempDir.appendingPathComponent("output.srt")
        
        // Clean up before test
        try? FileManager.default.removeItem(at: outputURL)
        
        var progressValues: [Double] = []
        let options = TranscriptionOptions(ffmpegPath: "/usr/local/bin/ffmpeg")
        
        try await coordinator.transcribe(
            inputURL: inputURL,
            outputURL: outputURL,
            engine: engine,
            options: options
        ) { progress in
            progressValues.append(progress)
        }
        
        #expect(progressValues == [0.5, 1.0])
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        
        let content = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(content == srt1 + srt2)
        
        // Cleanup
        try? FileManager.default.removeItem(at: outputURL)
    }

    @Test func testTranscriptionError() async throws {
        let coordinator = TranscriptionCoordinator()
        let engine = MockTranscriptionEngine()
        engine.errorToThrow = NSError(domain: "Test", code: 123, userInfo: [NSLocalizedDescriptionKey: "Mock Error"])
        
        let tempDir = FileManager.default.temporaryDirectory
        let inputURL = tempDir.appendingPathComponent("input.mp4")
        let outputURL = tempDir.appendingPathComponent("output.srt")
        
        await #expect(throws: Error.self) {
            try await coordinator.transcribe(
                inputURL: inputURL,
                outputURL: outputURL,
                engine: engine,
                options: TranscriptionOptions(),
                progressHandler: { _ in }
            )
        }
    }
}
