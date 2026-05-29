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
    
    private let chunkSize = 8

    var body: some View {
        Color.clear
            .translationTask(configuration) { session in
                do {
                    let enumeratedTexts = Array(texts.enumerated())
                    let chunkedTexts = stride(from: 0, to: texts.count, by: chunkSize).map {
                        Array(enumeratedTexts[$0..<Swift.min($0 + chunkSize, texts.count)])
                    }
                    
                    var results = Array(repeating: "", count: texts.count)
                    var completedCount = 0
                    
                    for chunk in chunkedTexts {
                        var requests: [TranslationSession.Request] = []
                        var requestIndices: [Int] = []
                        
                        for (index, text) in chunk {
                            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                results[index] = text
                                completedCount += 1
                            } else {
                                requests.append(TranslationSession.Request(sourceText: text))
                                requestIndices.append(index)
                            }
                        }
                        
                        if !requests.isEmpty {
                            let responses = try await session.translations(from: requests)
                            for (i, response) in responses.enumerated() {
                                results[requestIndices[i]] = response.targetText
                                completedCount += 1
                            }
                        }
                        
                        progressHandler?(completedCount, texts.count)
                    }
                    
                    onComplete(.success(results))
                } catch {
                    onComplete(.failure(error))
                }
            }
    }
}
