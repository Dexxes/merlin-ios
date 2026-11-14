# Datenschutzerklärung – Merlin für iOS

*English version below.*

Stand: 14. November 2026

## Kurz gesagt

Merlin ist ein Client für deinen eigenen Server: eine Nextcloud mit der Merlin-App oder einen Merlin-Server. Der Entwickler der App betreibt keinen eigenen Dienst für die App und erhält keine Daten von dir. Die App enthält keine Werbung, keine Analyse- oder Tracking-Werkzeuge und keine Software-Bausteine Dritter, die Daten sammeln.

## Verantwortlicher

Julian von Bülow, Entwickler der App Merlin für iOS.
Kontakt: über die Issues des Projekts unter <https://github.com/Dexxes/merlin-ios/issues>.

Für die Daten auf deinem Server ist verantwortlich, wer den Server betreibt, also du selbst oder dein Server-Administrator.

## Welche Daten die App verarbeitet

### Auf deinem Gerät

- **Zugangsdaten:** Server-Adresse, Benutzername und App-Passwort liegen im iOS-Schlüsselbund. Die Share Extension „Save to Merlin“ nutzt sie über eine gemeinsame Schlüsselbund-Gruppe.
- **Zwischenspeicher:** Artikel, Bilder, PDFs, Markierungen und Lesepositionen werden gespeichert, damit die App auch offline funktioniert. Dazu kommen Änderungen, die noch nicht an den Server übertragen wurden.
- **Einstellungen und Erinnerungen:** Erinnerungen werden als lokale Mitteilungen auf dem Gerät geplant. Es gibt keine Push-Mitteilungen über einen Server.
- **Texterkennung:** Die Erkennung von Text in Bildern (Live Text, Vision) läuft vollständig auf dem Gerät.

Beim Abmelden werden Zugangsdaten, Zwischenspeicher, Lesepositionen, Erinnerungen und offene Änderungen vom Gerät gelöscht. Wenn du die App löschst, entfernt iOS alle übrigen Daten der App.

### An deinen Server

Die App überträgt alle Inhalte ausschließlich an den Server, den du selbst einträgst. Dazu gehören:

- gespeicherte Links und über das Teilen-Menü gesendete Inhalte wie Texte, Bilder, Videos und Dateien
- Tags, Favoriten, Archivstatus, Lesepositionen, Markierungen und Kommentare
- Einstellungen der App
- Zugangsdaten für Abos von Nachrichtenseiten, wenn du sie hinterlegst. Der Server nutzt sie nur, um sich bei der jeweiligen Seite anzumelden.
- Artikeltext für die Vorlese-Funktion. Die Sprachausgabe erzeugt dein Server.

Die Verbindung ist mit HTTPS verschlüsselt. Wie lange dein Server Daten speichert und wie du sie löschst, legt der Betreiber des Servers fest. In der Merlin-App für Nextcloud kannst du Artikel jederzeit löschen und eine Löschfrist für archivierte Artikel einstellen.

### Direkt an Dritte

Einige Funktionen laden Inhalte direkt von anderen Anbietern. Diese sehen dabei deine IP-Adresse und die übliche technische Anfrage.

- **Bilder in Artikeln:** Sie werden von den Websites geladen, aus denen die Artikel stammen.
- **Website-Symbole:** Sie kommen von DuckDuckGo (`icons.duckduckgo.com`). Dabei wird der Domainname des gespeicherten Artikels übermittelt, zum Beispiel `example.com`, aber nicht die vollständige Adresse.
- **YouTube-Videos:** Sie werden erst geladen, wenn du ein Video antippst. Bei einem Nextcloud-Server geschieht das über eine Seite deines Servers, sonst direkt über `youtube-nocookie.com`. Dabei gilt die Datenschutzerklärung von Google.
- **Videos aus Mediatheken:** Videos von ARD, ZDF, 3sat und Arte werden direkt von deren Servern gestreamt.
- **Melden von Artikeln:** Wenn du einen Artikel meldest, gehen Adresse und Kommentar an das Melde-Backend, das dein Server-Administrator eingerichtet hat.
- **Links:** Links und „Via archive.ph öffnen“ öffnen sich in Safari bzw. auf der jeweiligen Website.
- **Kalender:** Termine aus erkannten Texten legst du im Kalenderdialog von iOS an. Die App liest deinen Kalender nicht.

## Was die App nicht tut

- kein Tracking und keine Werbung, und keine Weitergabe oder kein Verkauf von Daten
- keine Analyse des Nutzungsverhaltens und keine Absturzberichte an den Entwickler
- kein Konto beim Entwickler: Konten gibt es nur auf deinem eigenen Server

