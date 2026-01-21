<p align="center">
  <img src="assets/Axii-GitHub-Social.png" alt="Axii - Your voice, your command, your privacy" width="100%">
</p>

# Axii

Axii is a macOS menu bar app for voice-to-text dictation. Press a hotkey, speak, and your words are transcribed and pasted wherever your cursor is. Everything runs locally on your Mac - no cloud, no subscriptions, no data leaving your device.

## Features

- **Hotkey-triggered** - Press Control+Shift+Space to start/stop recording
- **Local transcription** - Powered by NVIDIA Parakeet, runs entirely on your Mac
- **Instant paste** - Text appears at your cursor automatically
- **Speaker diarization** - Identify different speakers in conversations
- **Conversation mode** - Continuous transcription for meetings and notes

## Screenshots

| Listening | Transcribed |
|:-:|:-:|
| ![Listening mode](assets/screenshot-listening.png) | ![Transcribed](assets/screenshot-transcribed.png) |
| *Press hotkey to start recording* | *Text transcribed and entered automatically* |

## Requirements

- macOS 15.0+
- Apple Silicon Mac (M1/M2/M3/M4)

## Installation

### Download (Recommended)

1. Download the latest `Axii.dmg` from [Releases](https://github.com/bwarzecha/Axii/releases)
2. Open the DMG and drag Axii to Applications
3. Launch Axii from Applications
4. Grant microphone and accessibility permissions when prompted

### Build from Source

```bash
git clone https://github.com/bwarzecha/Axii.git
cd Axii
open Axii.xcodeproj
```

## Acknowledgments

Axii is built on the shoulders of these excellent projects:

- [FluidAudio](https://github.com/FluidInference/FluidAudio) - Swift ASR framework
- [NVIDIA Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) - Speech recognition model
- [HotKey](https://github.com/soffes/HotKey) - Global hotkey handling by Sam Soffes
- [AWS SDK for Swift](https://github.com/awslabs/aws-sdk-swift) - Bedrock integration
- [PyAnnote](https://github.com/pyannote/pyannote-audio) - Speaker diarization

## License

Apache-2.0
