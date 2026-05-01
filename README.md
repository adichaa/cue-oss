# cue

A floating macOS overlay that lets an AI see your screen and guide you through — or fully execute — tasks across any app, step by step, on your real Mac.

> Not a chatbot. Not a sandbox. A visible, watch-every-step AI assistant that sits on your desktop and helps you use the software you already have open.

---

## Demo

<!-- TODO: add GIF -->

---

## What it does

Summon cue with a hotkey, type a task ("create a GitHub PAT", "extract this Grafana query to CSV", "set up an AWS IAM role"), and cue sees your screen and either:

- **Tells you exactly what to do** — with a visual indicator on the target element (Coach mode)
- **Does it for you** — clicking, typing, scrolling, with your approval at each step (Auto mode)
- **Runs it in the background** — full headless automation while you keep working (Agent mode)

Every action happens in the foreground, in the app you're looking at. You watch every click as it happens.

---

## Requirements

- macOS 14+
- Xcode 15+ (for building)
- [Anthropic API key](https://console.anthropic.com) (BYO — your key, your data)

---

## Install

**Download:** [cue-0.1.dmg](https://github.com/adichaa/cue-oss/releases/latest) — drag to Applications, launch, done.

**Or build from source:**

```bash
git clone https://github.com/adichaa/cue-oss
cd cue-oss
bash build-app.sh
```

On first launch cue will walk you through granting Screen Recording and Accessibility permissions, and prompt for your API key.

---

## Hotkeys

| Gesture | Effect |
|---|---|
| `⌘⇧Space` | Toggle cue |
| `qq` | Open in text mode |
| `qqq` | Open in voice mode |
| `Esc` | Dismiss |
| `Enter` (when active) | Next step |

---

## Modes

**Coach** — cue sees your screen and tells you the next step with a visual indicator on the exact target. You do it, press Enter, repeat.

**Auto** ⚡ — same as Coach but approved actions execute automatically. High-stake actions (delete, send, pay) always prompt.

**Agent** 🌙 — fully headless. Task runs in the background while you work. Progress shown in a floating chip. Agents can spawn sub-agents for parallel work.

---

## Building

Copy `build.env.example` to `build.env` and fill in your signing identity if you want a signed build:

```bash
cp build.env.example build.env
# edit build.env with your Developer ID
bash build-app.sh
```

Unsigned builds work fine for local development — macOS will prompt you to allow it on first launch.

---

## Architecture

Native Swift/SwiftUI — no Electron, no web views. One dependency: [WhisperKit](https://github.com/argmaxinc/WhisperKit) for on-device voice transcription.

```
Sources/Cue/
├── AppDelegate.swift        # Orchestrator
├── TaskController.swift     # Coach/auto conversation loop
├── LLMClient.swift          # Anthropic Messages API + tool use
├── BackgroundAgent.swift    # Headless agent runner
├── ActionExecutor.swift     # HID event dispatch (clicks, typing)
├── ScreenCapture.swift      # ScreenCaptureKit screenshot pipeline
├── IndicatorOverlay.swift   # Visual action indicators
├── OverlayPanel.swift       # Floating pill window (NSPanel)
├── OverlayView.swift        # SwiftUI pill UI
└── ...
```

All data stays local — logs, history, and approval policies write to `~/.cue/`. The API key lives in macOS Keychain.

---

## License

AGPL-3.0 — see [LICENSE](LICENSE).

If you build something with this and want to keep it closed source, reach out.
