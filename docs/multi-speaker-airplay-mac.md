# Play Mac audio on multiple AirPlay speakers with DALI

DALI is an open-source AirPlay sender for macOS. It is designed to take audio from your Mac and play it through several AirPlay speakers, with one place to choose speakers and adjust their levels.

[See the app](../README.md#see-the-app) · [Preview release](https://github.com/fortun8te/dali/releases/tag/v1.2.0-preview.1) · [Build instructions](building.md)

## What you need

- An Apple Silicon Mac running macOS 15 or later for the current engine build.
- AirPlay speakers reachable on the same trusted local network.
- System audio recording permission for DALI.
- Chrome and the optional extension if you want supported web video to follow the audio delay.

DALI is a developer preview. A signed Mac download is not available yet, and real speaker combinations still need broader testing.

## Set up multi-speaker audio from your Mac

1. [Build DALI from source](building.md) and place the app in Applications.
2. Open DALI and allow system audio in the macOS permission step.
3. Choose the AirPlay speakers you want to use together.
4. Choose all Mac audio or a selected app, then press Play.
5. Adjust each speaker’s volume in DALI. Your speaker choices are saved.

The [setup guide](getting-started.md) includes the permission and Chrome installation details. The [UI gallery](ui-tour.md) shows each screen.

## Can I send system audio to multiple speakers?

That is DALI’s main purpose: capture Mac audio and send it to a selected group of AirPlay receivers. It also offers a selected-app audio source. Receiver compatibility and physical synchronization depend on the speakers and network; they are not guaranteed for every combination.

## Can I use it for multi-room audio?

You can select AirPlay speakers in different rooms if they are reachable on the same network. Each speaker has its own level. The current preview needs real multi-room testing, especially across different speaker models and busy Wi-Fi networks.

## What about YouTube and other video sites?

AirPlay adds audio delay. DALI’s optional Chrome extension holds supported video frames back by the app’s timing estimate. Tests cover YouTube-style players, Shorts, TikTok and Instagram-style feeds, and changing video elements. Protected video and some player modes cannot use the delayed picture. See [video compatibility](../README.md#video-compatibility) for the exact testing scope.

## Does DALI turn my Mac into an AirPlay receiver?

No. DALI sends Mac audio to speakers. It is not an app for receiving iPhone audio on your Mac.

## Does it combine Bluetooth, USB and AirPlay speakers?

The current project targets AirPlay speakers. It does not promise a combined Bluetooth, USB and AirPlay output group.

## Is DALI ready for everyday use?

It is available for developers and early testers. Browser timing and app behavior have automated coverage, but signed distribution, Chrome Web Store publication, clean-machine setup, and physical speaker validation remain release requirements. See [release readiness](releasing.md).

## Share your speaker results

Have a setup worth testing? [Submit a speaker compatibility report](https://github.com/fortun8te/dali/issues/new?template=speaker-compatibility.md) with the models, macOS version, and what worked or failed. Reports help establish which multi-speaker AirPlay setups are reliable.
