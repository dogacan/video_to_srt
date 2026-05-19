# VideoToSrt

A fast, flexible Swift CLI utility for generating, formatting, translating, and diarizing subtitles from audio and video files.

## Features

- **Pluggable Architecture**: Easily switch between transcription backends.
- **Apple Speech (macOS)**: Native, on-device transcription leveraging Apple's Speech APIs.
- **Qwen3-ASR**: Multilingual transcription and forced alignment running locally via MLX.
- **On-Device Translation**: Translate generated subtitles on-the-fly or translate existing subtitle files (`.srt`/`.vtt`) using Apple's Translation framework.
- **Speaker Diarization**: Native speaker diarization using SpeechVAD.
- **FFmpeg Integration**: Automatic audio extraction and resampling for maximum compatibility with video formats.
- **Multi-Format Subtitle Output**: Support for SRT, WebVTT (VTT), Plain Text (TXT), and JSON.
- **Configurable Subtitle Layout**: Control maximum Characters Per Line (CPL), maximum duration of segments, and minimum words per segment.

---

## Usage

### 1. Transcribe (Default Subcommand)

Generates subtitles from a media file.

```bash
# Basic transcription (using Apple Speech, outputs SRT)
swift run VideoToSrt transcribe /path/to/video.mp4

# Translate on-the-fly to Turkish and output WebVTT format
swift run VideoToSrt transcribe --translate-to tr --format vtt /path/to/video.mp4

# Run with Qwen3-ASR engine and speaker diarization enabled
HF_TOKEN=your_token swift run --disable-sandbox -c release VideoToSrt transcribe --engine qwen --diarize /path/to/video.mp4
```

#### Transcribe CLI Options:

| Flag | Short | Description | Default |
| :--- | :--- | :--- | :--- |
| `<input-path>` | | **(Required)** The path to the audio or video file to transcribe. | - |
| `--engine` | `-e` | Transcription engine: `apple` or `qwen`. | `apple` |
| `--output` | `-o` | Path to write the output subtitle file. | `<input-file-without-extension>.<format>` |
| `--format` | `-f` | Subtitle format: `srt`, `vtt`, `txt`, or `json`. | `srt` |
| `--max-cpl` | | Maximum characters per line for subtitles. | `80` |
| `--max-duration`| | Maximum segment duration in seconds. | `7.0` |
| `--min-words` | | Minimum words per segment before splitting on duration. | `3` |
| `--locale` | | BCP-47 locale identifier for transcription (e.g. `en-US`, `fr-FR`). | System Locale |
| `--ffmpeg-path` | | Path to `ffmpeg` executable for unsupported formats. | - |
| `--subtitle-offset` | | Offset in seconds to apply to all subtitle timestamps. | `0.0` |
| `--diarize` | | Enable native SpeechVAD speaker diarization. | `false` |
| `--translate-to`| | Translate final subtitles on-the-fly to this language code. | - |
| `--qwen-model` | | Qwen3ASR model repo ID (MLX format). | `aufklarer/Qwen3-ASR-1.7B-MLX-4bit` |
| `--qwen-aligner-model`| | Qwen3 Forced Aligner model repo ID. | `aufklarer/Qwen3-ForcedAligner-0.6B-8bit` |
| `--vad-model` | | HuggingFace model repo ID for SpeechVAD model. | `aufklarer/Pyannote-Segmentation-MLX` |

---

### 2. Translate

Translates an existing subtitle file (SRT or WebVTT) into another language.

```bash
# Translate an existing SRT file to Turkish
swift run VideoToSrt translate --input Sample1.srt --target-locale tr

# Translate VTT file, overriding the source language and format
swift run VideoToSrt translate --input Sample1.vtt --source-locale en --target-locale es --format json
```

#### Translate CLI Options:

| Flag | Short | Description | Default |
| :--- | :--- | :--- | :--- |
| `--input` | `-i` | **(Required)** The path to the input subtitle file (SRT or WebVTT) to translate. | - |
| `--target-locale`| `-t` | **(Required)** Target BCP-47 language code for translation (e.g. `tr`, `es`). | - |
| `--source-locale`| `-s` | Source BCP-47 language code of input subtitles. | System Locale |
| `--output` | `-o` | The path to write the translated subtitle file. | `<input>.<target-locale>.<format>` |
| `--format` | `-f` | The output format: `srt`, `vtt`, `txt`, or `json`. | Input File Format |

---

## Translation Requirements

The translation features (both on-the-fly and standalone subtitle translation) utilize Apple's native on-device Translation framework.

> [!IMPORTANT]
> **On-Device Translation Requirements**:
> - **Offline Access**: If the target language models are already downloaded on your Mac (configured via *System Settings -> General -> Language & Region -> Translation -> Downloaded Languages*), translation runs 100% offline.
> - **GUI Permission Prompt**: If the required language model is missing, the OS will attempt to display a graphical permission sheet to prompt for the download. This requires the CLI tool to be run inside a GUI user session.

---

## Qwen Setup

To use the `qwen` engine, you must provide a pre-compiled MLX Metal library (`default.metallib`) in the project root. This is currently required because the MLX dependency does not bundle pre-compiled shaders for command-line tools.

1. **Clone the speech-swift repository:**

    ```bash
    git clone https://github.com/soniqo/speech-swift
    cd speech-swift
    ```

2. **Build the metallib:**

    ```bash
    make build
    ```

3. **Copy and rename the resulting file to this project's root:**

    ```bash
    cp build/mlx.metallib /path/to/video_to_srt/default.metallib
    ```

---

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

---

## Requirements

- Swift 6+
- macOS 26+ (macOS 15.0+ SDK)
- FFmpeg (optional, recommended for wide format support)
