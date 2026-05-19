import SwiftUI
@preconcurrency import Translation
import AppKit

public protocol TranslationEngine: Sendable {
    func translate(_ texts: [String], targetLanguageCode: String) async throws -> [String]
}

public final class AppleTranslationEngine: TranslationEngine, @unchecked Sendable {
    public init() {}

    public func translate(_ texts: [String], targetLanguageCode: String) async throws -> [String] {
        if texts.isEmpty { return [] }
        
        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                let targetLocale = Locale.Language(languageCode: Locale.LanguageCode(targetLanguageCode))
                let configuration = TranslationSession.Configuration(target: targetLocale)
                
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                
                let hostingView = NSHostingView(rootView: HeadlessTranslationView(
                    texts: texts,
                    configuration: configuration,
                    onComplete: { result in
                        window.close()
                        continuation.resume(with: result)
                    }
                ))
                window.contentView = hostingView
                window.orderFront(nil)
            }
        }
    }
}

@MainActor
private struct HeadlessTranslationView: View {
    let texts: [String]
    let configuration: TranslationSession.Configuration
    let onComplete: @MainActor @Sendable (Result<[String], Error>) -> Void
    
    var body: some View {
        Color.clear
            .translationTask(configuration) { session in
                do {
                    var translatedTexts: [String] = []
                    for text in texts {
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            translatedTexts.append(text)
                            continue
                        }
                        let response = try await session.translate(text)
                        translatedTexts.append(response.targetText)
                    }
                    onComplete(.success(translatedTexts))
                } catch {
                    onComplete(.failure(error))
                }
            }
    }
}
