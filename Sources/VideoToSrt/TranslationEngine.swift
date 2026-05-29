import SwiftUI
@preconcurrency import Translation
import AppKit

public protocol TranslationEngine: Sendable {
    func translate(_ texts: [String], sourceLanguageCode: String?, targetLanguageCode: String) async throws -> [String]
    
    func translate(
        _ texts: [String],
        sourceLanguageCode: String?,
        targetLanguageCode: String,
        progressHandler: (@Sendable (Int, Int) -> Void)?
    ) async throws -> [String]
}

extension TranslationEngine {
    public func translate(
        _ texts: [String],
        sourceLanguageCode: String?,
        targetLanguageCode: String,
        progressHandler: (@Sendable (Int, Int) -> Void)?
    ) async throws -> [String] {
        try await translate(texts, sourceLanguageCode: sourceLanguageCode, targetLanguageCode: targetLanguageCode)
    }
}

public final class AppleTranslationEngine: TranslationEngine, @unchecked Sendable {
    public init() {}

    public func translate(_ texts: [String], sourceLanguageCode: String?, targetLanguageCode: String) async throws -> [String] {
        try await translate(texts, sourceLanguageCode: sourceLanguageCode, targetLanguageCode: targetLanguageCode, progressHandler: nil)
    }

    public func translate(
        _ texts: [String],
        sourceLanguageCode: String?,
        targetLanguageCode: String,
        progressHandler: (@Sendable (Int, Int) -> Void)?
    ) async throws -> [String] {
        if texts.isEmpty { return [] }
        
        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                let targetLocale = Locale.Language(languageCode: Locale.LanguageCode(targetLanguageCode))
                let sourceLocale = sourceLanguageCode.map { Locale.Language(languageCode: Locale.LanguageCode($0)) }
                let configuration = TranslationSession.Configuration(source: sourceLocale, target: targetLocale)
                
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
                    progressHandler: progressHandler,
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
    let progressHandler: (@Sendable (Int, Int) -> Void)?
    let onComplete: @MainActor @Sendable (Result<[String], Error>) -> Void
    
    var body: some View {
        Color.clear
            .translationTask(configuration) { session in
                do {
                    var translatedTexts: [String] = []
                    for (index, text) in texts.enumerated() {
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            translatedTexts.append(text)
                            progressHandler?(index + 1, texts.count)
                            continue
                        }
                        let response = try await session.translate(text)
                        translatedTexts.append(response.targetText)
                        progressHandler?(index + 1, texts.count)
                    }
                    onComplete(.success(translatedTexts))
                } catch {
                    onComplete(.failure(error))
                }
            }
    }
}
