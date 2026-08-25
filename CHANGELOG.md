# Changelog

All notable changes to Merlin for iOS are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
