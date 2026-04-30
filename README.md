# VideoToSrt

A fast, flexible Swift CLI utility for automatically generating `.srt` transcriptions from audio and video files.

## Features

- **Pluggable Architecture**: Easily switch between transcription engines.
- **Apple Speech (macOS)**: Native, on-device transcription leveraging Apple's APIs.
- **Whisper**: High-performance transcription using local `.bin` models.
- **FFmpeg Integration**: Automatic audio extraction and resampling for maximum compatibility.

## Usage

### Using Apple Engine
```bash
swift run VideoToSrt --engine apple --output transcription.srt /path/to/video.mp4
```

### Using Whisper Engine
```bash
swift run VideoToSrt --engine whisper --whisper-model-path ./models/ggml-base.bin --output transcription.srt /path/to/video.mp4
```

## CLI Options

| Flag | Short | Description | Default |
| :--- | :--- | :--- | :--- |
| `<input-path>` | | **(Required)** The path to the audio or video file. | - |
| `--engine` | `-e` | Transcription engine: `apple` or `whisper`. | `apple` |
| `--output` | `-o` | **(Required)** Path to write the output SRT file. | - |
| `--locale` | | BCP-47 locale identifier (e.g., `en-US`, `fr-FR`). | System Locale |
| `--ffmpeg-path` | | Path to `ffmpeg` executable for unsupported formats. | - |
| `--whisper-model-path`| | Path to the whisper model file (e.g. `ggml-tiny.bin`). | - |
| `--subtitle-offset` | | Offset in seconds to apply to all timestamps. | `0.0` |
| `--whisper-max-len` | | Whisper-specific: Max segment length in characters. | - |

## Testing

Before running tests, download the required sample media files:

```bash
./scripts/download_test_data.sh
```

Then run the automated test suite:

```bash
swift test \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks \
  -Xlinker -rpath -Xlinker /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks
```

## Requirements

- Swift 6+
- macOS 15+ (Project target is 26, but functionality relies on recent macOS)
- FFmpeg (optional, recommended for wide format support)
