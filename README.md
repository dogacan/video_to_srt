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
| `--whisper-vad-path`  | | Path to the whisper VAD model file. | - |
| `--whisper-use-vad`   | | Enable VAD to suppress hallucinations in silence. | `true` |
| `--whisper-vad-threshold`| | VAD sensitivity (0.0 to 1.0). Lower is more sensitive. | `0.2` |
| `--whisper-no-speech-thold`| | No-speech threshold for Whisper probabilistic filtering. | `0.6` |
| `--subtitle-offset` | | Offset in seconds to apply to all timestamps. | `0.0` |
| `--whisper-max-len` | | Whisper-specific: Max segment length in characters. | - |

## Testing

Before running tests, download the required sample media files:

```bash
./scripts/download_test_data.sh
```

Then run the automated test suite:

```bash
swift test --disable-sandbox
```

Note: `--disable-sandbox` is required because the tests execute `ffmpeg` to extract audio from sample files.

## Requirements

- Swift 6+
- macOS 26+
- FFmpeg (optional, recommended for wide format support)
