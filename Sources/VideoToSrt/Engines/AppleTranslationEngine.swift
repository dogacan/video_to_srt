import Foundation
@preconcurrency import Translation

public final class AppleTranslationEngine: TranslationEngine, @unchecked Sendable {
    private let chunkSize = 32
    
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
        
        let targetLocale = Locale.Language(languageCode: Locale.LanguageCode(targetLanguageCode))
        let sourceLocaleCode = sourceLanguageCode ?? Locale.current.identifier
        let sourceLocale = Locale.Language(languageCode: Locale.LanguageCode(sourceLocaleCode))
        
        let session = TranslationSession(installedSource: sourceLocale, target: targetLocale)
        
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
        
        return results
    }
}
