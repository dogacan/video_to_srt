import Foundation
@preconcurrency import AVFoundation
import os

public enum AudioExtractionError: Error, LocalizedError, Equatable {
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

    public static func == (lhs: AudioExtractionError, rhs: AudioExtractionError) -> Bool {
        switch (lhs, rhs) {
        case (.assetNotReadable, .assetNotReadable): return true
        case (.unsupportedMediaFormat, .unsupportedMediaFormat): return true
        case (.audioExportFailed, .audioExportFailed): return true
        case (.noAudioTrack, .noAudioTrack): return true
        case (.conversionFailed, .conversionFailed): return true
        case (.invalidInputSource, .invalidInputSource): return true
        default: return false
        }
    }
}

/// A utility for extracting and converting audio from video/audio files.
/// This class handles both Apple-native extraction and FFmpeg-based fallback.
public struct AudioExtractor {
    private static let logger = Logger(subsystem: "com.video_to_srt", category: "AudioExtractor")

    // MARK: - Constants

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

    // MARK: - API for Diarization

    /// Extracts and resamples audio to 16kHz WAV for Pyannote Diarization.
    /// Returns the URL of the temporary WAV file.
    public static func extractAudioForDiarization(from sourceURL: URL, ffmpegPath: String?) async throws -> URL {
        try validateSourceURL(sourceURL)
        
        let ext = sourceURL.pathExtension.lowercased()
        
        if let ffmpeg = ffmpegPath, ext != "wav" {
            logger.info("Using ffmpeg to extract 16kHz wav audio for diarization...")
            return try runFFmpegTo16kHzWav(from: sourceURL, ffmpegPath: ffmpeg)
        } else if isUnsupportedFormat(ext) {
            throw AudioExtractionError.unsupportedMediaFormat(ext)
        }
        
        // If AVFoundation is supported, we can convert it to WAV.
        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent("video_to_srt_diarization_\(UUID().uuidString).wav")
        
        logger.debug("Converting audio file for Diarization using AVFoundation...")
        let audioFile = try AVAudioFile(forReading: sourceURL)
        
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: targetChannelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        let outputFile = try AVAudioFile(forWriting: outputURL, settings: fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let targetFormat = outputFile.processingFormat
        
        guard let converter = AVAudioConverter(from: audioFile.processingFormat, to: targetFormat) else {
            throw AudioExtractionError.conversionFailed("Cannot create AVAudioConverter to 16kHz mono.")
        }
        
        let inputBufferCapacity: AVAudioFrameCount = 32768
        let ratio = 16000.0 / audioFile.processingFormat.sampleRate
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
            
            if outputBuffer.frameLength > 0 {
                try outputFile.write(from: outputBuffer)
            }
            
            hasProvidedInput.value = false
        }
        
        return outputURL
    }

    // MARK: - API for Whisper Engine

    /// Extracts and resamples audio to 16kHz, mono, 16-bit PCM for Whisper.
    /// Returns an array of Float32 samples.
    public static func extractAudioForWhisper(from sourceURL: URL, ffmpegPath: String?) async throws -> [Float] {
        return try await extractAudioFloat(from: sourceURL, targetSampleRate: 16000.0, ffmpegPath: ffmpegPath)
    }

    // MARK: - API for Float Extraction (Whisper, Qwen, etc.)
    
    /// Extracts and resamples audio to the target sample rate, mono, Float32 PCM.
    /// Returns an array of Float32 samples.
    public static func extractAudioFloat(from sourceURL: URL, targetSampleRate: Double, ffmpegPath: String?) async throws -> [Float] {
        try validateSourceURL(sourceURL)
        
        var inputURL = sourceURL
        var ffmpegGeneratedURL: URL? = nil
        
        defer {
            if let url = ffmpegGeneratedURL {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let ext = sourceURL.pathExtension.lowercased()
        
        // If we have ffmpeg, use it to convert directly to target sample rate WAV for maximum compatibility.
        // Skip this if the input is already a WAV (e.g. from diarization).
        if let ffmpeg = ffmpegPath, ext != "wav" {
            logger.info("Using ffmpeg to extract \(targetSampleRate)Hz mono audio...")
            ffmpegGeneratedURL = try runFFmpegToWav(from: sourceURL, sampleRate: targetSampleRate, ffmpegPath: ffmpeg)
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
                throw AudioExtractionError.conversionFailed("Failed to create buffer for \(targetSampleRate)Hz audio.")
            }
            try audioFile.read(into: buffer)
            if let channelData = buffer.floatChannelData {
                return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
            }
        }

        // Standard path: Convert to targetSampleRate mono Float32.
        guard let converter = AVAudioConverter(from: audioFile.processingFormat, to: targetFormat) else {
            throw AudioExtractionError.conversionFailed("Cannot create AVAudioConverter to \(targetSampleRate)Hz mono float.")
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

    internal static func validateSourceURL(_ url: URL) throws {
        guard url.isFileURL else {
            throw AudioExtractionError.invalidInputSource
        }
    }

    internal static func validateFFmpegPath(_ path: String) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw AudioExtractionError.audioExportFailed("FFmpeg path '\(path)' is not a file.")
        }
        
        guard fileManager.isExecutableFile(atPath: path) else {
            throw AudioExtractionError.audioExportFailed("FFmpeg path '\(path)' is not executable.")
        }
    }

    internal static func isUnsupportedFormat(_ ext: String) -> Bool {
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
        return try runFFmpegToWav(from: sourceURL, sampleRate: 16000.0, ffmpegPath: ffmpegPath)
    }
    
    private static func runFFmpegToWav(from sourceURL: URL, sampleRate: Double, ffmpegPath: String) throws -> URL {
        try validateFFmpegPath(ffmpegPath)
        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent("video_to_srt_\(UUID().uuidString).wav")

        // Convert to target sample rate, 1 channel, 16-bit PCM WAV.
        let args = ["-nostdin", "-y", "-i", sourceURL.path, "-vn", "-ar", "\(Int(sampleRate))", "-ac", "1", "-c:a", "pcm_s16le", outputURL.path]
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
