# Merlin iOS – Projektstruktur

Merlin iOS ist ein Leselisten-Client für Nextcloud (iOS 17+, Swift 6, SwiftUI). Die App besteht aus zwei Targets: der Hauptapp **Merlin** und der Share-Extension **MerlinShare**, die die Einbindung in das iOS-Teilen-Menü ermöglicht.

---

## Konfigurationsdateien

| Datei | Zweck |
|-------|-------|
| `Package.swift` | Swift Package Manager-Konfiguration; definiert die beiden Targets `Merlin` und `MerlinShare`, iOS-Mindestversion (17+) und Swift-Version (6.0) |
| `xtool.yml` | Build-Konfiguration für das xtool-Buildsystem; legt App-Name, Bundle-ID (`dev.merlin.app`), Icon-Pfad und Share-Extension-Metadaten fest |
| `Sources/Merlin/Info.plist` | App-Metadaten: Bundle-ID, Anzeigename, unterstützte Orientierungen (Portrait + Landscape), Launch-Screen |
| `Sources/MerlinShare/Info.plist` | Metadaten und Konfiguration der Share-Extension |

---

## App-Einstieg (`Sources/Merlin/MerlinApp.swift`)

| Bestandteil | Zweck |
|-------|-------|
| `MerlinApp` (`@main`) | App-Entry-Point; hält das geteilte `ArticlesViewModel`, mappt das Reader-Theme auf `preferredColorScheme`, zeigt einen `SplashView` bis der erste Artikel-Load abgeschlossen ist, migriert Credentials beim Start in den App-Group-Container |
| `AppNavigator` | `@Observable`-Singleton, das Deep-Link-Navigation (z. B. „Erinnerung angetippt → Artikel öffnen“) vom `AppDelegate` an `ArticleListView` weiterreicht (`articleIdToOpen`) |
| `AppDelegate` | `UNUserNotificationCenterDelegate`; verarbeitet Tippen auf Erinnerungs-Benachrichtigungen (setzt `AppNavigator.articleIdToOpen`, markiert Reminder als `fired`) und zeigt Benachrichtigungen auch im Vordergrund als Banner |
| `SplashView` | Minimaler Ladebildschirm mit Merlin-Logo, eingeblendet bis Artikel geladen sind |

---

## Models (`Sources/Merlin/Models/`)

Reine Datenstrukturen ohne Logik, die die API-Antworten abbilden.

| Datei | Zweck |
|-------|-------|
| `Article.swift` | Datenmodell für einen Artikel (id, url, title, content, excerpt, author, siteName, imageUrl, isFavorite, isArchived, readingTime, feedId, publishedAt, createdAt/updatedAt/archivedAt, tags, isProcessing, category, requiresLoginDomain/requiresLoginPage); berechnete Properties `displayTitle`, `displaySiteName`, `faviconUrl`; eigene `Equatable`-Implementierung, die neben `id` auch `isProcessing`, `updatedAt`, `requiresLoginDomain` und die Tag-IDs vergleicht, damit SwiftUI Listenzeilen nach Server-Updates zuverlässig neu rendert |
| `Highlight.swift` | Datenmodell für eine Textmarkierung (id, articleId, highlightedText, XPath-Koordinaten, Farbe, Erstellungsdatum); inkl. `HighlightCreate`-Struct für API-Requests |
| `Reminder.swift` | Datenmodell für eine Artikel-Erinnerung (id, articleId, articleTitle, triggerAt, status `pending/fired/cancelled`, createdAt) |
| `Tag.swift` | Datenmodell für einen Tag (id, name, optionale Hex-Farbe); `Equatable` |

---

## Services (`Sources/Merlin/Services/`)

Zustandslose bzw. aktorbasierte Dienste, die Netzwerk, Authentifizierung, Caching und Persistenz kapseln.

