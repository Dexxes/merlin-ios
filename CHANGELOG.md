# Changelog

All notable changes to Merlin for iOS are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Tags: tags can be nested like on Nextcloud. The side menu shows the tag
  tree with an arrow to expand or collapse sub-tags (remembered across
  launches); long-press a tag and choose "Move to…" to put it below another
  tag or back on the top level. Opening a tag also lists the articles of all
  its sub-tags, and hiding a tag hides its sub-tags too. When creating a new
  tag while adding or tagging an article, "Below" picks its parent tag.

### Fixed
- Tags: archiving, restoring or (un)favoriting an article inside a tag view
  no longer makes it vanish from the list (or stay when it should go); the
  list now follows the tag view and its archive toggle instead of the main
  filter underneath.
- Comments: with "Newest reply first", the thread with the newest reply
  now also comes first among several threads on the same passage (they kept
  the server order before).

### Added
- Tags: a tag view now shows archived articles by default, like Nextcloud.
  In lists that mix active and archived articles (a tag, Favorites) archived
  ones carry an "Archived" label and are slightly faded. The eye button still
  hides them.
- App tour: the last step now lets you pick your accent color (progress bar
  and highlights) from a few suggestions or any custom color. It is the same
  setting as "Accent color" under Appearance in the reader menu and is synced
  to the server when the tour ends.
- Comments: highlighted passages and the whole article can be commented on,
  with threaded replies. The highlight toolbar has a new "Comment" button: on
  a fresh selection it opens the comment field with the quoted passage
  without marking anything; only once the comment is sent is the passage
  underlined (not colored). Tapping an underlined passage opens its comments,
  and deleting its last comment removes the underline. On an existing
  highlight the button opens its comments. Highlights with comments show a
  count badge. All comments are reachable from the side menu. Comments and
  highlights from visitors of the public share link (and from other devices)
  appear right away: the reader keeps a push connection to the server
  (Server-Sent Events) instead of polling. Your own comments can be edited,
  any comment can be deleted. Removing a highlight that has comments asks
  first; its threads are kept with the quoted text. The share link sheet has
  a switch "Visitors can highlight and comment". Requires Merlin for
  Nextcloud with comments; with merlin-server nothing changes.
- Side menu: the "Audio" category (Continue listening, Not listened,
  Favorites, Archive with counts) is now shown alongside Pages and Videos, as
  in Merlin for Nextcloud. Audio articles (server category `Audio`) no longer
  appear under Pages; "Audio" views can also be chosen as the start view.
- Author links: when the server delivers a profile link for the author
  (`authorUrl`, detected automatically or set by a content filter's
  `<metadata><author-link>` rule), the author name in the reader header is
  underlined and opens the link dialog on tap (if the name is truncated, the
  flyout with the full name carries the link). The byline at the end of the
  article links the name too. Only absolute http(s) links are used; older
  servers without the field are unaffected.
- Lead videos in text articles: when the server delivers the article's lead
  medium as a video (`div.merlin-media` with `data-media-kind="video"` and an
  https file/HLS source, e.g. the JSON-LD VideoObject on tagesschau.de), the
  reader now plays it on top of the hero image, like the web reader does.
  Previously only the hero image plus a "Zum Video" link were shown. The
  player reuses the inline-video player (hero image as poster, caption below);
  if playback fails, image and link come back.
- Inline videos: videos in the middle of an article (server `<media><inline>`,
  e.g. the ARD player on rbb24.de, delivered as `figure.merlin-inline-media`
  with a poster image and a `div.merlin-inline-media-source` marker) now play
  directly in the reader. A native WebKit player (mp4 or HLS, inline with a
  fullscreen option) replaces the poster image and the "Zum Video" link; if
  playback fails, image and link come back. The caption stays below the
  player, highlights in it keep working.
