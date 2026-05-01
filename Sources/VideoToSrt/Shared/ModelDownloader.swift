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
    private static let whisperModelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!
    private static let vadModelURL = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin")!

    public static func downloadWhisperModelIfNeeded(to path: String) async throws {
        try await downloadIfNeeded(from: whisperModelURL, to: path, description: "ggml-base.bin (approx. 140MB)")
    }

    public static func downloadVADModelIfNeeded(to path: String) async throws {
        try await downloadIfNeeded(from: vadModelURL, to: path, description: "ggml-silero-v6.2.0.bin (approx. 2MB)")
    }

    private static func downloadIfNeeded(from url: URL, to path: String, description: String) async throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: path) {
            return
        }

        print("Model not found at \(path).")
        print("Downloading \(description) from Hugging Face...")

        let destinationURL = URL(fileURLWithPath: path)
        let directoryURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw ModelDownloadError.downloadFailed("Server returned an error.")
        }

        try data.write(to: destinationURL)
        print("Model saved to \(path)")
    }
}

