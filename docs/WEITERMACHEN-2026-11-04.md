# Weitermachen wie zuvor, „Zuletzt benutzt“ und Begrüßung mit Namen (04.11.2026)

Wunsch des Inhabers vom 04.11.2026 für die iPad-App StudiNow. Alles bleibt auf dem Gerät, je Datencontainer
(Apple-ID und Hochschule); nichts geht ins Netz.

## 1. Begrüßung mit Namen

Übersicht: „Hallo Ahmad – lass uns gemeinsam lernen.“, vor 11 Uhr „Guten Morgen, Ahmad – …“, ab 18 Uhr
„Guten Abend, Ahmad – …“; ohne Namen „Hallo – lass uns gemeinsam lernen.“.

- Reine Funktionen: `apps/apple/UniFlow/Design/UFGreeting.swift` (`UFGreeting.text`, `salutation`, `displayName`,
  `pick`). Namen werden getrimmt, leer zählt als kein Name, über 24 Zeichen wird auf 23 Zeichen plus „…“ gekürzt.
- Namensquellen in dieser Reihenfolge (`UFGreeting.pick`):
  1. **Rufname**, den der Nutzer selbst eingibt: Einstellungen → Konto („Rufname“) oder einmal in der Begrüßung beim
     ersten Start („Wie sollen wir dich nennen?“). Gespeichert in den Einstellungen des Containers
     (`uniflow.greeting.rufname`); vor der Anmeldung vorgemerkt (`uniflow.greeting.rufname.pending`) und beim ersten
     Lesen in den Container übernommen.
  2. Anzeigename des StudiNow-Kontos (hat in V1 keinen; die Stelle ist vorbereitet).
  3. Vorname aus „Mit Apple anmelden“: Apple liefert ihn nur bei der ersten Anmeldung; `AccountStore` speichert ihn
     dann mit dem Konto im Schlüsselbund (`givenName`). Ältere Konten: das erste Wort des gespeicherten Namens.
  4. Sonst ohne Namen.

  Abweichung von der Reihenfolge im Auftrag (Konto, Apple, Rufname): der selbst eingegebene Rufname steht vorn, weil
  ein Feld, das neben einem Apple-Namen nichts bewirkt, verwirrt. Soll es anders sein, genügt die Reihenfolge in
  `UFGreeting.pick` (Test `GreetingAppTests.testSourceOrder`).
- Web: unverändert (Tageszeit ohne Namen, `app/static/views-home.js`); das Web kennt keinen Namen.

## 2. Weitermachen wie zuvor

Wurde das Dokument nicht ausdrücklich geschlossen (iPad gesperrt, ausgeschaltet, App von iOS oder im App-Umschalter
beendet), zeigt der nächste Start:

- das zuletzt offene Dokument auf seiner Seite,
- die KI-Hilfe offen, wenn sie offen war, mit dem ganzen Gespräch (Fragen, Antworten, Karteikarten, Quellen,
  Anschlussfragen über den gespeicherten Modus, „Schon erklärt“ über `explain`),
- „Daneben öffnen“ mit dem zweiten Dokument (auf der Seite, mit der es geöffnet wurde).

Wer das Dokument verlässt (Übersicht, andere Seite), schließt es ausdrücklich: dann startet die App dort.

Speicherorte (je Container):

| Was | Wo |
| --- | --- |
| Stand je Fenster (Route, Datei, Seite, KI-Hilfe offen, zweites Dokument) | Einstellungen des Containers, `uniflow.resume.scene.<Fenster>` und `uniflow.resume.last`; Fensterkennung per `@SceneStorage("uniflow.scene")` |
| KI-Gespräche je Dokument, höchstens 15, ältestes fällt heraus | `<Container>/tutor-conversations.json` (`TutorConversations`) |
| Zuletzt gelesene Seite, zuletzt geöffnet, Anzahl | Datenbank `files.last_page`, `last_opened`, `opened_count` (wie bisher) |

Ablauf: `UFRouter.resume` (`ResumeTracker`, `Services/ResumeState.swift`) schreibt bei jedem Seitenwechsel der App
mit; der Editor (`DocumentView`) meldet Seite (entprellt mit `last_page`), KI-Hilfe und zweites Dokument. Beim Start
zeigt `MainView` sofort die Übersicht; danach prüft `restoreIfNeeded` einmal je Fenster mit
`GET /api/files/{id}`, ob es das Dokument noch gibt, und öffnet es. Fehlt es oder gibt es einen Fehler, bleibt still
die Übersicht (`ResumeDecision.decide`). Hat der Nutzer in der Zwischenzeit schon etwas geöffnet, bleibt es dabei.
Unter XCTest und mit Startparametern `-UFRoute`/`-UFAction`/`-UFDocPanel` (Bildvergleiche) wird nichts
wiederhergestellt.

## 3. „Zuletzt benutzt“

Karte auf der Übersicht (10 Einträge) und auf KI-Start (15 Einträge, unter „Zuletzt“): Dokumente, KI-Gespräche und
Wochentests in einer Liste nach Zeit, neuestes zuerst, je Art ein Symbol. Antippen öffnet das Dokument auf seiner
Seite, ein Gespräch im Dokument mit offener KI-Hilfe und seinem Verlauf, einen Wochentest.

- Kern: `GET /api/recent?limit=15` (`RecentEndpoints.swift`, `limit` 1–50): Dokumente mit `last_opened`
  (`page` = `last_page`, `opened_count`, `sub` = Fach) und Wochentests mit `started_at`/`submitted_at` (`done`).
- App: `RecentItem.merge` fügt die Gespräche aus `TutorConversations` und KI-Start-Fragen mit Dokument
  (`AIRecents`) hinzu; je Art und Datei nur der neueste Eintrag. Ein Server ohne den Endpunkt liefert nur die
  Gespräche.
- Python/Web: kein Gegenstück (docs/paritaet/ipad-app.md).

## Tests

- App: `GreetingAppTests`, `RecentListAppTests`, `TutorConversationsAppTests`, `ResumeAppTests`.
- Kern: `swift test --package-path apps/apple/Packages/UniFlowCore --filter Recent` (`RecentEndpointsTests`).

## Offen

- Die Seite des zweiten Dokuments („Daneben öffnen“) wird nur beim Öffnen gemerkt, nicht beim Blättern darin.
- Zoom und Scrollposition innerhalb einer Seite werden nicht wiederhergestellt.
- Text-Dokumente (`TextDocumentView`) speichern ihr Gespräch, merken aber KI-Hilfe-offen nicht für den Neustart.
