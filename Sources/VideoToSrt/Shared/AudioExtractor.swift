import Foundation
@preconcurrency import AVFoundation
import os

public enum AudioExtractionError: Error, LocalizedError {
    case assetNotReadable(Error?)
    case unsupportedMediaFormat(String)
    case audioExportFailed(String)
    case noAudioTrack
    case conversionFailed(String)
    case invalidInputSource

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
        case .invalidInputSource:
            return "The input source is not a valid file URL."
        }
    }
}

/// A utility for extracting and converting audio from video/audio files.
/// This class handles both Apple-native extraction and FFmpeg-based fallback.
public struct AudioExtractor {
    private static let logger = Logger(subsystem: "com.video_to_srt", category: "AudioExtractor")

    // MARK: - Constants

    private static let targetSampleRate: Double = 16000
    private static let targetChannelCount: UInt32 = 1
    private static let inputBufferCapacity: AVAudioFrameCount = 32768
    private static let unsupportedFormats = ["mkv", "webm", "avi"]

    // MARK: - API for Apple Engine

    /// Exports the audio track(s) from a video or audio file into a temporary
    /// M4A file that Apple's Speech transcribers can process efficiently.
    ///
    /// FFmpeg is used as a fallback for formats unsupported by AVFoundation (e.g., MKV).
    public static func extractAudioForApple(from sourceURL: URL, ffmpegPath: String?) async throws -> URL {
        try validateSourceURL(sourceURL)
        
        var inputURL = sourceURL
        var ffmpegGeneratedURL: URL? = nil
        
        defer {
            if let url = ffmpegGeneratedURL {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let ext = sourceURL.pathExtension.lowercased()
        if let fallbackURL = try handleUnsupportedFormat(sourceURL, ext: ext, ffmpegPath: ffmpegPath) {
            ffmpegGeneratedURL = fallbackURL
            inputURL = ffmpegGeneratedURL!
        }

        let initialAsset = AVURLAsset(url: inputURL)
        var selectedAsset = initialAsset

        do {
            let isReadable = try await initialAsset.load(.isReadable)
            guard isReadable else {
                throw AudioExtractionError.assetNotReadable(nil)
            }
        } catch {
            // If AVFoundation fails and we haven't tried FFmpeg yet, try one last time.
            if let avError = error as? AVError, avError.code == .fileFormatNotRecognized, ffmpegGeneratedURL == nil {
                if let ffmpeg = ffmpegPath {
                    ffmpegGeneratedURL = try runFFmpeg(from: sourceURL, ffmpegPath: ffmpeg, codec: "copy")
                    inputURL = ffmpegGeneratedURL!
                    let fallbackAsset = AVURLAsset(url: inputURL)
                    
                    let isReadable = try await fallbackAsset.load(.isReadable)
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
        let audioTracks = try await workingAsset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw AudioExtractionError.noAudioTrack
        }

        let tempDir = FileManager.default.temporaryDirectory
        
        // Combine tracks into a single composition to ensure we capture all audio
        let composition = AVMutableComposition()
        let duration = try await workingAsset.load(.duration)
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
        
        // Use the modern async export and handle the potential throw.
        do {
            try await composedSession.export(to: m4aURL, as: .m4a)
        } catch {
            throw AudioExtractionError.audioExportFailed(error.localizedDescription)
        }

        return m4aURL
    }

    // MARK: - API for Whisper Engine

    /// Extracts and resamples audio to 16kHz, mono, 16-bit PCM for Whisper.
    /// Returns an array of Float32 samples.
    public static func extractAudioForWhisper(from sourceURL: URL, ffmpegPath: String?) async throws -> [Float] {
        try validateSourceURL(sourceURL)
        
        var inputURL = sourceURL
        var ffmpegGeneratedURL: URL? = nil
        
        defer {
            if let url = ffmpegGeneratedURL {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let ext = sourceURL.pathExtension.lowercased()
        
        // If we have ffmpeg, use it to convert directly to 16kHz WAV for maximum compatibility.
        if let ffmpeg = ffmpegPath {
            logger.info("Using ffmpeg to extract 16kHz mono audio...")
            ffmpegGeneratedURL = try runFFmpegTo16kHzWav(from: sourceURL, ffmpegPath: ffmpeg)
            inputURL = ffmpegGeneratedURL!
        } else if isUnsupportedFormat(ext) {
            throw AudioExtractionError.unsupportedMediaFormat(ext)
        }

        logger.debug("Opening audio file for PCM conversion...")
        let audioFile = try AVAudioFile(forReading: inputURL)
        
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, 
                                        sampleRate: targetSampleRate, 
                                        channels: targetChannelCount, 
                                        interleaved: false)!
        
        // Optimized path: If already in target format, read directly.
        if audioFile.processingFormat.sampleRate == targetSampleRate && 
           audioFile.processingFormat.channelCount == targetChannelCount {
            let frameCount = AVAudioFrameCount(audioFile.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
                throw AudioExtractionError.conversionFailed("Failed to create buffer for 16kHz audio.")
            }
            try audioFile.read(into: buffer)
            if let channelData = buffer.floatChannelData {
                return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
            }
        }

        // Standard path: Convert to 16kHz mono Float32.
        guard let converter = AVAudioConverter(from: audioFile.processingFormat, to: targetFormat) else {
            throw AudioExtractionError.conversionFailed("Cannot create AVAudioConverter to 16kHz mono float.")
        }
        
        let frameCount = AVAudioFrameCount(audioFile.length)
        let ratio = targetSampleRate / audioFile.processingFormat.sampleRate
        let targetFrameCount = AVAudioFrameCount(Double(frameCount) * ratio)
        
        var floats: [Float] = []
        floats.reserveCapacity(Int(targetFrameCount))
        
        let outputBufferCapacity = AVAudioFrameCount(Double(inputBufferCapacity) * ratio)
        
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: inputBufferCapacity),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputBufferCapacity) else {
            throw AudioExtractionError.conversionFailed("Failed to create PCM buffers.")
        }
        
        let hasProvidedInput = Box(false)
        
        while audioFile.framePosition < audioFile.length {
            let framesToRead = min(inputBufferCapacity, AVAudioFrameCount(audioFile.length - audioFile.framePosition))
            inputBuffer.frameLength = framesToRead
            try audioFile.read(into: inputBuffer, frameCount: framesToRead)
            
            var error: NSError? = nil
            
            let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
                if hasProvidedInput.value {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                hasProvidedInput.value = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
            
            if status == .error {
                throw AudioExtractionError.conversionFailed(error?.localizedDescription ?? "Unknown conversion error")
            }
            
            if let channelData = outputBuffer.floatChannelData {
                floats.reserveCapacity(floats.count + Int(outputBuffer.frameLength))
                floats.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
            }
            
            // Reset for next conversion call
            hasProvidedInput.value = false
        }
        
        if floats.isEmpty {
            throw AudioExtractionError.conversionFailed("No audio data extracted")
        }
        
        return floats
    }

    // MARK: - Internal Helpers

    private class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private static func validateSourceURL(_ url: URL) throws {
        guard url.isFileURL else {
            throw AudioExtractionError.invalidInputSource
        }
    }

    private static func validateFFmpegPath(_ path: String) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw AudioExtractionError.audioExportFailed("FFmpeg path '\(path)' is not a file.")
        }
        
        guard fileManager.isExecutableFile(atPath: path) else {
            throw AudioExtractionError.audioExportFailed("FFmpeg path '\(path)' is not executable.")
        }
    }

    private static func isUnsupportedFormat(_ ext: String) -> Bool {
        unsupportedFormats.contains(ext)
    }

    private static func handleUnsupportedFormat(_ sourceURL: URL, ext: String, ffmpegPath: String?) throws -> URL? {
        guard isUnsupportedFormat(ext) else { return nil }
        guard let ffmpeg = ffmpegPath else {
            throw AudioExtractionError.unsupportedMediaFormat(ext)
        }
        try validateFFmpegPath(ffmpeg)
        return try runFFmpeg(from: sourceURL, ffmpegPath: ffmpeg, codec: "copy")
    }

    private static func runFFmpeg(from sourceURL: URL, ffmpegPath: String, codec: String) throws -> URL {
        try validateFFmpegPath(ffmpegPath)
        let tempDir = FileManager.default.temporaryDirectory
        let ext = (codec == "copy") ? "mp4" : "m4a"
        let outputURL = tempDir.appendingPathComponent("video_to_srt_\(UUID().uuidString).\(ext)")

        let args = ["-nostdin", "-y", "-i", sourceURL.path, "-vn", "-c:a", codec, outputURL.path]
        return try executeFFmpeg(executablePath: ffmpegPath, arguments: args, outputURL: outputURL)
    }
    
    private static func runFFmpegTo16kHzWav(from sourceURL: URL, ffmpegPath: String) throws -> URL {
        try validateFFmpegPath(ffmpegPath)
        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent("video_to_srt_\(UUID().uuidString).wav")

        // Convert to 16kHz, 1 channel, 16-bit PCM WAV.
        let args = ["-nostdin", "-y", "-i", sourceURL.path, "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", outputURL.path]
        return try executeFFmpeg(executablePath: ffmpegPath, arguments: args, outputURL: outputURL)
    }

    private static func executeFFmpeg(executablePath: String, arguments: [String], outputURL: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        logger.debug("Executing: \(([executablePath] + arguments).joined(separator: " "), privacy: .public)")

        try process.run()
        
        // Handle cancellation
        let cancellationTask = Task {
            while process.isRunning {
                if Task.isCancelled {
                    process.terminate()
                    break
                }
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s check
            }
        }
        
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        cancellationTask.cancel()

        if process.terminationStatus == 0 {
            return outputURL
        } else {
            if Task.isCancelled {
                throw CancellationError()
            }
            let ffmpegOutput = String(data: data, encoding: .utf8) ?? "Unknown ffmpeg output"
            throw AudioExtractionError.audioExportFailed("ffmpeg failed: \(ffmpegOutput)")
        }
    }
}