| Datei | Zweck |
|-------|-------|
| `MerlinAPI.swift` | Zentraler REST-API-Client für das Nextcloud-Backend (thread-sicher via `actor`); stellt alle API-Methoden bereit: Artikel laden/erstellen/löschen/suchen, Status toggeln (favorit/archiviert), Tags verwalten, Highlights CRUD, Counts, Settings lesen/schreiben, Verbindungstest, TTS-Stream-URL, Paywall-Abo-Zugangsdaten (`getSiteCredentials`/`updateSiteCredential`/`deleteSiteCredential`, eigene Statuscode-Behandlung für `{message, reason}`-Fehler); implementiert außerdem einen SSE-Stream (`articleUpdateStream`) für Echtzeit-Updates beim Artikel-Verarbeiten |
| `CredentialsStore.swift` | Sichert Nextcloud-Zugangsdaten (URL, Nutzername, App-Passwort) im **iOS-Schlüsselbund** über die geteilte Access-Group `2R735BXV66.XTL-2R735BXV66.dev.merlin.app`, damit Hauptapp und Share-Extension dieselben Credentials nutzen; migriert beim Start ältere `UserDefaults`/App-Group-Daten in den Schlüsselbund (`migrateToGroupDefaultsIfNeeded`) |
| `LoginFlowService.swift` | Implementiert den Nextcloud Login Flow v2 (OAuth-ähnlich): öffnet Browser-Login, pollt alle 5 Sekunden auf Abschluss (Timeout: 5 min), speichert erhaltene Credentials im `CredentialsStore` |
| `PreferencesStore.swift` | Persistiert Nutzerpräferenzen (kein Login-bezogenes): Standard-Filter, Thumbnail-Anzeige, Reader-Schriftgröße/-Theme/-Schriftart, Fortschrittsbalken-Position (`progressEdge`), Lese-/Scrollpositions-Speicherung (`saveProgress`, `resumeOnOpen`), Bild-Prefetch nur über WLAN (`prefetchImagesOnWifiOnly`), ausgeblendete Tags (`excludedTagIds`) sowie Leseposition pro Artikel; postet `articleProgressDidUpdate`-Notification |
| `ArticleCacheService.swift` | **Offline-Cache**: persistiert komplette `Article`-Objekte (inkl. Inhalt) als JSON unter `Application Support/merlin/`, damit die App ohne Netzwerk nutzbar bleibt; additiver Merge nach Artikel-ID, liefert gefilterte Listen passend zu `ArticleFilter`/Tag; Eviction-Policy: archivierte Artikel werden 24 h nach `archivedAt` entfernt, gelöschte sofort (`actor`) |
| `ImageCacheService.swift` | **Bild-Cache** für Offline-Lesen: lädt und speichert Artikel-, Favicon- und Inline-Bilder persistent unter `Application Support/merlin/img-cache/` (SHA-256-Dateinamen mit erkannter Dateiendung, Index `articleId → [URLs]` für gezielte Eviction); `localURL(for:)` ist `nonisolated`/synchron für direkten Zugriff aus SwiftUI-Views; `prefetch(for:)` lädt mit max. 4 parallelen Downloads, respektiert WLAN-only-Einstellung, sendet artikel-eigenen `Referer`-Header gegen Hotlink-Schutz (`actor`) |
| `OfflineMutationQueue.swift` | Persistiert API-Mutationen (Favorit/Archiv toggeln, Tags setzen), die wegen Netzwerkfehlern fehlschlugen, und spielt sie via `NWPathMonitor` automatisch ab, sobald das Gerät wieder online ist; dedupliziert Toggles (gerade Anzahl = No-op) und Tag-Änderungen (nur letzter Stand pro Artikel zählt) |
| `ReminderService.swift` | Verwaltet Artikel-Erinnerungen: persistiert sie als JSON (gleiches Muster wie `ArticleCacheService`) und plant/storniert lokale Benachrichtigungen über `UNUserNotificationCenter` (`UNCalendarNotificationTrigger`); fordert bei Bedarf Benachrichtigungs-Berechtigung an (`actor`) |
| `ReportService.swift` | Sendet Artikel-Meldungen (URL + optionaler Kommentar) an das konfigurierbare `merlin-reports`-Backend; lädt die Backend-URL aus den Nextcloud-Settings (`reportBackendUrl`) und cacht sie bis `invalidateCache()` aufgerufen wird (`actor`) |
| `PiperAudioService.swift` | **TTS-Engine**: lädt Audio vom Nextcloud-TTS-Endpunkt via `URLSession.bytes` (Streaming), schreibt 64-KB-Blöcke in eine Temp-Datei, startet AVPlayer nach 256 KB Puffer (≈ 32 s bei 64 kbps). Verwaltet Playback-State (`isPlaying`, `isPaused`, `elapsed`, `totalDuration`), Stall-Recovery-Timer und `refreshPlayerItem` für wachsende Dateien während des Downloads. Spracherkennung via `NLLanguageRecognizer` |

