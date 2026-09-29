# Changelog

All notable changes to Merlin for iOS are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Support box in the reader: when the source has a subscription and/or donation
  page in its content filter (`supportBox` from `GET /articles/{id}`), a note
  "Enjoying this article from …? Consider taking out a subscription or making a
  donation" links to them between two paragraphs, tinted with the accent
  colour. Hidden when a subscription login is active for that site.
- The support box shows the icon of the article's own page next to its title
  (`supportBox.iconUrl`, read by the server from the page's
  `apple-touch-icon` / `<link rel="icon">`). An icon that fails to load is
  simply left out. It is not treated as an article image: no lightbox on tap
  and no "website prevents image download" placeholder.

## [0.1.0] - 2026-08-25

Initial public snapshot of the iOS client.

### Added

- Article list with list/grid layouts, filters (unread/all/favorites/archive/videos), search and tag filtering
- Full-screen article reader with adjustable font size, theme and font, saved scroll/reading position, and configurable reading-progress bar
- Highlight system with a JavaScript bridge into the article web view and an in-reader color picker
- Offline-first article and image caching, with automatic replay of queued mutations once back online
- Text-to-speech playback via the Piper TTS pipeline, streamed from the Nextcloud backend
- Reminders for articles with local notifications and deep-link navigation into the reader
- Paywall subscription credential management for supported sites
- Nextcloud Login Flow v2 for setup, with credentials shared between the app and the Share Extension via the iOS Keychain
- Share Extension (`MerlinShare`) for saving articles from the iOS share sheet
- Spotlight-guided onboarding tour for first-time users
