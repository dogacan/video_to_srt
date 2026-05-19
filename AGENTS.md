# VideoToSrt Agent Guidelines

Welcome to the `video_to_srt` project!

## Project Overview

This project is a Swift CLI tool for converting video and audio files into transcriptions (in SRT, WebVTT, Plain Text, or JSON formats) and translating subtitles. It is designed with a **pluggable architecture** to support multiple transcription and translation engines.

## Architectural Principles

1. **Pluggable Engines**:
   - The core interface is the `TranscriptionEngine` protocol located in `Sources/VideoToSrt/TranscriptionEngine.swift`.
   - All new transcription backends (e.g., Apple Speech, Qwen3-ASR) MUST implement this protocol.
   - Place new engine implementations in the `Sources/VideoToSrt/Engines/` directory.

2. **CLI Framework**:
   - We use Apple's `swift-argument-parser` for the CLI. The entry point is in `VideoToSrt.swift`.
   - The tool is split into subcommands:
     - `transcribe`: Handles audio/video transcription and optional on-the-fly translation.
     - `translate`: Handles standalone translation of existing subtitle files (SRT or WebVTT).

3. **No UI**:
   - This is strictly a command-line tool. Do not introduce AppKit or UIKit dependencies for UI purposes. (Note: `AppleTranslationEngine` uses a headless `NSWindow`/`NSHostingView` wrapper to execute SwiftUI translation tasks within a CLI context, but is non-interactive).

4. **Minimum macOS Version**:
   - The project is configured with a minimum deployment target of macOS 26 (`.macOS("26.0")` in `Package.swift`).

5. **Shared Utilities**:
   - Shared logic for audio extraction (resampling, ffmpeg integration) is in `Sources/VideoToSrt/Shared/AudioExtractor.swift`.
   - Subtitle formatting logic (SRT, WebVTT, Plain Text, JSON) is in `Sources/VideoToSrt/Shared/SubtitleFormatter.swift`.
   - Subtitle parsing logic is in `Sources/VideoToSrt/Shared/SubtitleParser.swift`.

6. **Translation Subsystem**:
   - Pluggable translation engines implement the `TranslationEngine` protocol in `Sources/VideoToSrt/TranslationEngine.swift`.
   - `SubtitleTranslator.swift` performs sentence-level grouping (reconstructing full sentences across segments using sentence-ending punctuation or pause detection) and uses proportional distribution to split the translated sentence back into timing segments.

7. **Hallucination Suppression (Whisper)**:
   - Whisper is prone to "looping" or hallucinating during silence. We combat this using three layers:
     - **VAD (Voice Activity Detection)**: Uses Silero VAD to strip silent regions before feeding audio to Whisper. Controlled via `whisper_vad_params`.
     - **Probabilistic Filtering**: Uses Whisper's `no_speech_thold` to ignore segments with high silence probability.
     - **RepetitionFilter**: A custom sliding-window filter in `WhisperTranscriptionEngine.swift` that detects and breaks infinite text loops.

8. **Speaker Diarization**:
   - Diarization is implemented natively via a Swift VAD model pipeline (using the `SpeechVAD` package).
   - Before executing the transcription engine, the `TranscriptionCoordinator` utilizes `AudioExtractor` to extract and resample input format audio to standard 16kHz wav PCM float array.
   - The `DiarizationRunner` invokes `DiarizationPipeline` to produce a list of speech segments and speaker IDs, which are parsed into a `DiarizationMap`.
   - The `DiarizationMap` is passed down to engines via `TranscriptionOptions`.
   - Inside the engines, `ResultSegmenter` consults the map and dynamically injects `-` at the start of any new subtitle segment where the speaker has changed.

## Workflow

1. **Developing Engines**:
   - Start by examining the `TranscriptionEngine` and `TranslationEngine` protocols.
   - If working on Apple Speech integration, edit `AppleTranscriptionEngine.swift`.
   - If working on Apple Translation integration, edit `TranslationEngine.swift`.

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
