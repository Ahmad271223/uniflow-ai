# StudiFlow: Plan für die App-Store-Version (Apple-ID zuerst)

> **Vorrang hat `docs/AUFTRAG-APPSTORE-V1.md`** (Auftrag des Inhabers: V1 nur iPad, Mit Apple anmelden, Free/Plus/Pro,
> ohne PC-Server; V2 eigener Editor, Android/Windows, Google/SMS). Dieses Dokument ergänzt die Recherche dazu:
> Abgleich um 8/15/20 Uhr, Uni-Daten, Recht, Community.

Stand 25.10.2026. Grundlage: Entscheidungen des Inhabers vom 25.10., Recherche mit Gegenprüfung (iOS-Grenzen,
Stud.IP/QIS, Recht, Kosten) und die vorhandenen Konzepte `SICHERHEITSKONZEPT-KONTEN.md`, `KONTEN-ABOS-PLAN.md`,
`RELEASE-VORBEREITUNG.md`, `QIS-STUDIP-STRUKTUR.md`. Nichts Kostenpflichtiges ist gebucht oder aktiviert.

## Entscheidungen des Inhabers

| Thema | Entscheidung |
| --- | --- |
| Konto | Zuerst nur **Mit Apple anmelden**. Telefonnummer (für Windows/Web) und Google ab V2. Abgleich zwischen Geräten ab V2 (laut Auftrag Plus/Pro). |
| Editor | Zum Start der **PencilKit-Editor in der App** (nichts wird im Browser geschrieben). Der eigene Editor (1:1 wie der Web-Editor) wird intern weiterentwickelt und nach etwa einem Monat veröffentlicht. |
| Teilen | Der Editor muss mit dem Community-Teilen zusammenarbeiten. |
| Ablauf | App laden → Uni wählen (zuerst LUH) → in der App die echte QIS-Seite, Anmeldung durch den Nutzer, alles auslesen → ebenso Stud.IP → eigenes StudiFlow-Konto mit Stundenplan, Modulen, Noten → Abgleich um 8, 15 und 20 Uhr, neue Vorlesungen/Übungen/Dateien in die Lernwoche einsortiert. |

## Architektur

- **Alles Uni-bezogene läuft auf dem Gerät.** Passwörter tippt der Nutzer nur in die echte Anmeldeseite der Uni. Die
  App speichert sie nicht und schickt sie an keinen Server (Sicherheitskonzept vom 25.10.). Einen eigenen Server, der
  sich mit gespeicherten Uni-Passwörtern anmeldet, gibt es nicht: unzulässig nach den Nutzungsregeln von LUIS und
  Stud.IP, dazu App-Store-Regel 5.2.2 und das DSGVO-Risiko.
- **Konto über Apple:** Mit Apple anmelden; in V1 liegen alle Daten lokal auf dem iPad (lokales Backend). Für den
  Abgleich zwischen Geräten ab V2 ist iCloud (CloudKit) ein Weg ohne eigenen Server für Apple-Geräte; für Windows und
  Android braucht es laut Auftrag einen gehosteten Dienst.
- **Community:** über die öffentliche CloudKit-Datenbank (geteilte Inhalte, Kommentare, Meldungen). Wer zu einem Modul
  gehört, prüft die App lokal über die Stud.IP-Kurse.
- **Später (Windows/Telefonnummer, KI für alle):** Dafür braucht es einen eigenen Dienst nach
  `KONTEN-ABOS-PLAN.md`. Das ist erst mit Freigabe der Kosten möglich.

### Uni-Daten

| Quelle | Weg | Stand |
| --- | --- | --- |
| Stud.IP: Dateien, Kurse | Anmeldung in der App auf der Stud.IP-Seite, Sitzungs-Cookie im Schlüsselbund, JSON:API (`StudIPSync`) | Kern getestet, App kompiliert |
| Stud.IP: Stundenplan | `users/{id}/schedule` (seminar-cycle-dates) → regelmäßige Termine, Gruppen zur Auswahl | in Arbeit (Kern) |
| QIS: Noten, Bescheinigungen | Anmeldung in der App auf der QIS-Seite, Links folgen, Tabellen lesen; `asi` nie speichern, Stammdaten nie übernehmen | in Arbeit (Kern) |
| Ziel Stud.IP | OAuth2 mit PKCE, Refresh-Token im Schlüsselbund | Anfrage an elsa als Entwurf (`ANFRAGE-STUDIP-ZUGANG.md`) |

### Abgleich um 8, 15 und 20 Uhr – was iOS wirklich erlaubt

- iOS garantiert keine festen Uhrzeiten im Hintergrund. `BGAppRefreshTask.earliestBeginDate` ist nur eine
  Untergrenze, und ein Lauf hat nur rund 30 Sekunden. Nach dem Wegwischen der App, im Energiesparmodus oder bei
  ausgeschalteter Hintergrundaktualisierung läuft gar nichts.
- Ehrliches Versprechen: **frühestens** um 8, 15 und 20 Uhr eine kurze Prüfung im Hintergrund, nur „was ist neu?“,
  ohne vollen Abgleich. **Sicher beim Öffnen der App**. Dazu eine Erinnerung um 8, 15 und 20 Uhr
  (`UNCalendarNotificationTrigger`).
