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
    
    // Anti-hallucination parameters
    public var entropyThold: Float = 2.4        // segments with entropy above this are considered failed
    public var logprobThold: Float = -1.0        // segments with avg logprob below this are considered failed
    public var noSpeechThold: Float = 0.6        // if no-speech prob exceeds this, treat segment as silence
    public var noContext: Bool = false            // don't use previous text as prompt (breaks hallucination loops)
    public var suppressBlank: Bool = true         // suppress blank outputs at the start of sampling

    // VAD (Voice Activity Detection) - Requires Silero VAD model
    public var useVAD: Bool = false
    public var vadModelPath: String? = nil
    
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
    private var context: OpaquePointer?
    
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
        free()
    }
    
    public func free() {
        if let ctx = context {
            whisper_free(ctx)
            context = nil
        }
    }
    
    public func transcribe(
        audio: [Float],
        params: WhisperParams,
        onNewSegments: (@Sendable ([WhisperSegment]) -> Void)? = nil
    ) async throws -> [WhisperSegment] {
        guard let context = self.context else {
            throw WhisperError.failedToInitialize("Context has been freed")
        }
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
        
        // Anti-hallucination parameters
        whisperParams.entropy_thold = params.entropyThold
        whisperParams.logprob_thold = params.logprobThold
        whisperParams.no_speech_thold = params.noSpeechThold
        whisperParams.no_context = params.noContext
        whisperParams.suppress_blank = params.suppressBlank

        // VAD parameters
        whisperParams.vad = params.useVAD
        if let vadPath = params.vadModelPath {
            vadPath.withCString { whisperParams.vad_model_path = $0 }
        }
        
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
