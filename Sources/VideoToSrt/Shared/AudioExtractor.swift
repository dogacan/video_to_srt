import Foundation
@preconcurrency import AVFoundation
import os

public enum AudioExtractionError: Error, LocalizedError {
    case assetNotReadable(Error?)
    case unsupportedMediaFormat(String)
    case audioExportFailed(String)
    case noAudioTrack
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .assetNotReadable(let underlyingError):
            if let error = underlyingError {
                return "The media file could not be read: \(error.localizedDescription)"
            }
            return "The media file could not be read."
        case .unsupportedMediaFormat(let format):
            return "The media format '.\(format)' is not natively supported by Apple's AVFoundation. Please convert the file or provide an ffmpeg path."
        case .audioExportFailed(let reason):
            return "Audio export failed: \(reason)"
        case .noAudioTrack:
            return "The file does not contain a readable audio track."
        case .conversionFailed(let reason):
            return "Audio conversion failed: \(reason)"
        }
    }
}

public struct AudioExtractor {
    private static let logger = Logger(subsystem: "com.video_to_srt", category: "AudioExtractor")

    // MARK: - API for Apple Engine

    /// Exports the audio track(s) from a video or audio file into a temporary
    /// Core Audio Format (`.caf`) file that `AVAudioFile` can open directly.
    public static func extractAudioForApple(from sourceURL: URL, ffmpegPath: String?) throws -> URL {
        var inputURL = sourceURL
        var ffmpegGeneratedURL: URL? = nil
        
        defer {
            if let url = ffmpegGeneratedURL {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let ext = sourceURL.pathExtension.lowercased()
        if ext == "mkv" || ext == "webm" || ext == "avi" {
            if let ffmpeg = ffmpegPath {
                ffmpegGeneratedURL = try runFFmpeg(from: sourceURL, ffmpegPath: ffmpeg, codec: "copy")
                inputURL = ffmpegGeneratedURL!
            } else {
                throw AudioExtractionError.unsupportedMediaFormat(ext)
            }
        }

        let initialAsset = AVURLAsset(url: inputURL)
        var selectedAsset = initialAsset

        do {
            let isReadable = try wait { try await initialAsset.load(.isReadable) }
            guard isReadable else {
                throw AudioExtractionError.assetNotReadable(nil)
            }
        } catch {
            if let avError = error as? AVError, avError.code == .fileFormatNotRecognized, ffmpegGeneratedURL == nil {
                if let ffmpeg = ffmpegPath {
                    ffmpegGeneratedURL = try runFFmpeg(from: sourceURL, ffmpegPath: ffmpeg, codec: "copy")
                    inputURL = ffmpegGeneratedURL!
                    let fallbackAsset = AVURLAsset(url: inputURL)
                    
                    let isReadable = try wait { try await fallbackAsset.load(.isReadable) }
                    guard isReadable else {
                        throw AudioExtractionError.assetNotReadable(nil)
                    }
                    selectedAsset = fallbackAsset
                } else {
                    throw AudioExtractionError.unsupportedMediaFormat(ext.isEmpty ? "unknown" : ext)
                }
            } else {
                throw AudioExtractionError.assetNotReadable(error)
            }
        }

        let workingAsset = selectedAsset

        let audioTracks = try wait { try await workingAsset.loadTracks(withMediaType: .audio) }
        guard !audioTracks.isEmpty else {
            throw AudioExtractionError.noAudioTrack
        }

        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("video_to_srt_\(UUID().uuidString).caf")

        guard let session = AVAssetExportSession(asset: workingAsset, presetName: AVAssetExportPresetPassthrough) else {
            throw AudioExtractionError.audioExportFailed("Could not create AVAssetExportSession.")
        }
        session.outputFileType = .caf
        session.outputURL = tempURL
        
        let composition = AVMutableComposition()
        let duration = try wait { try await workingAsset.load(.duration) }
        for track in audioTracks {
            if let compTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
            }
        }

        guard let composedSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioExtractionError.audioExportFailed("Could not create export session for composition.")
        }
        let m4aURL = tempDir.appendingPathComponent("video_to_srt_\(UUID().uuidString).m4a")
        composedSession.outputFileType = .m4a
        try wait { try await composedSession.export(to: m4aURL, as: .m4a) }

        return m4aURL
    }

    // MARK: - API for Whisper Engine