---

## ViewModel (`Sources/Merlin/ViewModels/`)

Vermittlungsschicht zwischen Services und Views.

| Datei | Zweck |
|-------|-------|
| `ArticlesViewModel.swift` | Haupt-State-Manager für die Artikelliste (`@Observable`); verwaltet: Array aller Artikel, aktiven Filter (inkl. neuem `videos`-Filter), Suchbegriff, Ladezustand, Offline-Status (`isOffline`), Fehlermeldungen, Zählerstände, ausgeblendete Tags. Bietet Mutationsmethoden mit optimistischen Updates (`toggleFavorite`, `toggleArchive`, `delete`, `setTags`), die bei Netzwerkfehlern in die `OfflineMutationQueue` einreihen; einen **Undo-Stack** (`UndoableAction`, `undo()`, `undoToast`) für rückgängig machbare Aktionen; lädt/cached Artikel über `ArticleCacheService` als Offline-Fallback; stößt Bild-Prefetching über `ImageCacheService` an; lauscht auf SSE-Events (`startProcessingListenerIfNeeded`) für Echtzeit-Aktualisierungen verarbeiteter Artikel |
| `SiteCredentialsViewModel.swift` | State für die Paywall-Abo-Zugangsdaten-Verwaltung (`@Observable`); lädt/speichert/löscht Zugangsdaten über `MerlinAPI.getSiteCredentials`/`updateSiteCredential`/`deleteSiteCredential`; liefert `connectableDomains` (unterstützte Domains ohne gespeicherte Zugangsdaten) für die "Abo hinzufügen"-Auswahl in `SiteCredentialsView` |

---

## Views (`Sources/Merlin/Views/`)

SwiftUI-Views, die ausschließlich für Darstellung und Nutzereingabe zuständig sind.

