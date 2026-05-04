import Foundation
import SpeechVAD

/// A service responsible for performing speaker diarization.
///
/// This runner uses the native `SpeechVAD` pipeline to detect speakers and their respective segments
/// within an audio stream.
public struct DiarizationRunner {
    
    /// Runs the diarization process on the provided audio file.
    ///
    /// - Parameters:
    ///   - inputURL: The URL of the video or audio file to diarize.
    ///   - ffmpegPath: Optional path to the ffmpeg executable.
    ///   - vadModelId: The identifier of the VAD model to use.
    /// - Returns: A ``DiarizationMap`` containing the identified speaker segments.
    public static func run(
        inputURL: URL,
        ffmpegPath: String?,
        vadModelId: String
    ) async throws -> DiarizationMap {
        print("\nStarting Native Swift Diarization with SpeechVAD...")
        
        let audio16k = try await AudioExtractor.extractAudioFloat(
            from: inputURL,
            targetSampleRate: 16000.0,
            ffmpegPath: ffmpegPath
        )
        
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
        print("Native Diarization complete. Found \(map.segments.count) speaker segments.")
        return map
    }
}
