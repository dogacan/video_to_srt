import Foundation

public struct SubtitleParser {
    public static func parse(_ content: String) throws -> [SubtitleSegment] {
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        
        var segments: [SubtitleSegment] = []
        var currentBlock: [String] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !currentBlock.isEmpty {
                    if let segment = parseBlock(currentBlock, fallbackIndex: segments.count + 1) {
                        segments.append(segment)
                    }
                    currentBlock.removeAll()
                }
            } else {
                // Keep original spacing for text line content, but trim block wrapper lines
                currentBlock.append(line.trimmingCharacters(in: .newlines))
            }
        }
        
        if !currentBlock.isEmpty {
            if let segment = parseBlock(currentBlock, fallbackIndex: segments.count + 1) {
                segments.append(segment)
            }
        }
        
        return segments
    }
    
    private static func parseBlock(_ block: [String], fallbackIndex: Int) -> SubtitleSegment? {
        if block.isEmpty { return nil }
        
        var index = fallbackIndex
        var timingLineIndex = 0
        
        // Find line containing "-->"
        if let idx = block.firstIndex(where: { $0.contains("-->") }) {
            timingLineIndex = idx
            let indexCandidate = block[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if idx > 0, let parsedIndex = Int(indexCandidate) {
                index = parsedIndex
            }
        } else {
            return nil
        }
        
        let timingLine = block[timingLineIndex]
        let timingParts = timingLine.components(separatedBy: "-->")
        guard timingParts.count == 2 else { return nil }
        
        guard let start = parseTimestamp(timingParts[0]),
              let end = parseTimestamp(timingParts[1]) else {
            return nil
        }
        
        let textLines = Array(block[(timingLineIndex + 1)...])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            
        guard !textLines.isEmpty else { return nil }
        let text = textLines.joined(separator: "\n")
        
        return SubtitleSegment(index: index, text: text, startSeconds: start, endSeconds: end)
    }
    
    public static func parseTimestamp(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        let components = normalized.components(separatedBy: ":")
        
        guard components.count >= 2 else { return nil }
        
        if components.count == 2 {
            // MM:SS.mmm
            guard let minutes = Double(components[0]),
                  let seconds = Double(components[1]) else {
                return nil
            }
            return minutes * 60.0 + seconds
        } else if components.count == 3 {
            // HH:MM:SS.mmm
            guard let hours = Double(components[0]),
                  let minutes = Double(components[1]),
                  let seconds = Double(components[2]) else {
                return nil
            }
            return hours * 3600.0 + minutes * 60.0 + seconds
        }
        
        return nil
    }
}