- Audio articles: instead of the hero image plus a "Zum Audio" link, the reader
  header now shows a native audio player with the hero image as cover and the
  controls as an overlay (play/pause, scrubber with elapsed/remaining time,
  back 15 s / forward 30 s, speed 0.75-2x, AirPlay, version picker when the
  server offers several). The source comes from the article's media marker
  (`div.merlin-media`) or `GET /articles/{id}/media`; the caption and tonal
  steps move below the player. Playback continues in the background with
  lock-screen / control-centre controls, a mini player in the article list
  (tap to return to the article), and remembers position and speed. Starting
  read-aloud pauses the audio and vice versa. Video articles and embeds are
  unchanged.
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
  the left (2.5 em wide, no background tile), spanning the full height of the
  box, with title and text beside it, vertically centred
  (`supportBox.iconUrl`, read by the server from the page's
  `apple-touch-icon` / `<link rel="icon">`). An icon that fails to load is
  simply left out. It is not treated as an article image: no lightbox on tap
  and no "image unavailable" placeholder.
  - Retention period (Löschfrist): Merlin for Nextcloud can now delete archived
  articles automatically after a period counted from archiving, with a
  separate period for favorites. Settings has a new "Retention Period"
  section with a slider per type, like the cache slider: 1 day up to the
  maximum set by the server admin, day by day; the right end means "as long
  as allowed" ("Maximum" with an admin limit, otherwise "Never", with the
  slider reaching 365 days). The onboarding tour has a new step
  explaining the periods that apply, and users who already finished the tour
  see a one-time notice when a period is set or shortened (shared with the
  Nextcloud web app, so it is shown only once per change). Standalone servers
  without retention support are unaffected.
- Comments: under "All comments" a sort button orders the threads by their
  newest reply, newest or oldest first, or by their order in the text. The
  choice is remembered.
- Comments: web addresses in comments are tappable links.

### Changed
- Side menu: Pages, Videos and Audio are no longer three stacked groups.
  A segmented control at the top (Text · Video · Audio) picks the media
  type, and only its four views (Continue, Unread/Unseen/Not listened,
  Favorites, Archive with counts) are listed below. Switching tabs does not
  change the list; tapping a view does. When the menu opens, the tab matches
  the current list. Tags, view mode, Reminders, Settings and App Tour stay
  shared below. The app tour's demo menu shows the same control.
- Reader: the placeholder for images that cannot be loaded now reads
  "Bild nicht abrufbar" / "Image unavailable" (previously the hard-coded
  German text "Webseite verhindert Bilddownload") and comes from the
  localization key `articleReader.imagePlaceholder.unavailable`.
- Comments: every author has a color (you are always orange, visitors of the
  share link pick their own). It colors the underline of commented passages,
  the count badge on them and the dot and bar next to each comment. The count
  badge is no longer white on light orange. Deleting is a trash icon at the
  top right of a comment, and the comments sheet has no "Comments on this
  passage" title any more. Needs merlin-nextcloud 1.0.16 for the colors.

### Fixed
- Highlights: a new highlight in a paragraph that already had one before it
  disappeared a moment after it was made (and on every reopen). The reader
  now redraws highlights in the order they were created, like the web
  reader, because each one's position was recorded with the older ones in
  place.
- Reader: 3sat videos play in the native player like ARD, ZDF and Arte
  (needs Merlin for Nextcloud with 3sat support).
- Reader: ARD/ZDF/Arte articles whose stream cannot be loaded (e.g. a film
  that is only available late in the evening, or one that is no longer
  online) show the title image again instead of nothing at the top.
- Quotes: a normal paragraph following a blockquote is no longer styled as the
  quote attribution; only a paragraph consisting solely of a `<cite>` is.
- Comments: the underline of commented passages was black and thin on
  iOS. A trailing `-webkit-text-decoration` shorthand reset its color and
  thickness in WebKit, so it now uses the author color.
- Comments: opening an article always asks the server for the current
  comments first, and coming back from the background reconnects the live
  channel again (it stayed closed before), so new comments show up.
- Comments: several threads on the same passage now sit together under a
  single quote instead of repeating the quote above each thread.

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
