import Foundation

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
        hfToken: String? = nil,
        pythonPath: String = "/usr/bin/env python3",
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

        var wavURLToDelete: URL? = nil
        defer {
            if let url = wavURLToDelete {
                try? FileManager.default.removeItem(at: url)
            }
        }
        
        if diarize {
            print("\nStarting Pyannote Diarization...")
            let wavURL = try await AudioExtractor.extractAudioForDiarization(from: inputURL, ffmpegPath: finalOptions.ffmpegPath)
            wavURLToDelete = wavURL
            
            let tempJSONURL = FileManager.default.temporaryDirectory.appendingPathComponent("diarization_\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: tempJSONURL) }
            
            let scriptURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("scripts/diarize.py")
            
            let process = Process()
            if pythonPath == "/usr/bin/env python3" {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["python3", scriptURL.path, wavURL.path, tempJSONURL.path]
            } else {
                process.executableURL = URL(fileURLWithPath: pythonPath)
                process.arguments = [scriptURL.path, wavURL.path, tempJSONURL.path]
            }
            
            var env = ProcessInfo.processInfo.environment
            if let token = hfToken {
                env["HF_TOKEN"] = token
            }
            process.environment = env
            
            try process.run()
            
            // Wait for completion (could take a while, maybe log progress if python supports it, but for now just wait)
            let cancellationTask = Task {
                while process.isRunning {
                    if Task.isCancelled { process.terminate(); break }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            process.waitUntilExit()
            cancellationTask.cancel()
            
            if process.terminationStatus != 0 {
                throw NSError(domain: "VideoToSrt", code: 2, userInfo: [NSLocalizedDescriptionKey: "Pyannote Diarization failed."])
            }
            
            let map = try DiarizationMap(jsonURL: tempJSONURL)
            finalOptions.diarizationMap = map
            print("Diarization complete. Found \(map.segments.count) speaker segments.")
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
