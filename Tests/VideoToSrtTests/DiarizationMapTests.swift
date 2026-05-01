import Testing
import Foundation
@testable import VideoToSrt

@Suite("Diarization Map Tests")
struct DiarizationMapTests {
    
    @Test("Finds correct speaker strictly within segment")
    func findsSpeakerWithinSegment() {
        let segments = [
            SpeakerSegment(start: 0.0, end: 2.0, speaker: "SPEAKER_00"),
            SpeakerSegment(start: 2.1, end: 5.0, speaker: "SPEAKER_01")
        ]
        let map = DiarizationMap(segments: segments)
        
        #expect(map.speaker(at: 1.0) == "SPEAKER_00")
        #expect(map.speaker(at: 3.5) == "SPEAKER_01")
    }
    
    @Test("Finds closest speaker when slightly outside segment")
    func findsClosestSpeaker() {
        let segments = [
            SpeakerSegment(start: 1.0, end: 2.0, speaker: "SPEAKER_00"),
            SpeakerSegment(start: 4.0, end: 5.0, speaker: "SPEAKER_01")
        ]
        let map = DiarizationMap(segments: segments)
        
        // 0.8 is 0.2s before SPEAKER_00 (within 1.0s threshold)
        #expect(map.speaker(at: 0.8) == "SPEAKER_00")
        
        // 2.2 is 0.2s after SPEAKER_00 (within 1.0s threshold)
        #expect(map.speaker(at: 2.2) == "SPEAKER_00")
        
        // 3.8 is 0.2s before SPEAKER_01
        #expect(map.speaker(at: 3.8) == "SPEAKER_01")
        
        // 10.0 is way outside (> 1.0s threshold)
        #expect(map.speaker(at: 10.0) == nil)
    }
    
    @Test("Resolves to correct speaker between two distant segments")
    func resolvesBetweenSegments() {
        let segments = [
            SpeakerSegment(start: 0.0, end: 1.0, speaker: "SPEAKER_00"),
            SpeakerSegment(start: 5.0, end: 6.0, speaker: "SPEAKER_01")
        ]
        let map = DiarizationMap(segments: segments)
        
        // 1.5 is 0.5s from SPEAKER_00 and 3.5s from SPEAKER_01
        #expect(map.speaker(at: 1.5) == "SPEAKER_00")
        
        // 3.0 is 2.0s from both -> >1.0s threshold so nil
        #expect(map.speaker(at: 3.0) == nil)
    }
}
