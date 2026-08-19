# Contributing to Voxmit

**English | [简体中文](CONTRIBUTING.zh-CN.md)**

Thanks for your interest in contributing! Voxmit is a macOS menu-bar voice-driven AI coding tool (Swift 6 + SwiftUI/AppKit). Contributions of all kinds are welcome — bug reports, features, docs, tests, translations.

> 🤖 **AI-assisted contributions are welcome.** This project is built with AI assistance. The root `AGENTS.md` is a ready-made context file for your coding assistant; the task board is `PLAN.md`; the single source of truth for requirements is `语音编程工具-需求分析与方案说明.md`.

## Environment Setup

Prerequisites: macOS 14+, Xcode 16+ (Swift 6 toolchain).

```bash
git clone https://github.com/scottli139/voxmit.git
cd voxmit
open Voxmit.xcodeproj   # SPM dependencies (WhisperKit, ...) resolve automatically
```

Real-device debugging requires granting three system permissions to the dev build (microphone / input monitoring / accessibility). See the permission matrix in the requirement doc §4.4.

## Pre-commit Checks

Run both — CI enforces them:

```bash
xcodebuild build -scheme Voxmit -destination 'platform=macOS'
xcodebuild test -scheme Voxmit -destination 'platform=macOS'
```

Notes:

- Features touching system permissions (hotkey / injection / context) must be covered by protocol mocks — tests must not require real permissions.
- Main-chain changes (hotkey → recording → transcription → refinement → injection) must record which manual-test matrix items from `docs/TESTING.md` were executed.
- SwiftLint / SwiftFormat configuration is planned but not yet wired; style follows the existing Swift conventions for now.

## Commit Conventions

Conventional prefix + short description (Chinese or English, matching existing history):

```
feat: Right Option push-to-talk with mistouch guard
fix: clipboard restore no longer overwrites newer user copy
docs: document permission matrix
test / chore / style / refactor: ...
```

- AI-assisted commits must end with a model trailer (`Model: <model name>`, the model actually used); purely manual commits omit it.
- Version bumps and releases are maintainer-only (`chore: bump version` + tag).

## Pull Request Flow

1. Branch from `main`, keep the diff focused — one PR, one thing.
2. Tag requirement-related changes with the FR number (requirement doc §3.1).
3. Make sure CI is green (build + tests). Main-chain changes must include manual-test records.
4. Small PRs get reviewed faster; large changes should start as an issue. Scheduling follows `PLAN.md`.

## Code Quality Requirements

- **Protocol isolation**: modules are decoupled via the §9.1 protocols; core logic (state machine, refinement, injection decisions) must be unit-testable without system permissions.
- **No premature scope**: work strictly by FR priority (P0 → P1 → P2); do not implement P1/P2 during MVP.
- **Zero-tolerance on keys**: the LLM API key lives only in Keychain; never in code, config, or logs.
- **Privacy red line**: audio stays in memory and is never written to disk; any network egress (refinement / cloud ASR) requires user disclosure and an off switch.
- **Language**: code identifiers in English, comments following Swift community style; docs and commit messages in Chinese (project convention); user-facing docs bilingual where applicable.
- **Doc sync**: user-visible changes update `docs/USER_GUIDE.md`; task progress goes only in `PLAN.md`; pitfalls go in `docs/implementation-notes.md`; bilingual files (`README` ↔ `README.zh-CN`, `docs/index` ↔ `docs/index.zh-CN`, `CONTRIBUTING` ↔ `CONTRIBUTING.zh-CN`) must be updated together; changing any of these conventions updates `AGENTS.md`. Diagrams use mermaid, never ASCII art.

## Where to Start

- `PLAN.md` "下一步行动" — current wave and dependencies.
- Open questions in the requirement doc §8 are already decided (2026-08-17); do not unilaterally resolve new open questions.
- Questions? Open an issue with the `question` label.
