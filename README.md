<p align="center">
  <img src="docs/icon.png" width="128" alt="Hyperclip app icon">
</p>

# Hyperclip

A native macOS app that turns long videos into short, captioned clips on your Mac. An open alternative to Opus Clip, made with SwiftUI.

![Hyperclip finding clips in a talk and previewing one vertical, with captions](docs/screenshot.png)

## What it does

- **Paste a link, get clips.** Hyperclip downloads with [yt-dlp](https://github.com/yt-dlp/yt-dlp), so YouTube, TikTok, Instagram, X, Twitch and over a thousand other sites work. It can download only part of a long stream. You can also drop in a file of your own. Videos the Mac can't play are converted with FFmpeg.
- **Signs in as you.** For age-restricted, members-only or private videos, or when YouTube asks you to prove you're not a bot, Hyperclip uses the cookies from your browser: Safari, Chrome, Arc, Brave, Edge, Helium, Firefox, Zen and more, with a choice of profile. Hyperclip decrypts cookies itself for browsers yt-dlp can't read, like Arc. A cookies.txt file works too, and **Test** checks that everything is in place before a download needs it.
- **Transcribes on your Mac.** You can use Apple's built-in on-device transcriber (nothing to install), or [Whisper](https://github.com/ggml-org/whisper.cpp) models on the GPU (detects the language, handles jargon). Any OpenAI-compatible server works too (OpenAI, Groq, Speaches, a Hypervoice server). Every word is timed.
- **Finds the clips worth posting**, in one of three ways:
  - **Built-in (no AI).** Scores every span of whole sentences on its hook, its payoff, the pace and loudness of the delivery, and its length. Instant and offline.
  - **Decision model.** Shortlists with the built-in scores, then asks a [Jev-compatible](https://docs.typesafe.ai) decision model typed questions about each clip: how strong the hook is, whether it stands on its own, how good the payoff is, and whether people would share it. It then weighs the probabilities into a score. This works with TypeSafe's Jev or with open models you host yourself (Laya, Von, Kev, AnyJev).
  - **Language model.** Reads the whole transcript and picks moments with titles, like an editor would. This works with Ollama or LM Studio on your Mac, or with any OpenAI-compatible API.
- **Clip by hand.** Press **I** and **O** while the video plays, select words in the transcript, or drag a clip's edges on the timeline. Click any word to jump to it.
- **Frames the speaker.** Vision tracks faces and crops to 9:16, 4:5 or 1:1. The crop holds still and only moves when the speaker does, the way a camera operator would. The preview shows the crop as it will export.
- **Burns in captions** word by word, with the current word highlighted, in Bold, Clean, Boxed or One-word styles. You choose the font, size, color and position. The preview draws exactly what the export does.
- **Publishes** to X, YouTube, TikTok, Instagram, LinkedIn, Facebook, Threads, Bluesky and more through [Zernio](https://zernio.com), now or on a schedule.

## Installation

```sh
curl -fsSL https://raw.githubusercontent.com/alexisbcz/hyperclip/main/install.sh | bash
```

This builds Hyperclip from source and installs it in Applications. It needs a Mac with Apple silicon, macOS 26 or later, and Xcode. If Homebrew is installed, the script also installs yt-dlp, FFmpeg and whisper.cpp. Otherwise, install them later from **Models & Tools** in the app.

## Shortcuts

| Key | Action |
|---|---|
| Space | Play or pause |
| I / O | Mark in and out; marking out makes the clip |
| ← → (⇧ for 5 s) | Step 1 second |
| J / K / L | Back 10 s, pause, forward 10 s |
| , / . | Step one frame |
| Return | Play the selected clip |
| ⌘E / ⇧⌘E | Export the selected clip / every clip |
| ⌘K | Find clips again |

[MIT License](LICENSE)
