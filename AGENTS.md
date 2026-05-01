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
