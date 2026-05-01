# VideoToSrt Agent Guidelines

Welcome to the `video_to_srt` project! 

## Project Overview
This project is a Swift CLI tool for converting video and audio files into SRT transcriptions. It is designed with a **pluggable architecture** to support multiple transcription engines.

## Architectural Principles

1. **Pluggable Engines**:
   - The core interface is the `TranscriptionEngine` protocol located in `Sources/VideoToSrt/TranscriptionEngine.swift`.
   - All new transcription backends (e.g., Apple Speech, Whisper) MUST implement this protocol.
   - Place new engine implementations in the `Sources/VideoToSrt/Engines/` directory.

2. **CLI Framework**:
   - We use Apple's `swift-argument-parser` for the CLI. The entry point is in `VideoToSrt.swift`.
   - When adding new options or flags, update the `VideoToSrt` struct.

3. **No UI**:
   - This is strictly a command-line tool. Do not introduce AppKit or UIKit dependencies for UI purposes.

4. **Minimum macOS Version**:
   - The project is configured with a minimum deployment target of macOS 26 (`.macOS("26.0")` in `Package.swift`).

5. **Shared Utilities**:
   - Shared logic for audio extraction (resampling, ffmpeg integration) is in `Sources/VideoToSrt/Shared/AudioExtractor.swift`.
   - SRT formatting logic is in `Sources/VideoToSrt/Shared/SRTFormatter.swift`.

6. **Hallucination Suppression (Whisper)**:
   - Whisper is prone to "looping" or hallucinating during silence. We combat this using three layers:
     - **VAD (Voice Activity Detection)**: Uses Silero VAD to strip silent regions before feeding audio to Whisper. Controlled via `whisper_vad_params`.
     - **Probabilistic Filtering**: Uses Whisper's `no_speech_thold` to ignore segments with high silence probability.
     - **RepetitionFilter**: A custom sliding-window filter in `WhisperTranscriptionEngine.swift` that detects and breaks infinite text loops.

7. **Speaker Diarization**:
   - Diarization is implemented via an external Python script (`scripts/diarize.py`) using `pyannote.audio`.
   - Before executing the transcription engine, the `TranscriptionCoordinator` utilizes `AudioExtractor` to convert any input format to a standard 16kHz `.wav` file.
   - The coordinator invokes the Python script to produce a JSON map of speakers, which is parsed into a `DiarizationMap`.
   - The `DiarizationMap` is passed down to engines via `TranscriptionOptions`.
   - Inside the engines, `ResultSegmenter` consults the map and dynamically injects `- ` at the start of any new subtitle segment where the speaker has changed.

## Workflow

1. **Developing Engines**:
   - Start by examining the `TranscriptionEngine` protocol.
   - If working on Apple Speech integration, edit `AppleTranscriptionEngine.swift`.
   - If working on Whisper, edit `WhisperTranscriptionEngine.swift`.

2. **Testing**:
   - Use `Tests/VideoToSrtTests/VideoToSrtTests.swift` for regression testing.
   - When resolving paths in tests, use `#filePath` instead of `#file` to ensure absolute path resolution in Swift 6.
   - Running tests requires `--disable-sandbox` because the audio extractor executes `ffmpeg` via `Process`.
   - **Note**: We've added `swift-testing` as a package dependency to ensure compatibility with environments using `CommandLineTools` (where the system `Testing.framework` might not be in the search path).
   - Example command:
```bash
./scripts/download_test_data.sh
swift test --disable-sandbox
```
