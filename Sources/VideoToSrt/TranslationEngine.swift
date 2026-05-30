import Foundation
@preconcurrency import Translation

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
