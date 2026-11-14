# Merlin for iOS

Merlin is a cross-platform read-it-later app. This repository contains the native **iOS client**, built with Swift 6 and SwiftUI, talking to a [Nextcloud](https://nextcloud.com) backend (the [`merlin-nextcloud`](https://github.com/Dexxes/merlin-nextcloud) app) via REST.

The app ships as two targets:

- **Merlin** – the main app (article list, reader, offline cache, TTS playback)
- **MerlinShare** – a Share Extension that adds Merlin to the iOS share sheet, so articles can be saved from Safari or any other app

## Features

- **Offline-first**: articles and images are cached to disk, so the reading list stays usable without a network connection; failed mutations (favorite/archive/tags) are queued and automatically replayed once the device is back online
- **Full-screen reader** with adjustable font size, theme and font, saved scroll position, and a configurable reading-progress bar
- **Highlights** with an in-reader color picker, backed by a JavaScript bridge into the article `WKWebView`
- **Text-to-speech** playback of articles via a self-hosted Piper TTS pipeline, streamed from the Nextcloud backend
- **Reminders** for articles, delivered as local notifications with deep-linking back into the reader
- **Tags**, favorites, archive, search, and list/grid layouts
- **Paywall subscription credentials** for supported sites, stored and validated server-side
- **Login Flow v2** (Nextcloud's OAuth-like flow) for setup, with credentials shared between the app and the Share Extension via the iOS Keychain access group

See [Structure.md](Structure.md) for a full breakdown of the codebase (models, services, view models, views).

## Requirements

- Xcode 16+ / Swift 6 toolchain, or [xtool](https://github.com/xtool-org/xtool) for building/signing outside of Xcode
- iOS 18+
- A running Merlin backend: either the [`merlin-nextcloud`](https://github.com/Dexxes/merlin-nextcloud) app on a Nextcloud instance, or the [`merlin-standalone-server`](https://github.com/Dexxes/merlin-standalone-server)

## Building

The project uses Swift Package Manager (`Package.swift`) — there is no checked-in `.xcodeproj`. `Merlin` and `MerlinShare` are library products; xtool wraps them into the app and the share extension using `xtool.yml`.

**With Xcode:**

Opening `Package.swift` directly is only good for editing — Xcode cannot run a library product. Let xtool generate a wrapper workspace instead (requires xtool ≥ 1.22 on macOS):

```bash
xtool dev generate-xcode-project
open xtool/Merlin.xcworkspace
```

Then select the **`Merlin-App`** scheme (not `Merlin`, which is the bare library) and run it on a simulator. For a real device, set your team under *Signing & Capabilities* for both `Merlin-App` and `MerlinShare-Extension`.

Notes:

- The generated project lives in `xtool/` (git-ignored). Re-running the command overwrites it, including the team selection. New Swift files or resources don't need a regeneration — only changes to `xtool.yml`, `Info.plist` or entitlements do.
- Xcode signs with the bundle IDs from `xtool.yml` as they are (`dev.merlin.app`, `group.dev.merlin`), while xtool registers prefixed IDs (`XTL-….dev.merlin.app`). So an Xcode build installs as a separate app next to an xtool build. If Xcode reports an ID as unavailable, change it locally in the target settings.

**With xtool:**

```bash
xtool dev
```

`xtool.yml` defines the app's bundle ID (`dev.merlin.app`), icon, and the `MerlinShare` extension's metadata.

## Configuration

On first launch, connect the app to your Nextcloud instance either via the built-in Login Flow v2 (recommended) or by entering a username and [app password](https://docs.nextcloud.com/server/latest/user_manual/en/session_management.html#managing-devices) manually in Settings.

## Project structure

See [Structure.md](Structure.md) for a file-by-file overview of `Sources/Merlin` and `Sources/MerlinShare`, and the top-level `CLAUDE.md` for how this app fits into the broader Merlin platform (Nextcloud backend, standalone server, Android, browser extensions).

## Privacy

Merlin collects no data for the developer: no analytics, no tracking, no ads. See [PRIVACY.md](PRIVACY.md) (German and English).

## License

Copyright (C) 2026 Julian von Bülow

Licensed under the GNU Affero General Public License v3.0 (AGPL-3.0) — see [LICENSE](LICENSE).
