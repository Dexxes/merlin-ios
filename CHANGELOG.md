# Changelog

All notable changes to Merlin for iOS are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- PDF articles: a saved link to a PDF (server category `PDF`, or a URL ending in
  `.pdf`) opens in the reader as the document itself. The server stores only
  the URL; the app downloads the PDF from the source when the article is opened
  (plain `URLSession`, never with the Merlin login), renders it page by page
  inside the reader's scroll view (reading progress and position restore work
  as for text articles) and keeps a local copy for offline reading
  (`PDFCacheService`; pruned by the cache retention, on delete and by "Clear
  Cache"). Lists show a PDF placeholder instead of the logo. Limitations: no
  pinch zoom, text selection, highlights or read-aloud for PDFs;
  password-protected PDFs show a notice with "Open in browser". Local file URLs
  shared to the extension are ignored.
- Support box in the reader: when the source has a subscription and/or donation
  page in its content filter (`supportBox` from `GET /articles/{id}`), a note
  "Enjoying this article from …? Consider taking out a subscription or making a
  donation" links to them between two paragraphs, tinted with the accent
  colour. Hidden when a subscription login is active for that site.
- The support box shows the icon of the article's own page as its own column on
  the left (4.5 em wide, no background tile), spanning the full height of the
  box, with title and text beside it, vertically centred
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