## Berechtigungen

- **Mitteilungen:** Die App fragt erst danach, wenn du eine Erinnerung anlegst.
- **Fotos (nur hinzufügen):** Die App fragt erst danach, wenn du ein Bild oder Video ausdrücklich in deiner Fotomediathek sicherst.

Du kannst beide Berechtigungen jederzeit in den iOS-Einstellungen widerrufen.

## Deine Rechte

Nach der DSGVO hast du das Recht auf Auskunft, Berichtigung, Löschung, Einschränkung der Verarbeitung, Datenübertragbarkeit und Widerspruch. Außerdem kannst du dich bei einer Datenschutz-Aufsichtsbehörde beschweren. Da der Entwickler keine Daten von dir speichert, richten sich Anfragen zu Daten auf deinem Server an dessen Betreiber.

## Änderungen

Wenn sich die App ändert, wird diese Erklärung angepasst. Die jeweils aktuelle Fassung steht unter <https://github.com/Dexxes/merlin-ios/blob/main/PRIVACY.md>.

---

# Privacy Policy – Merlin for iOS

Last updated: November 14, 2026

## In short

Merlin is a client for your own server: a Nextcloud with the Merlin app, or a Merlin server. The developer of the app runs no service for the app and receives no data from you. The app contains no ads, no analytics or tracking tools, and no third-party components that collect data.

## Controller

Julian von Bülow, developer of the Merlin for iOS app.
Contact: via the project's issues at <https://github.com/Dexxes/merlin-ios/issues>.

Whoever runs your server is responsible for the data stored on it: you, or your server administrator.

## Data the app processes

### On your device

- **Login credentials:** server address, username and app password are stored in the iOS Keychain. The "Save to Merlin" share extension uses them through a shared Keychain group.
- **Cache:** articles, images, PDFs, highlights and reading positions are stored so the app also works offline. This includes changes not yet sent to the server.
- **Settings and reminders:** reminders are scheduled as local notifications on the device. There are no push notifications from a server.
- **Text recognition:** recognizing text in images (Live Text, Vision) runs entirely on the device.

Logging out removes login credentials, cache, reading positions, reminders and pending changes from the device. Deleting the app removes all remaining app data.

### Sent to your server

The app sends all content only to the server you enter yourself. This includes:

- saved links and content shared through the share sheet, such as text, images, videos and files
- tags, favorites, archive status, reading positions, highlights and comments
- app settings
- login credentials for news site subscriptions, if you add them. The server uses them only to log in to that site.
- article text for read-aloud. Your server generates the speech.

The connection is encrypted with HTTPS. How long your server keeps data and how you delete it is up to whoever runs the server. In the Merlin app for Nextcloud you can delete articles at any time and set a retention period for archived articles.

### Sent directly to third parties

Some features load content directly from other providers. They see your IP address and the usual technical request.

- **Images in articles:** they are loaded from the websites the articles come from.
- **Site icons:** they come from DuckDuckGo (`icons.duckduckgo.com`). This sends the domain name of the saved article, for example `example.com`, but not the full address.
- **YouTube videos:** they load only when you tap a video. With a Nextcloud server this goes through a page on your server, otherwise directly through `youtube-nocookie.com`. Google's privacy policy applies.
- **Videos from broadcaster media libraries:** videos from ARD, ZDF, 3sat and Arte are streamed directly from their servers.
- **Reporting articles:** if you report an article, its address and your comment go to the reporting backend your server administrator set up.
- **Links:** links and "Open via archive.ph" open in Safari or on the respective website.
- **Calendar:** you add events from recognized text in the iOS calendar dialog. The app does not read your calendar.

## What the app does not do

- no tracking and no advertising, and no sharing or selling of data
- no usage analytics and no crash reports sent to the developer
- no account with the developer: accounts exist only on your own server

## Permissions

- **Notifications:** the app asks only when you create a reminder.
- **Photos (add only):** the app asks only when you explicitly save an image or video to your photo library.

You can revoke both permissions at any time in iOS Settings.

## Your rights

Under the GDPR you have the right of access, rectification, erasure, restriction of processing, data portability and objection. You can also lodge a complaint with a data protection supervisory authority. Since the developer stores no data about you, requests about data on your server go to whoever runs it.

## Changes

This policy is updated when the app changes. The current version is always at <https://github.com/Dexxes/merlin-ios/blob/main/PRIVACY.md>.
