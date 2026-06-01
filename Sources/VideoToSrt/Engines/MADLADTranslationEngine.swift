import Foundation
import MADLADTranslation
import os

/// A ``TranslationEngine`` implementation that uses MADLAD-400 via local MLX execution.
public actor MADLADTranslationEngine: TranslationEngine {
    private let logger = Logger(subsystem: "com.video_to_srt", category: "MADLADTranslationEngine")
    
    public let modelId: String
    public let quantization: MADLADTranslator.Quantization
    
    private var translator: MADLADTranslator?
    
    public init(
        modelId: String = MADLADTranslator.defaultModelId,
        quantization: MADLADTranslator.Quantization = .int8
    ) {
        self.modelId = modelId
        self.quantization = quantization
    }
    
    private func getTranslator() async throws -> MADLADTranslator {
        if let existing = translator {
            return existing
        }
        
        print("Loading MADLAD translation model (\(self.modelId), \(self.quantization.rawValue))...\n")
        
        let newTranslator = try await MADLADTranslator.fromPretrained(
            modelId: modelId,
            quantization: quantization,
            progressHandler: { progress, status in
                let percent = Int(progress * 100)
                fputs("\rLoading (\(status)... \(percent)%)", stderr)
                fflush(stderr)
            }
        )
        fputs("\n", stderr)
        self.translator = newTranslator
        return newTranslator
    }
    
    public func translate(
        _ texts: [String],
        sourceLanguageCode: String?,
        targetLanguageCode: String
    ) async throws -> [String] {
        try await translate(
            texts,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode,
            progressHandler: nil
        )
    }
    
    public func translate(
        _ texts: [String],
        sourceLanguageCode: String?,
        targetLanguageCode: String,
        progressHandler: (@Sendable (Int, Int) -> Void)?
    ) async throws -> [String] {
        if texts.isEmpty { return [] }
        
        let translator = try await getTranslator()
        
        var results = Array(repeating: "", count: texts.count)
        
        logger.info("Translating \(texts.count) texts to \(targetLanguageCode)...")
        
        // Translate sequentially to avoid concurrent GPU execution contention.
        for (index, text) in texts.enumerated() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                results[index] = text
            } else {
                let translated = try translator.translate(
                    trimmed,
                    to: targetLanguageCode,
                    sampling: .greedy
                )
                results[index] = translated
            }
            progressHandler?(index + 1, texts.count)
        }
        
        return results
    }
}