| Datei | Zweck |
|-------|-------|
| `ArticleListView.swift` | **Hauptscreen**: zeigt Artikelliste oder -raster (Liste/Grid umschaltbar); Toolbar mit Tag-Filter (Sichtbarkeits-Icon), Filter-Menü (Ungelesen/Alle/Favoriten/Archiv/Videos), Suche, Layout-Umschalter, Einstellungs- und Hinzufügen-Button; Pull-to-Refresh; Empty-State- und Unkonfiguriert-Anzeige; reagiert auf `AppNavigator.articleIdToOpen` (Deep-Link aus Erinnerungs-Benachrichtigung) und zeigt bei Erststart `OnboardingTourView` |
| `ArticleRowView.swift` | Wiederverwendbare Listenzeile (`ArticleRowView`): zeigt Titel, Seitenname, Lesezeit, Excerpt, Tags, Favicon/Thumbnail, Leseforschritts-Indikator; Swipe-Aktionen (archivieren, favorisieren, löschen); Kontextmenü mit Teilen/Kopieren/Löschen/Tags bearbeiten/Erinnerung |
| `ArticleCardView.swift` | Eigenständige Rasterkarten-Variante (`ArticleCardView`) mit manuell implementierten Swipe-Gesten (links: Teilen-Pille, rechts: Aktionen-Pille, da `.swipeActions` nur in `List` funktioniert); Leseforschritts-Ring, Haptik-Feedback, Kontextmenü |
| `ArticleReaderView.swift` | **Vollbild-Reader** (mit Abstand größte View, ~2300 Zeilen): rendert Artikelinhalt in `ArticleWebView` (`WKWebView`-Wrapper) mit eigenem HTML/CSS-Template; Highlight-System mit JS-Bridge und Farbauswahl-Toolbar; Bild-Tap → `ImageLightboxView`; Lese-Einstellungen über eigenes Appearance-Sheet (Schriftgröße, Theme, Schriftart); konfigurierbarer Lesefortschrittsbalken; gespeicherte Scroll-/Leseposition (`ScrollPositionRestorer`); Link-Abfangung mit Aktionssheet; rechtes Seitenmenü (Drawer) mit Tags, Erinnerung, Melden, Teilen; eingebettetes Piper-TTS-Panel; eigene `ArticleTagSheet` für Tag-Bearbeitung; Undo-Toast (theme-aware); Paywall-Warnbanner (`PaywallWarningBanner`, sichtbar bei gesetztem `requiresLoginDomain`) mit Sprung in `SiteCredentialsView` und Retry-Aktion (Löschen + Neu-Anlegen via `ArticlesViewModel`) |
| `ImageLightboxView.swift` | Vollbild-Bildbetrachter mit Pinch-Zoom und horizontalem Wischen zwischen allen Bildern eines Artikels (Endlos-Karussell via Index-Multiplikation); Drag-to-dismiss mit dynamischer Backdrop-Opazität (blockiert bei Zoom) |
| `CachedAsyncImage.swift` | Bildanzeige, die zuerst aus dem `ImageCacheService`-Diskcache liest und nur bei Cache-Miss über `URLSession` nachlädt (und dabei persistiert) – so laden wiederkehrende Bilder (Karte → Reader) sofort von der Platte |
| `NoImageView.swift` | Platzhalterbild (`no-img.png`) für Artikel ohne Vorschaubild; lädt die PNG direkt aus dem Modul-Bundle (umgeht xcassets-Caching-Probleme bei SPM-Builds), Fallback: grauer Hintergrund |
| `ListFlyoutModifier.swift` | UIKit-basierte Wischgeste (`UIScreenEdgePanGestureRecognizer` direkt am `UIWindow`) zum Öffnen eines linken Flyout-Menüs ohne Konflikte mit Scroll-/Card-Swipe-Gesten (eigenes `SimultaneousGestureDelegate`) |
| `OnboardingTourView.swift` | Spotlight-geführte Erst-Start-Tour über die wichtigsten Funktionen (Flyout, Karten-Swipe, Reader, Highlights); nutzt `TourAnchorKey`/`tourAnchor(_:)` PreferenceKey-Mechanismus, um reale View-Frames für die Spotlight-Aussparung zu ermitteln |
| `AddArticleSheet.swift` | Modal-Sheet zum Hinzufügen eines neuen Artikels: URL-Eingabe, Tag-Raster mit Vorschlägen, Erstellung neuer Tags; löst Tags auf und persistiert via API |
| `TagFilterSheet.swift` | Sheet zum Verwalten ausgeblendeter Tags; in der Liste ausgewählte Tags werden aus `ArticleListView`/`ArticleCardView` herausgefiltert (`excludedTagIds`) |
| `ReminderSheet.swift` | Sheet zum Setzen/Ändern/Stornieren einer Erinnerung für einen Artikel (`DatePicker`, Fehlerbehandlung bei fehlender Benachrichtigungs-Berechtigung) |
| `RemindersView.swift` | Übersicht aller ausstehenden Erinnerungen, sortiert nach Fälligkeit; Swipe-to-Delete |
| `ReportArticleSheet.swift` | Melde-Sheet: optionaler Kommentar vor dem Versand der Meldung ans `merlin-reports`-Backend; `ReportFeedback`-Enum (`success`/`failure`) statt fragiler String-Prefix-Checks |
| `SettingsView.swift` | Einstellungsscreen: Nextcloud-URL-Eingabe, OAuth-Login-Button, manuelle Nutzername/App-Passwort-Felder, Verbindungstest, Standard-Filter-Auswahl, Reader-/Fortschrittsbalken-Einstellungen, Bild-Prefetch (WLAN-only), Cache leeren, Logout, Entwicklermodus, App-Versionsanzeige, Sprung in `SiteCredentialsView` (Paywall-Abos) |
| `SiteCredentialsView.swift` | Sheet zur Verwaltung von Paywall-Abo-Zugangsdaten (z. B. Tagesspiegel Plus): Liste verbundener Domains mit Status (verbunden/fehlgeschlagen/ungeprüft) und Swipe-to-Delete, Auswahl-Liste noch nicht verbundener, unterstützter Domains; öffnet pro Domain ein Eingabe-Sheet (`SiteCredentialEditView`, private) mit sofortigem Server-seitigem Login-Test beim Speichern; optionaler `preselectedDomain`-Parameter öffnet das Eingabe-Sheet automatisch (Aufruf aus dem Reader-Paywallbanner) |

