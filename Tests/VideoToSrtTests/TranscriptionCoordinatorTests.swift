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

    @Test func testSuccessfulTranscriptionSRT() async throws {
        let coordinator = TranscriptionCoordinator()
        let engine = MockTranscriptionEngine()
        
        let srt1 = "1\n00:00:00,000 --> 00:00:02,000\nHello\n\n"
        let srt2 = "2\n00:00:02,000 --> 00:00:04,000\nWorld\n\n"
        
        engine.segmentsToEmit = [
            TranscriptionResult(formattedText: srt1, progress: 0.5),
            TranscriptionResult(formattedText: srt2, progress: 1.0)
        ]
        
        let tempDir = FileManager.default.temporaryDirectory
        let inputURL = tempDir.appendingPathComponent("input.mp4")
        let outputURL = tempDir.appendingPathComponent("output_srt_\(UUID().uuidString).srt")
        
        // Clean up before test
        try? FileManager.default.removeItem(at: outputURL)
        
        var progressValues: [Double] = []
        let options = TranscriptionOptions(ffmpegPath: "/usr/local/bin/ffmpeg", format: .srt)
        
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

    @Test func testSuccessfulTranscriptionVTT() async throws {
        let coordinator = TranscriptionCoordinator()
        let engine = MockTranscriptionEngine()
        
        let vtt1 = "1\n00:00:00.000 --> 00:00:02.000\nHello\n\n"
        let vtt2 = "2\n00:00:02.000 --> 00:00:04.000\nWorld\n\n"
        
        engine.segmentsToEmit = [
            TranscriptionResult(formattedText: vtt1, progress: 0.5),
            TranscriptionResult(formattedText: vtt2, progress: 1.0)
        ]
        
        let tempDir = FileManager.default.temporaryDirectory
        let inputURL = tempDir.appendingPathComponent("input.mp4")
        let outputURL = tempDir.appendingPathComponent("output_vtt_\(UUID().uuidString).vtt")
        
        try? FileManager.default.removeItem(at: outputURL)
        
        let options = TranscriptionOptions(format: .vtt)
        
        try await coordinator.transcribe(
            inputURL: inputURL,
            outputURL: outputURL,
            engine: engine,
            options: options
        ) { _ in }
        
        let content = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(content == "WEBVTT\n\n" + vtt1 + vtt2)
        
        try? FileManager.default.removeItem(at: outputURL)
    }

    @Test func testSuccessfulTranscriptionJSON() async throws {
        let coordinator = TranscriptionCoordinator()
        let engine = MockTranscriptionEngine()
        
        let json1 = "{\"index\":1,\"text\":\"Hello\"}"
        let json2 = "{\"index\":2,\"text\":\"World\"}"
        
        engine.segmentsToEmit = [
            TranscriptionResult(formattedText: json1, progress: 0.5),
            TranscriptionResult(formattedText: json2, progress: 1.0)
        ]
        
        let tempDir = FileManager.default.temporaryDirectory
        let inputURL = tempDir.appendingPathComponent("input.mp4")
        let outputURL = tempDir.appendingPathComponent("output_json_\(UUID().uuidString).json")
        
        try? FileManager.default.removeItem(at: outputURL)
        
        let options = TranscriptionOptions(format: .json)
        
        try await coordinator.transcribe(
            inputURL: inputURL,
            outputURL: outputURL,
            engine: engine,
            options: options
        ) { _ in }
        
        let content = try String(contentsOf: outputURL, encoding: .utf8)
        let expected = "[\n\(json1),\n\(json2)\n]\n"
        #expect(content == expected)
        
        try? FileManager.default.removeItem(at: outputURL)
    }

    @Test func testTranscriptionError() async throws {
        let coordinator = TranscriptionCoordinator()
        let engine = MockTranscriptionEngine()
        engine.errorToThrow = NSError(domain: "Test", code: 123, userInfo: [NSLocalizedDescriptionKey: "Mock Error"])
        
        let tempDir = FileManager.default.temporaryDirectory
        let inputURL = tempDir.appendingPathComponent("input.mp4")
        let outputURL = tempDir.appendingPathComponent("output_err_\(UUID().uuidString).srt")
        
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
