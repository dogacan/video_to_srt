import Foundation

private struct OpenRouterRequest: Codable {
    struct Message: Codable {
        let role: String
        let content: String
    }
    let model: String
    let messages: [Message]
    let temperature: Double
}

private struct OpenRouterResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
}

public final class OpenRouterTranslationEngine: TranslationEngine, @unchecked Sendable {
    public let model: String
    private let urlString = "https://openrouter.ai/api/v1/chat/completions"
    private let chunkSize = 8
    
    public init(model: String = "openrouter/free") {
        self.model = model
    }
    
    public func translate(
        _ texts: [String],
        sourceLanguageCode: String?,
        targetLanguageCode: String
    ) async throws -> [String] {
        try await translate(texts, sourceLanguageCode: sourceLanguageCode, targetLanguageCode: targetLanguageCode, progressHandler: nil)
    }
    
    public func translate(
        _ texts: [String],
        sourceLanguageCode: String?,
        targetLanguageCode: String,
        progressHandler: (@Sendable (Int, Int) -> Void)?
    ) async throws -> [String] {
        guard let apiKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !apiKey.isEmpty else {
            throw NSError(domain: "OpenRouterTranslationEngine", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Error: OPENROUTER_API_KEY environment variable is not set. Please set it using 'export OPENROUTER_API_KEY=...' before running."
            ])
        }
        
        if texts.isEmpty { return [] }
        
        let enumeratedTexts = Array(texts.enumerated())
        let chunkedTexts = stride(from: 0, to: texts.count, by: chunkSize).map {
            Array(enumeratedTexts[$0..<Swift.min($0 + chunkSize, texts.count)])
        }
        
        var results = Array(repeating: "", count: texts.count)
        var completedCount = 0
        
        for chunk in chunkedTexts {
            // Filter out empty lines to avoid translating them
            var nonEmptyChunk: [(Int, String)] = []
            for (index, text) in chunk {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    results[index] = text
                    completedCount += 1
                } else {
                    nonEmptyChunk.append((index, text))
                }
            }
            
            if !nonEmptyChunk.isEmpty {
                let translatedChunk = try await translateChunk(
                    nonEmptyChunk,
                    sourceLanguageCode: sourceLanguageCode,
                    targetLanguageCode: targetLanguageCode,
                    apiKey: apiKey
                )
                for (index, translated) in translatedChunk {
                    results[index] = translated
                    completedCount += 1
                }
            }
            
            progressHandler?(completedCount, texts.count)
        }
        
        return results
    }
    
    private func translateChunk(
        _ chunk: [(Int, String)],
        sourceLanguageCode: String?,
        targetLanguageCode: String,
        apiKey: String
    ) async throws -> [(Int, String)] {
        let url = URL(string: urlString)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://localhost:3000", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Subtitle Translator", forHTTPHeaderField: "X-Title")
        
        let targetLanguageName = Locale(identifier: "en").localizedString(forLanguageCode: targetLanguageCode) ?? targetLanguageCode
        let sourceLanguagePart = sourceLanguageCode.map { " from " + (Locale(identifier: "en").localizedString(forLanguageCode: $0) ?? $0) } ?? ""
        
        let systemPrompt = """
        You are a translation assistant. Translate the following tagged lines to \(targetLanguageName)\(sourceLanguagePart).
        Maintain a strict one-to-one mapping: output exactly the same number of lines as the input, keeping the line indices [index] intact.
        Do not add any explanations, notes, introductory text, or concluding text.
        Output ONLY the translation, matching the input line formats exactly.
        
        Example Input:
        [0] Hello
        [1] Goodbye
        
        Example Output:
        [0] Merhaba
        [1] Hoşça kal
        """
        
        var inputLines: [String] = []
        for (index, text) in chunk {
            inputLines.append("[\(index)] \(text)")
        }
        let userContent = inputLines.joined(separator: "\n")
        
        let openRouterReq = OpenRouterRequest(
            model: model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userContent)
            ],
            temperature: 0.1
        )
        
        request.httpBody = try JSONEncoder().encode(openRouterReq)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown HTTP error"
            throw NSError(domain: "OpenRouterTranslationEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "OpenRouter API returned error: \(errorMsg)"])
        }
        
        let openRouterRes = try JSONDecoder().decode(OpenRouterResponse.self, from: data)
        
        guard let responseContent = openRouterRes.choices.first?.message.content else {
            throw NSError(domain: "OpenRouterTranslationEngine", code: 2, userInfo: [NSLocalizedDescriptionKey: "OpenRouter API returned empty choice response."])
        }
        
        // Parse the response
        let lines = responseContent.components(separatedBy: .newlines)
        
        // Build a mapping lookup for indices in this chunk
        let indexMap = Set(chunk.map { $0.0 })
        
        var parsedResults: [Int: String] = [:]
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            
            if trimmed.hasPrefix("[") {
                if let closeBracketIndex = trimmed.firstIndex(of: "]") {
                    let indexStart = trimmed.index(after: trimmed.startIndex)
                    let indexString = String(trimmed[indexStart..<closeBracketIndex])
                    if let index = Int(indexString), indexMap.contains(index) {
                        let textStart = trimmed.index(after: closeBracketIndex)
                        let translatedText = String(trimmed[textStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        parsedResults[index] = translatedText
                    }
                }
            }
        }
        
        // Fallback checks
        var returnedResults: [(Int, String)] = []
        for (i, item) in chunk.enumerated() {
            let index = item.0
            if let parsed = parsedResults[index] {
                returnedResults.append((index, parsed))
            } else {
                // Fallback 1: Try lines[i] clean up
                if i < lines.count {
                    let rawLine = lines[i]
                    var cleanLine = rawLine
                    if cleanLine.hasPrefix("[") {
                        if let closeBracketIndex = cleanLine.firstIndex(of: "]") {
                            let textStart = cleanLine.index(after: closeBracketIndex)
                            cleanLine = String(cleanLine[textStart...])
                        }
                    }
                    returnedResults.append((index, cleanLine.trimmingCharacters(in: .whitespacesAndNewlines)))
                } else {
                    // Fallback 2: Keep original text
                    returnedResults.append((index, item.1))
                }
            }
        }
        
        return returnedResults
    }
}