---

## Extensions (`Sources/Merlin/Extensions/`)

| Datei | Zweck |
|-------|-------|
| `Color+Hex.swift` | Extension auf `SwiftUI.Color` zum Parsen von 6-stelligen Hex-Farbstrings (`#RRGGBB`) |
| `UIImpactFeedbackGenerator+Haptics.swift` | `HapticFeedback`-Enum mit benannten Haptik-Presets (`lightTap`, `mediumTap`, `heavyTap`, `success`, `error`, `warning`) für konsistentes Feedback bei Nutzerinteraktionen |
| `UIWindow+Shake.swift` | Erweitert `UIWindow.motionEnded`, um Schüttel-Gesten als `.deviceDidShake`-Notification app-weit zu posten (Standard-UIKit-Hook für Motion-Events in SwiftUI) |
| `View+Shake.swift` | `.onShake { }`-View-Modifier, der auf die `.deviceDidShake`-Notification reagiert (z. B. zum Auslösen von Undo) |

---

## Assets

| Pfad | Zweck |
|------|-------|
| `Sources/Merlin/Assets.xcassets/` | App-Icon und Akzentfarbe der Hauptapp |
| `Sources/MerlinShare/Assets.xcassets/` | Merlin-Logo für die Share-Extension |

---

## Share-Extension (`Sources/MerlinShare/`)

Eigenständiges Target, das im iOS-Teilen-Menü erscheint.

| Datei | Zweck |
|-------|-------|
| `ShareViewController.swift` | Herzstück der Share-Extension; drei UI-Modi: *Settings* (Zugangsdaten einrichten), *Staging* (URL-Vorschau + Tag-Auswahl), *Saving* (Fortschrittsanzeige); extrahiert URLs aus `NSExtensionItem`; lädt Tag-Liste vom Server; erstellt Artikel via POST; teilt Credentials über den Schlüsselbund-Access-Group mit der Hauptapp |

---

## Architektur-Überblick

Die App folgt einem klaren MVVM-Muster mit Offline-First-Erweiterungen:

```
Views  ←→  ViewModel  ←→  Services (API, Caches, Queue, Reminder, Report, Credentials, Preferences)
                ↑                          ↑
            Models               Persistenz (Disk-JSON, Keychain, UserDefaults)
       (Article, Tag, Highlight, Reminder)
```

Besondere Muster:
- **`actor`-basierte Services** (`MerlinAPI`, `ArticleCacheService`, `ImageCacheService`, `ReminderService`, `ReportService`) für Thread-Sicherheit
- **`@Observable`-Makro** (SwiftUI 5+) statt `ObservableObject`
- **Offline-First**: `ArticleCacheService` + `ImageCacheService` halten die App ohne Netzwerk nutzbar; `OfflineMutationQueue` puffert fehlgeschlagene Mutationen und spielt sie via `NWPathMonitor` automatisch nach
- **Optimistische Updates + Undo-Stack** in `ArticlesViewModel` für sofortiges UI-Feedback bei Mutationen
- **SSE-Streaming** via `AsyncThrowingStream` für Echtzeit-Artikel-Updates
- **Schlüsselbund-Sharing** (Access-Group `2R735BXV66.XTL-2R735BXV66.dev.merlin.app`) für Credential-Sharing zwischen Hauptapp und Share-Extension
- **JavaScript-Bridge** (`WKScriptMessageHandler`) für Highlight- und Bild-Tap-Operationen im WebView
- **Lokale Benachrichtigungen** (`UNUserNotificationCenter`) für Artikel-Erinnerungen mit Deep-Link-Navigation über `AppNavigator`
- **Spotlight-Onboarding-Tour** via `PreferenceKey`-basierter Geometrie-Erfassung (`tourAnchor`)
