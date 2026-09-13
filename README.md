# DALI

### Your Mac's audio. Every speaker in the room.

DALI is a native macOS app for playing Mac audio through multiple AirPlay speakers. Its companion Chrome extension delays supported web video to match the room's audio, including video feeds that move from clip to clip.

[Preview release](https://github.com/fortun8te/dali/releases/tag/v1.2.0-preview.1) · [Setup](docs/getting-started.md) · [Build from source](docs/building.md) · [Privacy](PRIVACY.md) · [Report an issue](https://github.com/fortun8te/dali/issues)

> **Developer preview.** Source and extension packages are available. A signed, notarized Mac download and Chrome Web Store distribution are not available yet. Apple Silicon is the current engine target. Physical speaker timing and live platform compatibility need broader testing.

## What it does

- Sends system audio, or audio from a selected app, to your AirPlay speakers.
- Lets you choose speakers, adjust their volume, and see when one needs attention.
- Keeps the existing compact dark interface, with guided setup for new users.
- Gives supported HTML video players a matching picture delay, with recovery when the app reconnects or a feed changes clips.
- Keeps audio and playback status local. No DALI account or subscription.

<p align="center">
  <img src="docs/images/onboarding-1-welcome.png" width="280" alt="DALI macOS welcome screen with a compact dark typographic layout">
  <img src="docs/images/onboarding-3-your-speakers.png" width="280" alt="Choose multiple AirPlay speakers during DALI setup">
</p>

## Video compatibility

| Video source | Implementation | Verification |
| --- | --- | --- |
| YouTube and Shorts | HTML video timing, seek/pause handling, visible clip selection | Automated player and feed regressions; live-site testing still needed |
| TikTok and Instagram Reels | Visible active video selection, recycled element and source handling | Automated feed fixtures; login-dependent live-site testing still needed |
| Other HTML video players | Generic HTML video support | Depends on the player and browser restrictions |
| DRM, protected video, picture-in-picture and fullscreen | Browser restrictions can prevent delayed rendering | Not guaranteed; use normal playback when unavailable |
| Live streams | Player-dependent | Not guaranteed |

The extension matches the delay reported by DALI. It cannot measure the sound at your seat; speaker hardware and network conditions still matter.

## Get started

You need macOS 15 or later, Apple Silicon for the current engine build, Chrome, and AirPlay speakers reachable on the same local network. See the [setup guide](docs/getting-started.md). Existing DALI users keep their saved room settings and skip first-run onboarding.

For contributors, start with [building](docs/building.md), [compatibility tests](docs/compatibility.md), and [release requirements](docs/releasing.md).

## Built on OwnTone

DALI uses a modified [OwnTone](https://github.com/owntone/owntone-server) engine for AirPlay playback. The modified source, upstream commit, and build notes are included under `third_party/owntone` and `third_party/README.md`. The app and extension are MIT licensed; OwnTone and other dependencies retain their own licenses.

DALI is an independent project and is not affiliated with DALI Speakers, Apple, Google, YouTube, TikTok, or Instagram.
