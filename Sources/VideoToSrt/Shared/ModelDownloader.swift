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

        let (bytes, response) = try await URLSession.shared.bytes(from: modelURL)
        
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw ModelDownloadError.downloadFailed("Server returned an error.")
        }

        let totalBytes = httpResponse.expectedContentLength
        var downloadedBytes: Int64 = 0
        var data = Data()
        if totalBytes > 0 {
            data.reserveCapacity(Int(totalBytes))
        }

        for try await byte in bytes {
            data.append(byte)
            downloadedBytes += 1
            
            if downloadedBytes % (1024 * 1024) == 0 { // Update every 1MB
                let percent = totalBytes > 0 ? Int(Double(downloadedBytes) / Double(totalBytes) * 100) : 0
                let progressString = "\rDownload Progress: \(percent)%..."
                fputs(progressString, stderr)
                fflush(stderr)
            }
        }
        fputs("\rDownload Progress: 100% (Complete)          \n", stderr)

        try data.write(to: destinationURL)
        print("Model saved to \(path)")
    }
}