    /// Extracts and resamples audio to 16kHz, mono, 16-bit PCM for Whisper.
    public static func extractAudioForWhisper(from sourceURL: URL, ffmpegPath: String?) throws -> [Float] {
        var inputURL = sourceURL
        var ffmpegGeneratedURL: URL? = nil
        
        defer {
            if let url = ffmpegGeneratedURL {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let ext = sourceURL.pathExtension.lowercased()
        
        // If we have ffmpeg, we can just let it do the Heavy lifting directly to 16kHz WAV
        if let ffmpeg = ffmpegPath {
            logger.info("Using ffmpeg to extract 16kHz mono audio...")
            ffmpegGeneratedURL = try runFFmpegTo16kHzWav(from: sourceURL, ffmpegPath: ffmpeg)
            inputURL = ffmpegGeneratedURL!
        } else if ext == "mkv" || ext == "webm" || ext == "avi" {
            throw AudioExtractionError.unsupportedMediaFormat(ext)
        }

        logger.debug("Opening audio file for PCM conversion...")
        let audioFile = try AVAudioFile(forReading: inputURL)
        
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        
        // If the file is already in the target format (e.g. from ffmpeg), we can read directly.
        if audioFile.processingFormat.sampleRate == 16000 && audioFile.processingFormat.channelCount == 1 {
            let frameCount = AVAudioFrameCount(audioFile.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
                throw AudioExtractionError.conversionFailed("Failed to create buffer for 16kHz audio.")
            }
            try audioFile.read(into: buffer)
            if let channelData = buffer.floatChannelData {
                return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
            }
        }

        guard let converter = AVAudioConverter(from: audioFile.processingFormat, to: targetFormat) else {
            throw AudioExtractionError.conversionFailed("Cannot create AVAudioConverter to 16kHz mono float.")
        }
        
        let frameCount = AVAudioFrameCount(audioFile.length)
        let ratio = 16000.0 / audioFile.processingFormat.sampleRate
        let targetFrameCount = AVAudioFrameCount(Double(frameCount) * ratio)
        
        var floats: [Float] = []
        floats.reserveCapacity(Int(targetFrameCount))
        
        let inputBufferCapacity: AVAudioFrameCount = 32768
        let outputBufferCapacity = AVAudioFrameCount(Double(inputBufferCapacity) * ratio)
        
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: inputBufferCapacity),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputBufferCapacity) else {
            throw AudioExtractionError.conversionFailed("Failed to create PCM buffers.")
        }
        
        while audioFile.framePosition < audioFile.length {
            let framesToRead = min(inputBufferCapacity, AVAudioFrameCount(audioFile.length - audioFile.framePosition))
            inputBuffer.frameLength = framesToRead
            try audioFile.read(into: inputBuffer, frameCount: framesToRead)
            
            var error: NSError? = nil
            var hasProvidedInput = false
            
            let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
                if hasProvidedInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                hasProvidedInput = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
            
            if status == .error {
                throw AudioExtractionError.conversionFailed(error?.localizedDescription ?? "Unknown conversion error")
            }
            
            if let channelData = outputBuffer.floatChannelData {
                let blockFloats = Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
                floats.append(contentsOf: blockFloats)
            }
        }
        
        return floats
    }

    // MARK: - Internal Helpers

    private class ResultBox<T> : @unchecked Sendable {
        var result: Result<T, Error>?
    }

    private static func wait<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()

        Task {
            do {
                let value = try await operation()
                box.result = .success(value)
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }

        semaphore.wait()
        return try box.result!.get()
    }

    private static func runFFmpeg(from sourceURL: URL, ffmpegPath: String, codec: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let ext = (codec == "copy") ? "mp4" : "m4a"
        let outputURL = tempDir.appendingPathComponent("video_to_srt_\(UUID().uuidString).\(ext)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        
        var args = ["-nostdin", "-y", "-i", sourceURL.path, "-vn"]
        if codec == "copy" {
            args.append(contentsOf: ["-c:a", "copy"])
        } else {
            args.append(contentsOf: ["-c:a", codec])
        }
        args.append(outputURL.path)
        process.arguments = args

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        logger.debug("Executing: \(([ffmpegPath] + args).joined(separator: " "), privacy: .public)")

        try process.run()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            return outputURL
        } else {
            let ffmpegOutput = String(data: data, encoding: .utf8) ?? "Unknown ffmpeg output"
            throw AudioExtractionError.audioExportFailed("ffmpeg failed: \(ffmpegOutput)")
        }
    }
    
    private static func runFFmpegTo16kHzWav(from sourceURL: URL, ffmpegPath: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent("video_to_srt_\(UUID().uuidString).wav")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        
        // Convert to 16kHz, 1 channel, 16-bit PCM WAV (or Float32 if we prefer)
        // pcm_s16le is standard, AVAudioFile will read it and convert to Float32 during read
        let args = ["-nostdin", "-y", "-i", sourceURL.path, "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", outputURL.path]
        process.arguments = args

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        logger.debug("Executing: \(([ffmpegPath] + args).joined(separator: " "), privacy: .public)")

        try process.run()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            return outputURL
        } else {
            let ffmpegOutput = String(data: data, encoding: .utf8) ?? "Unknown ffmpeg output"
            throw AudioExtractionError.audioExportFailed("ffmpeg failed: \(ffmpegOutput)")
        }
    }
}
