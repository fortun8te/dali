# Release requirements

The release script builds a separate product. It never stops a running DALI, installs into Applications, or resets preferences.

Before publishing a Mac binary:

1. Pass `scripts/check.sh` and compile the app. Run the onboarding preview for each step and both fresh-install and existing-install paths.
2. Validate real audio delivery on at least two distinct AirPlay receivers. Test pause, seek, source change, speaker removal/rejoin, sleep/wake, network loss, and an app/extension update. Test YouTube, TikTok, and Instagram on live pages. Automated fixtures do not replace this check.
3. Build the engine and every library for the advertised architecture. Current bundled development engine is arm64 only. Do not advertise a universal or Intel build without verifying all nested libraries.
4. Package the corresponding modified engine source, dependency licenses and source obligations for every shipped library. Do not publish an engine binary with only an upstream URL if it contains local changes.
5. Sign nested code and the app with Developer ID Application, enable hardened runtime, notarize, staple, and assess the final download. A local self-signed or ad-hoc build is not a public signed release.
6. Publish Chrome Web Store metadata and privacy disclosures. Keep required permissions stable. Use the store's existing item and identity for future updates.
7. Verify downloading, installing, and updating on a clean Mac. Never use a developer's already-authorized machine as proof of first-run success.

## Packaging

```sh
DALI_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' \
DALI_NOTARY_PROFILE='your-notary-profile' \
./scripts/build-release.sh
```

Without these credentials the script creates a development build and labels it accordingly. Credentials are read from the local keychain and environment; never commit them. The current preview has no automatic app updater. Do not promise automatic app updates until a signed updater and rollback path are implemented and tested.

## Sources

- [Apple: notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple: audio capture permission](https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac)
- [Chrome: extension permission warnings](https://developer.chrome.com/docs/extensions/develop/concepts/permission-warnings)
- [Chrome Web Store: privacy requirements](https://developer.chrome.com/docs/webstore/program-policies/privacy)
- [GitHub: repository topics](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/classifying-your-repository-with-topics)

## GitHub automation activation

The current publishing login cannot write workflow files. A ready-to-use workflow is included at `docs/ci/ci.yml`. To activate hosted checks, a repository maintainer with workflow permission must copy it to `.github/workflows/ci.yml`. Until then, checks run locally and are mandatory in `scripts/build-release.sh`; hosted CI is not active.
