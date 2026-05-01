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
}
