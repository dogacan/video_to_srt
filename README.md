# VideoToSrt

A fast, flexible Swift CLI utility for automatically generating `.srt` transcriptions from audio and video files.

## Features

- **Pluggable Architecture**: Easily switch between transcription engines.
- **Apple Speech (macOS)**: Native, on-device transcription leveraging Apple's APIs.
- **Qwen3-ASR**: State-of-the-art multilingual transcription and forced alignment via MLX.
- **Whisper**: High-performance transcription using local `.bin` models.
- **FFmpeg Integration**: Automatic audio extraction and resampling for maximum compatibility.

## Usage

### Using Apple Engine
```bash
swift run VideoToSrt --engine apple --output transcription.srt /path/to/video.mp4
```

### Using Qwen3-ASR Engine
Requires manual setup of `mlx.metallib` (see [Qwen Setup](#qwen-setup)).
```bash
HF_TOKEN=your_token swift run --disable-sandbox -c release VideoToSrt --engine qwen --output transcription.srt /path/to/video.mp4
```

### Using Whisper Engine
```bash
swift run VideoToSrt --engine whisper --whisper-model-path ./models/ggml-base.bin --output transcription.srt /path/to/video.mp4
```

## CLI Options

| Flag | Short | Description | Default |
| :--- | :--- | :--- | :--- |
| `<input-path>` | | **(Required)** The path to the audio or video file. | - |
| `--engine` | `-e` | Transcription engine: `apple`, `qwen`, or `whisper`. | `apple` |
| `--output` | `-o` | **(Required)** Path to write the output SRT file. | - |
| `--locale` | | BCP-47 locale identifier (e.g., `en-US`, `fr-FR`). | System Locale |
| `--ffmpeg-path` | | Path to `ffmpeg` executable for unsupported formats. | - |
| `--qwen-model` | | Qwen3ASR model repo ID (MLX format). | `aufklarer/Qwen3-ASR-0.6B-MLX-4bit` |
| `--qwen-aligner-model` | | Qwen3 Forced Aligner model repo ID. | `aufklarer/Qwen3-ForcedAligner-0.6B-4bit` |
| `--whisper-model-path`| | Path to the whisper model file (e.g. `ggml-tiny.bin`). | - |
| `--whisper-vad-path`  | | Path to the whisper VAD model file. | - |
| `--whisper-use-vad`   | | Enable VAD to suppress hallucinations in silence. | `true` |
| `--whisper-vad-threshold`| | VAD sensitivity (0.0 to 1.0). Lower is more sensitive. | `0.2` |
| `--whisper-no-speech-thold`| | No-speech threshold for Whisper probabilistic filtering. | `0.6` |
| `--subtitle-offset` | | Offset in seconds to apply to all timestamps. | `0.0` |
| `--whisper-max-len` | | Whisper-specific: Max segment length in characters. | - |
| `--diarize` | | Enable Pyannote speaker diarization (injects `- ` on speaker changes). | `false` |
| `--hf-token` | | HuggingFace token for Pyannote model. Or use `HF_TOKEN` env var. | - |
| `--python-path` | | Path to the Python 3 executable for the Pyannote script. | `/usr/bin/env python3` |

## Qwen Setup

To use the `qwen` engine, you must provide a pre-compiled MLX Metal library (`default.metallib`) in the project root. This is currently required because the MLX dependency does not bundle pre-compiled shaders for command-line tools.

1.  **Clone the speech-swift repository:**
    ```bash
    git clone https://github.com/soniqo/speech-swift
    cd speech-swift
    ```
2.  **Build the metallib:**
    ```bash
    make build
    ```
3.  **Copy and rename the resulting file to this project's root:**
    ```bash
    cp build/mlx.metallib /path/to/video_to_srt/default.metallib
    ```

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

### Diarization Requirements
If you wish to use the `--diarize` flag to enable speaker separation, you must also have:
- **Python 3**
- **PyTorch** and **pyannote.audio** installed (`pip install torch pyannote.audio huggingface_hub`)
- A **HuggingFace** account and Access Token (to download the Pyannote models).
