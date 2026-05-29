import Testing
import Foundation
@testable import VideoToSrt

struct SubtitleTranslatorTests {

    final class MockTranslationEngine: TranslationEngine {
        func translate(_ texts: [String], sourceLanguageCode: String?, targetLanguageCode: String) async throws -> [String] {
            try await translate(texts, sourceLanguageCode: sourceLanguageCode, targetLanguageCode: targetLanguageCode, progressHandler: nil)
        }

        func translate(
            _ texts: [String],
            sourceLanguageCode: String?,
            targetLanguageCode: String,
            progressHandler: (@Sendable (Int, Int) -> Void)?
        ) async throws -> [String] {
            var results: [String] = []
            for (index, text) in texts.enumerated() {
                results.append(text.uppercased())
                progressHandler?(index + 1, texts.count)
            }
            return results
        }
    }

    @Test func testTranslateGroupingAndDistribution() async throws {
        let engine = MockTranslationEngine()
        let translator = SubtitleTranslator(engine: engine)
        
        let segments = [
            SubtitleSegment(index: 1, text: "I am not going", startSeconds: 0.0, endSeconds: 2.0),
            SubtitleSegment(index: 2, text: "to school today.", startSeconds: 2.0, endSeconds: 4.5),
            SubtitleSegment(index: 3, text: "It is closed.", startSeconds: 5.0, endSeconds: 7.0)
        ]
        
        // This should form two groups:
        // Group 1: ["I am not going", "to school today."] -> combined: "I am not going to school today."
        // Group 2: ["It is closed."] -> combined: "It is closed."
        
        // Mock translation result:
        // Group 1: "I AM NOT GOING TO SCHOOL TODAY."
        // Group 2: "IT IS CLOSED."
        
        let translated = try await translator.translate(segments, sourceLanguageCode: "en", targetLanguageCode: "tr")
        #expect(translated.count == 3)
        
        // Check timings are preserved
        #expect(translated[0].startSeconds == 0.0)
        #expect(translated[0].endSeconds == 2.0)
        #expect(translated[1].startSeconds == 2.0)
        #expect(translated[1].endSeconds == 4.5)
        #expect(translated[2].startSeconds == 5.0)
        #expect(translated[2].endSeconds == 7.0)
        
        // Check that translation was distributed proportionally based on segment duration ratios.
        // Group 1 duration = 4.5s.
        // Segment 1 ratio = 2.0 / 4.5 ≈ 44.4%
        // Segment 2 ratio = 2.5 / 4.5 ≈ 55.6%
        // Translated string: "I AM NOT GOING TO SCHOOL TODAY." (31 characters)
        // Segment 1 Target length: 31 * 0.444 ≈ 13.8 characters.
        // Words: ["I", "AM", "NOT", "GOING", "TO", "SCHOOL", "TODAY."]
        // Best word count closest to 13.8 is 3 words ("I AM NOT" -> 8 chars) or 4 words ("I AM NOT GOING" -> 14 chars).
        // 14 is closest to 13.8, so it splits at 4 words.
        // Segment 1 text: "I AM NOT GOING"
        // Segment 2 text: "TO SCHOOL TODAY."
        
        #expect(translated[0].text == "I AM NOT GOING")
        #expect(translated[1].text == "TO SCHOOL TODAY.")
        #expect(translated[2].text == "IT IS CLOSED.")
    }

    @Test func testTranslateWithLongPauseGrouping() async throws {
        let engine = MockTranslationEngine()
        let translator = SubtitleTranslator(engine: engine)
        
        let segments = [
            SubtitleSegment(index: 1, text: "First part", startSeconds: 0.0, endSeconds: 2.0),
            // There's a 2.0-second pause before next segment (exceeds 1.5s gap rule)
            SubtitleSegment(index: 2, text: "Second part after pause", startSeconds: 4.0, endSeconds: 6.0)
        ]
        
        let translated = try await translator.translate(segments, sourceLanguageCode: "en", targetLanguageCode: "fr")
        #expect(translated.count == 2)
        
        // Because of the pause, they should have been translated in separate groups,
        // resulting in exact mapped translations.
        #expect(translated[0].text == "FIRST PART")
        #expect(translated[1].text == "SECOND PART AFTER PAUSE")
    }

    @Test func testTranslateWithProgress() async throws {
        let engine = MockTranslationEngine()
        let translator = SubtitleTranslator(engine: engine)
        
        let segments = [
            SubtitleSegment(index: 1, text: "I am not going", startSeconds: 0.0, endSeconds: 2.0),
            SubtitleSegment(index: 2, text: "to school today.", startSeconds: 2.0, endSeconds: 4.5),
            SubtitleSegment(index: 3, text: "It is closed.", startSeconds: 5.0, endSeconds: 7.0)
        ]
        
        // Use a thread-safe container to store updates.
        final class ProgressTracker: @unchecked Sendable {
            private var _updates: [(translated: Int, total: Int)] = []
            private let lock = NSLock()
            func record(translated: Int, total: Int) {
                lock.withLock {
                    _updates.append((translated, total))
                }
            }
            func getUpdates() -> [(translated: Int, total: Int)] {
                lock.withLock {
                    _updates
                }
            }
        }
        
        let tracker = ProgressTracker()
        
        let _ = try await translator.translate(
            segments,
            sourceLanguageCode: "en",
            targetLanguageCode: "tr",
            progressHandler: { translated, total in
                tracker.record(translated: translated, total: total)
            }
        )
        
        let updates = tracker.getUpdates()
        
        #expect(updates.count == 2)
        #expect(updates[0].translated == 2)
        #expect(updates[0].total == 3)
        #expect(updates[1].translated == 3)
        #expect(updates[1].total == 3)
    }
}

