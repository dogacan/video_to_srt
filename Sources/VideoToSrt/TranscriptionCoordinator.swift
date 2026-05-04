import Foundation
import SpeechVAD

/// The central orchestrator for the transcription process.
///
/// `TranscriptionCoordinator` is responsible for managing the high-level workflow of transcribing a file:
/// 1. Validating the output environment (ensuring directories exist and are writable).
/// 2. Executing the transcription via a provided ``TranscriptionEngine``.
/// 3. Handling real-time progress updates via a callback.
/// 4. Persisting the final SRT text to the filesystem.
///
/// This coordinator decouples the CLI interface from the business logic of transcription and file management.
public struct TranscriptionCoordinator {
    public init() {}

    public func transcribe(
        inputURL: URL,
        outputURL: URL,
        engine: any TranscriptionEngine,
        options: TranscriptionOptions,
        diarize: Bool = false,
        vadModelId: String = "aufklarer/Pyannote-Segmentation-MLX",
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        var finalOptions = options
        let outputDir = outputURL.deletingLastPathComponent()
        
        try FileManager.default.createDirectory(
            at: outputDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        guard FileManager.default.isWritableFile(atPath: outputDir.path) else {
            throw NSError(domain: "VideoToSrt", code: 1, userInfo: [NSLocalizedDescriptionKey: "Output directory '\(outputDir.path)' is not writable."])
        }

        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: nil)

        let fileHandle = try FileHandle(forWritingTo: outputURL)
        defer {
            try? fileHandle.close()
        }


        if diarize {
            print("\nStarting Native Swift Diarization with SpeechVAD...")
            let audio16k = try await AudioExtractor.extractAudioFloat(from: inputURL, targetSampleRate: 16000.0, ffmpegPath: finalOptions.ffmpegPath)
            
            let diarizer = try await DiarizationPipeline.fromPretrained(segModelId: vadModelId)
            let speechSegments = diarizer.diarize(audio: audio16k, sampleRate: 16000)
            
            let mappedSegments = speechSegments.map { segment in
                SpeakerSegment(
                    start: Double(segment.startTime),
                    end: Double(segment.endTime),
                    speaker: "SPEAKER_\(String(format: "%02d", segment.speakerId))"
                )
            }
            
            let map = DiarizationMap(segments: mappedSegments)
            finalOptions.diarizationMap = map
            print("Native Diarization complete. Found \(map.segments.count) speaker segments.")
        }

        let stream = engine.transcribe(fileURL: inputURL, options: finalOptions)
        
        for try await result in stream {
            if let data = result.srtText.data(using: .utf8) {
                try fileHandle.write(contentsOf: data)
            }
            progressHandler(result.progress)
        }
    }
}
