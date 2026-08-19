# Voxmit

Voice-first input for AI coding on macOS. Hold a global hotkey, speak, and your words are transcribed locally, refined into an engineering prompt by an LLM, and injected straight into the input box of your current AI dev tool (Kimi Code / Claude Code / Cursor / ...).

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Swift](https://img.shields.io/badge/Swift-6-orange.svg)
![Platform](https://img.shields.io/badge/macOS-14%2B-blue.svg)
![AI-Built](https://img.shields.io/badge/100%25%20AI-Built-purple.svg)

**English | [简体中文](README.zh-CN.md)**

## 🌐 Website

Visit the project website: **[https://scottli139.github.io/voxmit](https://scottli139.github.io/voxmit)**

## Screenshots

> Screenshots and a demo video are coming soon. The app is in MVP acceptance (Phase 9); the core chain below is already working end-to-end.

## How It Works

1. Hold the global hotkey (default **Right Option**) and speak.
2. Release to transcribe locally (WhisperKit small, ~500 MB, on-device; the Speech framework serves as fallback before the model download completes).
3. The raw transcript is refined into a high-quality engineering prompt by your own LLM key (OpenAI-compatible endpoint; falls back to the raw transcript on timeout/failure).
4. The result is injected into the input box of the app you were using when you pressed the key.

Target end-to-end latency (release-to-injection): **≤ 2 s** (P95, ≤ 15 s speech).

## Features

- **Push-to-talk global hotkey** — default Right Option; 200 ms hold-to-confirm, 300 ms mistouch cancel, Esc to discard. Hotkey presets: Right Option / Right Command / Right Shift / Fn.
- **Local, private transcription** — WhisperKit small runs fully on-device; audio lives in memory only, never written to disk. Chinese/English mixed supported.
- **LLM prompt refinement** — removes filler words, normalizes phrasing, and resolves anaphora from context, with hard anti-hallucination constraints. Bring your own key; unrefined fallback on timeout/failure. Hold Right Option + Shift to skip refinement.
- **Context-aware** — snapshots the frontmost app and window title when the hotkey goes down, re-checks on release, and classifies the target (terminal / editor / browser / other).
- **Clipboard + Cmd+V injection** — with clipboard snapshot/restore and change-count race protection; optional auto-send (Return) after paste; newline folding for CLI targets.
- **Non-activating recording HUD** — waveform, stage status, and success/failure feedback; visible in full screen and across Spaces without stealing focus.
- **Permission self-check & graceful degradation** — microphone, input monitoring, accessibility; deep links into System Settings; menu-bar recording fallback when the hotkey is unavailable; clipboard-only fallback without accessibility.
- **Diagnostics** — categorized os_log plus on-disk logs with one-click export from Settings.
- **Settings** — hotkey preset, input device, ASR engine (WhisperKit / Speech), LLM endpoint/model, injection behavior, auto-send.

## Tech Stack

- **Language/UI**: Swift 6 + SwiftUI / AppKit (menu-bar app, no main window)
- **Audio**: AVAudioEngine + AVAudioConverter (16 kHz mono Float32, in-memory)
- **Global hotkey**: CGEventTap (listen-only)
- **Local ASR**: WhisperKit (whisper.cpp / Core ML), Speech framework fallback
- **Refinement**: OpenAI-compatible `chat/completions` (bring your own key, stored in Keychain)
- **Context**: NSWorkspace + Accessibility API
- **Injection**: NSPasteboard + CGEvent (Cmd+V)
- **Tests**: Swift Testing with protocol mocks (no system permissions required)

## AI Development

This project is **built with AI coding assistants**:

| Tool | Model |
| --- | --- |
| [Kimi Code CLI](https://www.kimi.com/) | Kimi K3 |
| [DeepSeek](https://platform.deepseek.com/) | V4 Pro |

> 🤖 Code is generated, reviewed, and refined through AI collaboration. See commit trailers for the model used on each change.

## Permissions & Privacy

Voxmit needs three macOS permissions, each of which degrades gracefully if denied:

| Permission | Enables | If denied |
| --- | --- | --- |
| Microphone | Recording | Hard block; onboarding guides you to enable it |
| Input Monitoring | Global hotkey | Menu-bar click-to-record fallback |
| Accessibility | Cmd+V injection & window context | Clipboard-only injection + manual paste hint |

Privacy: transcription is local by default; audio is never written to disk; LLM refinement is disclosed before first use and can be turned off; the API key is stored only in Keychain.

## Getting Started

### Prerequisites

- macOS 14+ (Apple Silicon recommended)
- Xcode 16+ (Swift 6 toolchain)

### Build & Test

```bash
git clone https://github.com/scottli139/voxmit.git
cd voxmit
xcodebuild build -scheme Voxmit -destination 'platform=macOS'
xcodebuild test -scheme Voxmit -destination 'platform=macOS'
```

The WhisperKit small model (~500 MB) is downloaded on first launch; the Speech framework serves as fallback until it is ready.

## Project Structure

```
Voxmit/
├── Pipeline/          # VoicePipeline state machine, clock, models, placeholders
├── Modules/           # Permissions, Hotkey, Audio, Transcription, Refiner,
│                      # Context, Injector, Diagnostics, Storage
├── UI/                # Settings, permission onboarding, recording HUD
└── VoxmitApp.swift    # @main menu-bar app
VoxmitTests/           # Swift Testing suite with protocol mocks
docs/                  # Architecture, testing, user guide, notes, website
```

## Development Status

Phase 0–8 are implemented and verified (240 unit tests green); the project is in **Phase 9: end-to-end integration and MVP acceptance**. See [PLAN.md](PLAN.md) for the live task board and the [requirement doc](语音编程工具-需求分析与方案说明.md) for FR-level scope.

## Contributing

Contributions are welcome — bug reports, features, docs, tests and translations. See [CONTRIBUTING.md](CONTRIBUTING.md) for the dev setup and PR checklist.

- 🤖 This project is AI-built, and **AI-assisted contributions are welcome** — `AGENTS.md` is a ready-made context file for your coding assistant.
- Please follow our [Code of Conduct](CODE_OF_CONDUCT.md).

## License

This project is licensed under the MIT License — see [LICENSE](LICENSE) for details.

## Acknowledgments

- Local transcription powered by [WhisperKit](https://github.com/argmaxinc/WhisperKit)
- Inspired by the voice-dictation tooling ecosystem (VoiceInk, Wispr Flow) and the AI CLI workflow
