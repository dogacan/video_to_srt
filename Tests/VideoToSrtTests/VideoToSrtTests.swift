import Testing
import Foundation
@testable import VideoToSrt

struct VideoToSrtTests {
    private var samplesURL: URL {
        // Bundle.module is available because we added resources to Package.swift
        return Bundle.module.resourceURL!.appendingPathComponent("samples")
    }

    /// Path to ffmpeg for ogg/wav fallback if needed.
    private let ffmpegPath = "/opt/homebrew/bin/ffmpeg"

    @Test func testGwbColumbiaApple() async throws {
        try await runTranscriptionTest(audioName: "gwb_columbia.ogg", srtName: "gwb_columbia.srt", engine: AppleTranscriptionEngine())
    }

    @Test func testMicroMachinesApple() async throws {
        try await runTranscriptionTest(audioName: "micro_machines.wav", srtName: "micro_machines.srt", engine: AppleTranscriptionEngine())
    }

    @Test func testGwbColumbiaWhisper() async throws {
        let modelURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // VideoToSrtTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // root/
            .appendingPathComponent("models")
            .appendingPathComponent("ggml-base.bin")
        let options = TranscriptionOptions(locale: Locale(identifier: "en"), ffmpegPath: ffmpegPath, whisperModelPath: modelURL.path)
        try await runTranscriptionTest(
            audioName: "gwb_columbia.ogg",
            srtName: "gwb_columbia.srt",
            engine: WhisperTranscriptionEngine(),
            options: options,
            matchThreshold: 0.85
        )
    }

    @Test func testMicroMachinesWhisper() async throws {
        let modelURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // VideoToSrtTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // root/
            .appendingPathComponent("models")
            .appendingPathComponent("ggml-base.bin")
        let options = TranscriptionOptions(locale: Locale(identifier: "en"), ffmpegPath: ffmpegPath, whisperModelPath: modelURL.path)
        try await runTranscriptionTest(
            audioName: "micro_machines.wav",
            srtName: "micro_machines.srt",
            engine: WhisperTranscriptionEngine(),
            options: options,
            matchThreshold: 0.55
        )
    }

    private func runTranscriptionTest(
        audioName: String,
        srtName: String,
        engine: TranscriptionEngine,
        options: TranscriptionOptions? = nil,
        matchThreshold: Double = 0.98
    ) async throws {
        let audioURL = samplesURL.appendingPathComponent(audioName)
        let goldenSRTURL = samplesURL.appendingPathComponent(srtName)
        
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            Issue.record("Sample file missing: \(audioURL.path)")
            return
        }
        guard FileManager.default.fileExists(atPath: goldenSRTURL.path) else {
            Issue.record("Golden SRT missing: \(goldenSRTURL.path)")
            return
        }

        let goldenSRT = try String(contentsOf: goldenSRTURL, encoding: .utf8)
        
        let testOptions = options ?? TranscriptionOptions(ffmpegPath: ffmpegPath)
        
        var transcript = ""
        let stream = engine.transcribe(fileURL: audioURL, options: testOptions)
        
        for try await result in stream {
            transcript += result.srtText
        }
        
        // Normalize and compare content-only with some tolerance for non-deterministic speech recognition jitter.
        let actualWords = extractWords(transcript)
        let expectedWords = extractWords(goldenSRT)
        
        let similarity = wordSimilarity(actual: actualWords, expected: expectedWords)
        #expect(similarity >= matchThreshold, "Transcription text for \(audioName) with \(type(of: engine)) is only \(String(format: "%.1f", similarity * 100))% similar to golden data (expected >= \(matchThreshold * 100)%).")
    }

    private func wordSimilarity(actual: [String], expected: [String]) -> Double {
        // Simple word-by-word similarity (intersection / max count)
        // This is a rough approximation but good enough for regression testing against non-deterministic engines.
        if actual == expected { return 1.0 }
        if actual.isEmpty || expected.isEmpty { return 0.0 }
        
        var actualCounts: [String: Int] = [:]
        for w in actual { actualCounts[w, default: 0] += 1 }
        
        var commonCount = 0
        for w in expected {
            if let count = actualCounts[w], count > 0 {
                commonCount += 1
                actualCounts[w] = count - 1
            }
        }
        
        return Double(commonCount) / Double(max(actual.count, expected.count))
    }

    private func extractWords(_ text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        let contentLines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return false }
            if Int(trimmed) != nil { return false } // SRT index
            if trimmed.contains("-->") { return false } // SRT timestamp
            return true
        }
        let fullText = contentLines.joined(separator: " ")
        return fullText.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
