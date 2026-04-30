import Foundation
import whisper

public struct WhisperSegment: Sendable {
    public let text: String
    public let startTime: Int64 // ms
    public let endTime: Int64 // ms
}

public struct WhisperParams {
    public var language: String = "auto"
    public var threads: Int32 = Int32(ProcessInfo.processInfo.activeProcessorCount)
    public var maxLen: Int32 = 0
    public var tokenTimestamps: Bool = false
    public var splitOnWord: Bool = false
    public var suppressNST: Bool = true
    
    public init() {}
}

public enum WhisperError: Error, LocalizedError {
    case failedToInitialize(String)
    case transcriptionFailed(Int32)
    case modelFileNotFound(String)
    
    public var errorDescription: String? {
        switch self {
        case .failedToInitialize(let path):
            return "Failed to initialize Whisper context with model at: \(path)"
        case .transcriptionFailed(let code):
            return "Whisper transcription failed with error code: \(code)"
        case .modelFileNotFound(let path):
            return "Whisper model file not found at: \(path)"
        }
    }
}

public final class WhisperContext: @unchecked Sendable {
    private let context: OpaquePointer
    
    public init(modelPath: String) throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw WhisperError.modelFileNotFound(modelPath)
        }
        
        let cparams = whisper_context_default_params()
        guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw WhisperError.failedToInitialize(modelPath)
        }
        self.context = ctx
    }
    
    deinit {
        whisper_free(context)
    }
    
    public func transcribe(
        audio: [Float],
        params: WhisperParams,
        onNewSegments: (@Sendable ([WhisperSegment]) -> Void)? = nil
    ) async throws -> [WhisperSegment] {
        var whisperParams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        
        // Apply params
        whisperParams.n_threads = params.threads
        whisperParams.print_progress = false
        whisperParams.print_timestamps = false
        whisperParams.print_special = false
        whisperParams.print_realtime = false
        whisperParams.max_len = params.maxLen
        whisperParams.token_timestamps = params.tokenTimestamps
        whisperParams.split_on_word = params.splitOnWord
        whisperParams.suppress_nst = params.suppressNST
        
        if params.language != "auto" {
            params.language.withCString { whisperParams.language = $0 }
        }
        
        // Set up callback if needed
        var callbackContainer: CallbackContainer?
        if let onNewSegments = onNewSegments {
            callbackContainer = CallbackContainer(callback: onNewSegments)
            whisperParams.new_segment_callback_user_data = Unmanaged.passUnretained(callbackContainer!).toOpaque()
            whisperParams.new_segment_callback = { ctx, state, nNew, userData in
                guard let userData = userData else { return }
                let container = Unmanaged<CallbackContainer>.fromOpaque(userData).takeUnretainedValue()
                
                let totalSegments = whisper_full_n_segments(ctx)
                let startIdx = totalSegments - nNew
                
                var newSegments: [WhisperSegment] = []
                for i in startIdx..<totalSegments {
                    if let textC = whisper_full_get_segment_text(ctx, i) {
                        let text = String(cString: textC)
                        let t0 = whisper_full_get_segment_t0(ctx, i) * 10
                        let t1 = whisper_full_get_segment_t1(ctx, i) * 10
                        newSegments.append(WhisperSegment(text: text, startTime: t0, endTime: t1))
                    }
                }
                container.callback(newSegments)
            }
        }
        
        let result = whisper_full(context, whisperParams, audio, Int32(audio.count))
        if result != 0 {
            throw WhisperError.transcriptionFailed(result)
        }
        
        // Final segments
        let nSegments = whisper_full_n_segments(context)
        var segments: [WhisperSegment] = []
        for i in 0..<nSegments {
            if let textC = whisper_full_get_segment_text(context, i) {
                let text = String(cString: textC)
                let t0 = whisper_full_get_segment_t0(context, i) * 10
                let t1 = whisper_full_get_segment_t1(context, i) * 10
                segments.append(WhisperSegment(text: text, startTime: t0, endTime: t1))
            }
        }
        
        return segments
    }
}

// Helper to pass the closure to C
private final class CallbackContainer {
    let callback: @Sendable ([WhisperSegment]) -> Void
    init(callback: @escaping @Sendable ([WhisperSegment]) -> Void) {
        self.callback = callback
    }
}
