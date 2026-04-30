import Foundation

public enum ModelDownloadError: Error, LocalizedError {
    case invalidURL
    case downloadFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "The model download URL is invalid."
        case .downloadFailed(let reason): return "Model download failed: \(reason)"
        }
    }
}

public struct ModelDownloader {
    private static let modelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!

    public static func downloadIfNeeded(to path: String) async throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: path) {
            return
        }

        print("Model not found at \(path).")
        print("Downloading ggml-base.bin from Hugging Face (approx. 140MB)...")
        
        let destinationURL = URL(fileURLWithPath: path)
        let directoryURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let (data, response) = try await URLSession.shared.data(from: modelURL)
        
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw ModelDownloadError.downloadFailed("Server returned an error.")
        }

        try data.write(to: destinationURL)
        print("Model saved to \(path)")
    }
}
