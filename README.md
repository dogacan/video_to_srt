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
swift run VideoToSrt --engine apple /path/to/video.mp4
```

### Using Whisper Engine
```bash
swift run VideoToSrt --engine whisper --whisper-model-path ./models/ggml-base.bin /path/to/video.mp4
```

## Testing

Run the automated test suite with the following command to ensure all engines (Apple & Whisper) are working correctly:

```bash
swift test --disable-sandbox \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks \
  -Xlinker -rpath -Xlinker /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks
```

## Requirements

- Swift 6+
- macOS 26+
- FFmpeg
