import Foundation

/// A segment of audio spoken by a specific speaker.
public struct SpeakerSegment: Codable, Sendable {
    public let start: Double
    public let end: Double
    public let speaker: String
}

/// Provides fast lookup of speaker identifiers by timestamp.
public struct DiarizationMap: Sendable {
    public let segments: [SpeakerSegment]
    
    public init(segments: [SpeakerSegment]) {
        // Sort segments by start time for binary search or sequential access
        self.segments = segments.sorted(by: { $0.start < $1.start })
    }
    
    public init(jsonURL: URL) throws {
        let data = try Data(contentsOf: jsonURL)
        let decoded = try JSONDecoder().decode([SpeakerSegment].self, from: data)
        self.init(segments: decoded)
    }
    
    /// Returns the speaker identifier at the given time (in seconds).
    /// If the time falls between segments, or overlaps, it returns the most appropriate speaker.
    public func speaker(at time: Double) -> String? {
        // Simple linear scan for now, since segments are typically < 10,000.
        // We look for a segment where the time falls strictly within [start, end].
        // If not found, we look for the closest segment.
        
        var closestSegment: SpeakerSegment? = nil
        var smallestDistance: Double = .infinity
        
        for segment in segments {
            if time >= segment.start && time <= segment.end {
                return segment.speaker
            }
            
            // If we're outside, track the closest one in case of slight timestamp mismatches
            let distance: Double
            if time < segment.start {
                distance = segment.start - time
            } else {
                distance = time - segment.end
            }
            
            if distance < smallestDistance {
                smallestDistance = distance
                closestSegment = segment
            }
        }
        
        // If the query time is within 1.0 seconds of the closest segment, use that speaker.
        if smallestDistance < 1.0 {
            return closestSegment?.speaker
        }
        
        return nil
    }
    
    /// Returns the speaker who occupies the most time within [from, to].
    /// This is more accurate than point-in-time lookup because diarization boundaries
    /// rarely align perfectly with transcription segment boundaries.
    public func dominantSpeaker(from rangeStart: Double, to rangeEnd: Double) -> String? {
        guard rangeEnd > rangeStart else { return speaker(at: rangeStart) }
        
        var overlapBySpeaker: [String: Double] = [:]
        
        for segment in segments {
            // Calculate overlap between [rangeStart, rangeEnd] and [segment.start, segment.end]
            let overlapStart = max(rangeStart, segment.start)
            let overlapEnd = min(rangeEnd, segment.end)
            let overlap = overlapEnd - overlapStart
            
            if overlap > 0 {
                overlapBySpeaker[segment.speaker, default: 0] += overlap
            }
        }
        
        // If we found overlapping diarization segments, return the speaker with the most overlap
        if let dominant = overlapBySpeaker.max(by: { $0.value < $1.value }) {
            return dominant.key
        }
        
        // Fallback: no diarization segment overlaps this range; use midpoint lookup
        return speaker(at: (rangeStart + rangeEnd) / 2.0)
    }
}