- Die Stud.IP-Sitzung läuft ab. Der Standard ist 2 h, die Einstellung der LUH ist unbekannt; gemessen sind bisher 10 min.
  Ohne OAuth2 scheitern viele Hintergrundläufe deshalb mit „bitte neu anmelden“. Messen und dann entscheiden.
- Exakte Uhrzeiten gingen nur mit einem Server, und der dürfte sich nicht mit Passwörtern anmelden (siehe oben).

### Editor und Teilen

- Der PencilKit-Editor speichert im gemeinsamen Notizformat (`packages/shared-contracts/annotations.schema.json`), das
  auch der Web-Editor am PC liest.
- Teilen erzeugt ein PDF mit der Handschrift als Vektoren (`SharePayload`). Derselbe Inhalt geht später in die
  Community.
- **Urheberrecht:** Folien und Übungsblätter aus Stud.IP gehören den Lehrenden. In die Community dürfen nur eigene
  Notizen und Lösungen, standardmäßig ohne die Originalseiten darunter. Bei Lösungen zu bewerteten Aufgaben braucht
  es einen Hinweis auf die Prüfungsordnung.
- **App Store bei Nutzerinhalten:** Melden, Blockieren und Moderation sind Pflicht.

## Reihenfolge

Maßgeblich ist die Reihenfolge in `docs/AUFTRAG-APPSTORE-V1.md` Abschnitt 3 (zuerst der erste Start). Die folgenden
Punkte ordnen sich dort ein.

1. PencilKit-Editor für den Start fertig: Datenverlust-Risiken, Dunkelmodus, Rückgängig über alle Seiten, Seiten
   einfügen und löschen, Teilen/Export mit Handschrift. *Auf develop (c1a2206), am echten iPad noch nicht geprüft.*
2. QIS- und Stud.IP-Auslesen im Swift-Kern (Notenspiegel, Bescheinigungen, Kurszeiten). *Kern fertig mit Tests,
   Anbindung in der App offen.*
3. Einrichtungsassistent: Uni wählen → QIS-Anmeldung → Stud.IP-Anmeldung → Erstabgleich mit Fortschritt; dazu
   lokale Speicherung, damit die App ohne PC-Server läuft. Logik aus `study.py`/`timetable.py` nach Swift portieren
   (Einordnen in die Lernwoche).
4. Hintergrundprüfung, Erinnerungen um 8, 15 und 20 Uhr, Hinweis „bitte neu anmelden“. *Hintergrundprüfung und
   Hinweis auf `wip/s8-hintergrund` (BGAppRefresh nur Listen, BGProcessing mit Downloads, frühestens 8/15/20 Uhr);
   die Erinnerung zu festen Uhrzeiten (`UNCalendarNotificationTrigger`) ist noch offen, am echten iPad nicht geprüft.*
5. *Nach Freigabe des Apple Developer Program:* Mit Apple anmelden echt testen, Kontolöschung in der App,
   Datenschutzerklärung, Privacy Manifest.
6. Community über CloudKit: Teilen nach Sichtbarkeit (privat, Lerngruppe, Modul, anonym), Kommentare, Melden,
   Blockieren.
7. Eigener Editor intern 1:1 nach dem Web-Editor, Veröffentlichung nach etwa einem Monat.
8. Später: Telefonnummer und Windows/Web über einen eigenen Dienst, KI für alle Nutzer.

## Aufgaben und Entscheidungen des Inhabers

1. **Apple Developer Program** (99 €/Jahr; selbst anmelden). Nötig für Mit Apple anmelden, iCloud/CloudKit, Push,
   TestFlight und App Store. Für Tests auf dem eigenen iPad reicht die kostenlose Apple-ID (Profil 7 Tage gültig,
   höchstens 3 Apps).
2. **Anfrage an elsa/ZQS** abschicken (`ANFRAGE-STUDIP-ZUGANG.md`), ergänzt um den Hintergrundabgleich und die
   schriftliche Erlaubnis für den App Store (Regel 5.2.2).
3. Reicht „frühestens 8/15/20 Uhr im Hintergrund, sicher beim Öffnen, dazu Erinnerung“?
4. KI für andere Nutzer: kostenpflichtige API oder KI auf dem Gerät?
5. Datenschutz: Wer ist Verantwortlicher? Datenschutzerklärung, Impressum, Moderation der Community.

## Risiken

- Die Stud.IP-Sitzung ist kurz (siehe oben). Möglicherweise vergibt die LUH keinen OAuth2-Zugang an Dritte.
- QIS wird durch HISinOne abgelöst (angekündigt). Die Leistungstabelle ist am echten Konto noch nie gesehen worden,
  weil noch keine Leistungen verbucht sind.
- App-Prüfung: Ohne Erlaubnis der LUH (5.2.2) droht eine Ablehnung. Apple braucht außerdem einen Demo-Modus, weil ein
  echtes Uni-Konto nicht weitergegeben werden darf.
- Mitbewerber: Studo bietet für die LUH schon Stud.IP-Anmeldung, Stundenplan und Noten.
- Mit der kostenlosen Apple-ID: Wird die App nach Ablauf gelöscht, gehen lokal ungesendete Notizen verloren. Vorher
  synchronisieren.
