# Community und Abgleich über alle Geräte (09.11.2026)

Auftrag des Inhabers (09.11.2026): „Diskussionen, Community müssen überall gleich sein, aktualisieren usw.“ –
iPad (Build 28 = 7d1a8fb3), Mac (dieselbe iPad-App, „Designed for iPad“), Windows-App und Web (app.studinow.app).
Nachgeschärft am selben Tag: **zuerst Mac**, „Mac-Community muss mit iPad komplett kompatibel sein“; Windows und Web
später. Zweig `paritaet/community-sync-b28` (von `develop` 574a2603).

Zeilenangaben: Stand dieses Zweigs; wo Build 28 abweicht, steht es dabei.

## 1. Kurzfassung

- **iPad und Mac:** Mit `communityViaService = false` (Build 28: StudoraAccountLink.swift:203) läuft die Community auf
  beiden über **dieselbe CloudKit-Datenbank** (Container
  `iCloud.de.uniflow.ai`, öffentliche Datenbank, Standardzone). Lösungen, Kommentare, Fragen und Antworten, Likes,
  Korrekturen, geteilte Stapel und Meldungen sind auf beiden Geräten dieselben Datensätze – die Inhalte waren nie
  getrennt. **Getrennt war der Zustand des Geräts** (nur UserDefaults): Beitritte zu Kurs-Communities, Lerngruppen,
  Pseudonym und „gesehen/ignoriert“ der Korrekturhinweise. Auf dem Mac fehlten daher die Lerngruppen und Beitritte
  des iPads, Beiträge erschienen dort als „Anonym“, und das Abzeichen am Menüpunkt Community zählte schon gesehene
  Hinweise neu. **Behoben** über den iCloud-Schlüssel-Wert-Speicher (`CommunitySharedState`, Abschnitt 3.3).
- Dazu: Gerätename beim StudiNow-Konto („iPad“ auf beiden Geräten) – **behoben** (Mac heißt „Mac“).
- **iPad/Mac gegen Web/Windows:** Auf dem iPad läuft die Community **immer über CloudKit**, auch mit StudiNow-Konto
  (`StudoraAccountLink.communityViaService = false`, StudoraAccountLink.swift:209, in Build 28 Zeile 203). Web und
  Windows nutzen den Dienst (`/api/community`). **Nichts, was auf iPad oder Mac in der Community entsteht, ist im Web
  oder in der Windows-App sichtbar, und umgekehrt.** Das betrifft alle Community-Funktionen einschließlich der
  Karteikarten-Stapel. Plan in Abschnitt 5 (nicht umgesetzt; Entscheidung des Inhabers nötig).
- Persönliche Daten (Notizen, Lernplan, Karteikarten, Einstellungen, Studienverlauf) gleichen iPad, Mac, Windows und
  Web nur über das StudiNow-Konto ab (Vertrag G2, `/api/sync/*`); ohne Konto hat jedes Gerät seinen eigenen Stand.

## 2. Welche Funktion läuft wo (iPad und Mac identisch)

Wahl des Community-Wegs: `SolutionSharing.community` = `CommunityRoute.shared.service ?? container.community`
(SolutionSharing.swift:159, :164). `CommunityRoute` wird nur gesetzt, wenn `communityViaService` true ist
(StudoraAccountLink.swift:212–235) – das ist es nicht. Damit gilt für **alle Nutzer, mit oder ohne StudiNow-Konto**:
`CloudKitCommunityService` des Containers (DataContainers.swift:115). Ohne iCloud-Container im Build (Simulator, CI,
Personal Team) meldet die App „nicht verfügbar“ (CommunityCloud.swift:137).

| Funktion | iPad/Mac: Weg (Beleg) | Bedingung | Web/Windows: Weg | Für Web/Windows sichtbar? | Stand |
|---|---|---|---|---|---|
| Lösungen teilen, finden, laden, zurückziehen, aktualisieren | CloudKit `Solution` öffentlich (CommunityCloudKit.swift:200 ff., `publish`/`findForCourse`/`download`/`withdraw`) | Lesen ohne iCloud-Konto, Schreiben mit iCloud-Konto | `/api/community/solutions*` (app/community_api.py:54–233) | **nein** | Plan 5.2 |
| Kommentare (mit Stelle, Antworten, bearbeiten, löschen, melden) | CloudKit `Comment` (Inhalt verschlüsselt), CommunityCloudKit.swift:777 ff. | iCloud-Konto zum Schreiben | `/solutions/{id}/comments`, `/comments/{id}` (community_api.py:156–182) | **nein** | Plan 5.2 |
| Likes Lösung | CloudKit `Like` (:916) | iCloud-Konto | `/solutions/{id}/like` | **nein** | Plan 5.2 |
| Fragen & Antworten (Diskussion je Community) | CloudKit `Comment` mit `post:<id>` (:952, :973, :977) | iCloud-Konto | `/courses/{key}/questions`, `/questions/*`, `/answers/*` (community_api.py:247–315) | **nein** | Plan 5.2 (Dienst-Weg der App kann sie nicht: `supportsSpaceDiscussion` false, CommunityService.swift:101) |
| Korrekturvorschläge, Posteingang | CloudKit `Correction` (CommunityCorrectionsCloudKit.swift:39, :101) | iCloud-Konto | `/solutions/{id}/corrections`, `/corrections/*` (community_api.py:370–409) | **nein** | Plan 5.2 (Dienst-Weg der App: `supportsCorrections` false, CommunityService.swift:139). Chiffrat ist dasselbe Format (fixtures/community/correction-vectors.json) |
| Gesehen/Ignoriert der Korrekturen | bis Build 28 UserDefaults des Geräts; jetzt `CommunitySharedState` (iPad = Mac) | – | Dienst je Konto (`/corrections/{id}/status`) | nein | iPad↔Mac behoben (3.3) |
| Karteikarten-Stapel teilen/übernehmen/liken/melden | lokaler Router `/api/community/card-stacks*` (CardStackEndpoints.swift:180 ff.) → Anbieter CloudKit `CardStackShare` (LocalBackendHost.swift:123, CardStackCloudKit.swift:240). Die App ruft dieselben Pfade wie das Web (CardsPage.swift:318, :369), **aber am lokalen Router, nicht am Dienst** | iCloud-Konto zum Teilen | `/api/community/card-stacks*` (app/community_cards_api.py) | **nein** (nur das Kontingent zählt beim Dienst: `/adopt-quota`) | Plan 5.3 |
| Geteilte Wochenstapel, gemeinsame Wochentests | CloudKit `WeekCardStack`, `WeeklyTest` (LocalBackendHost.swift:119, :122) | – | Dienst (`cardshare.py`, `testshare.py`) | nein (eigene Varianten je Weg) | Plan 5.3 |
| Lerngruppen | Datensatz `StudyGroup` öffentlich; Mitgliedschaft = Code, bis Build 28 nur in den UserDefaults (CommunityCloudKit.swift:26 ff.) | iCloud-Konto zum Anlegen | `/groups`, `/communities/{key}/join`; Code nur im `localStorage` des Browsers (community-spaces.js:78–83) | nein | iPad↔Mac behoben (3.3); Web: Code je Gerät (5.4) |
| Beitritt Kurs-Community | bis Build 28 UserDefaults (`joinedCourses`, :68); jetzt `CommunitySharedState` | eigener Uni-Abgleich | `/claims` + `/communities/{key}/join` beim Dienst (je Konto) | nein | iPad↔Mac behoben |
| Melden | CloudKit `Report` | iCloud-Konto | `/report`, `/report-post` | nein (Moderation im CloudKit-Dashboard bzw. `/moderation`) | Plan 5.2 |
| Sperren (eigene Sperrliste) | CloudKit `Block` **privat** (:522, :541) – über iCloud auf iPad und Mac gleich | iCloud-Konto | `/solutions/{id}/block`, `/blocks` | nein | iPad↔Mac war schon gleich |
| Sperren durch den Inhaber | CloudKit `Ban` (Dashboard) | – | `bans` im Dienst | nein (zwei Listen) | Plan 5.2 |
| Benachrichtigungen | **keine** (nur Abzeichen = offene Korrekturhinweise, CommunityBadge.swift) | – | `/notifications` (Glocke, views-qa.js:143) | – | Plan 5.4 |
| Lesezeichen | **keine** | – | `/bookmarks` | – | Plan 5.4 |

Bedingung „StudiNow-Konto angemeldet“ ändert an der Community **nichts** (Build 28 und dieser Zweig). Das Konto wirkt
nur bei: Gerätesync G2 (`StudoraAccountLink.syncNow`), Kontingent der Stapel-Übernahme (`/adopt-quota`), StudiNow-KI.

## 3. Mac („Designed for iPad“) gegen iPad

### 3.1 Was gleich ist (geprüft)

| Punkt | Befund | Beleg |
|---|---|---|
| Binärdatei | dieselbe App; kein eigener Mac-Build | project.yml:35–38 (`SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: YES`, `TARGETED_DEVICE_FAMILY: 2`) |
| CloudKit-Container | `iCloud.de.uniflow.ai` in den Berechtigungen und in der Info.plist (`UFCloudKitContainer` aus `UF_CLOUDKIT_CONTAINER` der Team.xcconfig) | UniFlow.entitlements:26–33, project.yml:106, CommunityCloud.swift:126–140 |
| Umgebung | keine `icloud-container-environment` in den Berechtigungen: App Store und TestFlight laufen auf **Production**, ein aus Xcode gestarteter Build (auch „My Mac (Designed for iPad)“) auf **Development**. Ein Mac-Test aus Xcode sieht die Daten des iPads aus dem App Store also **nicht** – kein Fehler der App, aber für Abnahmen wichtig: beide Geräte aus TestFlight/App Store prüfen | UniFlow.entitlements |
| Datensatztypen, Zonen | 14 Typen (cloudkit-schema.ckdb), alle in der Standardzone; öffentlich alles außer `Block` (privat). Keine eigenen Zonen, keine Freigaben | Config/cloudkit-schema.ckdb, CommunityCloud.swift:151–152 |
| Nutzerkennung | `userRecordID` hängt an Apple-ID und Container: iPad und Mac derselben Apple-ID sind derselbe Nutzer („deine“, Zurückziehen, Sperren) | CommunityCloud.swift:161 |
| Container der App | Kennung aus Apple-Nutzer und Hochschule (`DataContainerKey.identifier`), auf beiden Geräten gleich | Packages/…/Containers/DataContainer.swift:36 |
| Community-Schlüssel | aus den Kurstiteln des eigenen Uni-Abgleichs (`CommunityCourses.spaces`); gleicher Stud.IP-Zugang → gleiche Schlüssel und Geheimnisse | CommunityCloudKit.swift (CommunityCourses) |
| Push/Abos | **keine** `CKSubscription`, keine Push-Berechtigung: weder iPad noch Mac bekommen Änderungen zugeschickt. Beide laden beim Öffnen einer Ansicht (`.task`, CommunitySpacePage.swift:210, :552) und frischen das Abzeichen bei `scenePhase == .active` auf (CommunityBadge.swift:112). Auf dem Mac wird `.active`, sobald das Fenster nach vorn kommt – gleichwertig | – |
| Mac-Weichen | nur im Editor (`isiOSAppOnMac`: Maus zeichnet, keine Helligkeit; PDFEditorController.swift:442, EditorFreezeLock.swift:48). **Keine** Weiche in Community, Abgleich, Lerngruppen, Mitteilungen oder Ablagepfaden | `grep isiOSAppOnMac|targetEnvironment(macCatalyst)|userInterfaceIdiom` |
| Schlüsselbund | nicht synchronisiert (je Gerät): StudiNow-Anmeldung und Uni-Zugang gibt es je Gerät neu – gewollt (Passwort nur auf dem Gerät). Die 7-Tage-Probe und das Stapel-Kontingent liegen zusätzlich im iCloud-Schlüssel-Wert-Speicher (LocalTrial.swift:131 ff., AdoptQuota.swift:13) und gelten auf iPad und Mac gemeinsam | – |
| Schlüssel-Wert-Speicher | `com.apple.developer.ubiquity-kvstore-identifier = $(TeamIdentifierPrefix)$(CFBundleIdentifier)`: gleiches Team und gleiche Bundle-ID → **ein** Speicher für iPad und Mac | UniFlow.entitlements:34 |

### 3.2 Befunde (Unterschiede iPad ↔ Mac bei gleicher Apple-ID)

| Nr. | Befund | Wirkung auf dem Mac | Stand |
|---|---|---|---|
| M1 | Beitritte zu Kurs-Communities nur in den UserDefaults (`uniflow.community.joined`) | Kurs zeigt „Beitreten“, Lösungen und Diskussion fehlen („nicht Mitglied“), obwohl auf dem iPad beigetreten | **behoben** |
| M2 | Lerngruppen (Code, Name) nur in den UserDefaults (`uniflow.community.groups`) | Lerngruppen des iPads fehlen ganz; ohne Code keine Entschlüsselung ihrer Lösungen | **behoben** |
| M3 | Pseudonym nur in den UserDefaults (`uniflow.solution.displayName`) | Kommentare, Fragen, Korrekturen und geteilte Stapel vom Mac erscheinen als „Anonym“, vom iPad als „Erika“ | **behoben** |
| M4 | Gesehen/Ignoriert der Korrekturhinweise nur in den UserDefaults | Abzeichen „Community“ zählt auf dem Mac schon gesehene oder ignorierte Hinweise erneut | **behoben** |
| M5 | Sperrliste: Datensätze privat in CloudKit (gleich), der Zwischenspeicher lokal | ohne Netz auf dem Mac die alte Liste | **behoben** (Zwischenspeicher mitgespiegelt) |
| M6 | Gerätename beim StudiNow-Konto `UIDevice.current.name` = „iPad“ auch auf dem Mac; Kennung „ipad-…“ | zwei gleich benannte „iPad“ in der Geräteliste – welches abmelden? (wichtig für die 3-Geräte-Regel in 1.0.1); Diagnose „iPadOS“ auf dem Mac | **behoben**: Name „Mac“, neue Kennungen „mac-…“ (vorhandene bleiben), Diagnose „macOS (App für iPad)“ |
| M7 | Hintergrundabgleich (`BGTaskScheduler`) gibt es für iPad-Apps auf dem Mac nicht; `submit` scheitert still (BackgroundSync.swift:391) | Mac gleicht nur beim Öffnen/Vordergrund ab (wie iPad nach dem Beenden) | kein Fehler, dokumentiert |
| M8 | Vorwärmen des Dokument-Index nur beim Laden (`batteryState`, DocIndexCloudKit.swift:100); ein Mac ohne Akku meldet `.unknown` | Mac wärmt den gemeinsamen Index nicht vor (lädt bei Bedarf) | dokumentiert; Inhalte gleich |
| M9 | Persönliche Daten (Notizen, Lernplan, Karten) ohne StudiNow-Konto nur lokal | iPad und Mac ohne Konto: zwei getrennte Stände | dokumentiert (G2 mit Konto, Notizen ab Pro AI) |
| M10 (K3) | Geräte-eigene Einstellungen im Abgleich: die Liste des Kerns (`DeviceSyncCore.localSettings`, DeviceSync.swift:220 in Build 28) hatte 5 Schlüssel, die Windows-App (app/sync_client.py:41) 10. iPad und Mac (beide Swift) sendeten u. a. `exam_registration_run` (Stand des eigenen QIS-Abrufs; die Tabelle `exam_registrations` gleicht nicht ab) und `studip_bulletin_fetched_at_v2` (Zeitpunkt des eigenen Abrufs des Schwarzen Bretts) | Mac zeigte „N Prüfungen abgerufen“ über einer leeren Liste; der Mac ließ den Abruf des Schwarzen Bretts aus (`StudIPBulletin.fetch`, Drosselung `minHours`), obwohl seine Tabelle leer war; beide Geräte überschrieben sich den Stand gegenseitig | **behoben**: alle 10 Schlüssel der Windows-App plus `studip_bulletin_fetched_at_v2`, `studip_blubber_fetched_at`, `studip_blubber_activity` bleiben auf dem Gerät (Senden und Empfangen, `settingIsLocal`). Test `DeviceSyncLocalSettingsTests` liest die Liste aus app/sync_client.py (rot vor der Behebung: 10 Fehler) |
| M11 | Händigkeit (`uniflow.hand`, AppStorage, DocumentView.swift:161, SettingsPage.swift:649) und Rufname (`Rufname`, UFGreeting.swift:62, „verlässt das Gerät nie“) nur in den UserDefaults | iPad und Mac können verschieden sein | gewollt (Eingabe je Gerät: Stift links/rechts auf dem iPad, Maus auf dem Mac), dokumentiert |

### 3.3 Behebung M1–M6

- Kern: `CommunitySharedState` (Packages/UniFlowCore/Sources/UniFlowCore/Solutions/CommunitySharedState.swift).
  UserDefaults des Containers **und** iCloud-Schlüssel-Wert-Speicher; Schlüssel `cs1.<Container-UUID>.<j|g|b|n|ci|cs>`
  (höchstens 39 Byte, Grenze 64). Lesen: iCloud-Wert gilt und wird lokal übernommen; fehlt er, wird der lokale
  Bestand einmal gespiegelt (das iPad mit Build 28 bringt seine Beitritte und Gruppen beim ersten Start von Build 29
  mit). Leere Listen werden geschrieben, nicht entfernt (ein Austritt kommt nicht aus dem lokalen Stand zurück).
  Kein neuer CloudKit-Typ → **keine Schema-Änderung in Production**.
- `CommunityCorrectionStatusStore(defaults:state:)` (CommunityCorrection.swift) nutzt den Zustand, wenn er da ist.
- App: `ActiveContainer.communityState` (DataContainers.swift:110), `CommunityMembership(defaults:state:)`
  (CommunityCloudKit.swift:26 ff.), `SolutionDisplayName` (SolutionSharing.swift:130–147), `CorrectionStatusRegistry`
  (CommunityCorrectionsCloudKit.swift:185), `StudoraAccountLink.deviceID/deviceName` (:85–98), Diagnose
  (SettingsPage.swift:1359). Unter XCTest ohne iCloud-Speicher (sonst teilten App-Tests einen echten Speicher).
- Grenzen: gleichzeitige Änderung derselben Liste auf beiden Geräten → der spätere Schreiber gewinnt (Regel des
  Speichers); ein Mac, der vor dem ersten iCloud-Abgleich schon lokal beitritt, kann die Liste des iPads einmal
  überschreiben (erneut beitreten genügt). „Daten löschen“ eines Containers lässt die iCloud-Einträge stehen (sie
  liegen im iCloud des Nutzers, nicht beim Dienst); ein neu angelegter Container übernimmt sie.
- Tests: `CommunitySharedStateTests` (9 Fälle, zwei Geräte mit eigenen UserDefaults und einem gemeinsamen Speicher):
  Befund M4 als Ausgangslage, iPad → Mac für M1–M3/M5, Übernahme des Bestands, Austritt auf dem Mac, Trennung je
  Container/Hochschule und Schlüssellänge, Verhalten ohne iCloud, offline weiter lesbar, Abzeichen-Zahl gleich auf
  beiden Geräten, Gerätename.

### 3.4 Abnahme am Gerät (Inhaber, zwei Geräte, gleiche Apple-ID, beide aus TestFlight)

1. iPad: Pseudonym setzen, einer Kurs-Community beitreten, Lerngruppe anlegen. Mac öffnen (App in den Vordergrund):
   Community zeigt den Beitritt, die Lerngruppe und schreibt unter demselben Pseudonym.
2. Korrekturhinweis an eine eigene Lösung schicken lassen, auf dem iPad öffnen → Abzeichen auf dem Mac nach dem
   nächsten Vordergrund ohne diesen Hinweis.
3. Einstellungen → Konto → Geräte: iPad und „Mac“ getrennt.
4. Nicht aus Xcode testen (Development-Umgebung, 3.1).

## 4. Abgleich persönlicher Daten (G2) – Stand

- iPad und Mac senden `changed` seit P73-F6 (a6d25a73, DeviceSync.swift:590–594), der Dienst führt bei Konflikt nur
  diese Felder zusammen (app/sync.py:301–313). Notizen: `version`/`base_version` wie `PUT /api/files/{id}/annotations`
  (sync.py:364–385; das iPad liest `version`, DeviceSync.swift:474), gemeinsame Regeln `fixtures/merge/cases.json`
  (Python `annotation_merge.py`, Browser `merge.js`, Swift `AnnotationMerge`). Gezeichnetes wird sofort gesichert
  (P60-F1, f5a31bf8).
- Abgeglichen: Module, Ordner, Stundenplan-Serien/Ausnahmen, Lernpakete und Aufgaben (Lernplan), Karteikarten und
  Stapel, Einstellungen (darunter `study_plan` = Studienverlauf), Notizen (ab Pro AI). Nicht abgeglichen: Noten
  (jedes Gerät liest sie selbst von der Hochschule), Dateien der Hochschule (jedes Gerät lädt sie selbst).
- Mac und iPad sind für G2 zwei Geräte desselben Kontos (eigene `device_id`); keine Mac-Sonderwege.
- Geräte-eigene Einstellungen: Befund M10 (K3) oben. Geprüft wurde jeder Schlüssel der Windows-Liste:
  `lan_pin`, `university`, `demo_content`, `semester_rule_applied`, `pen_input` (schon lokal);
  `exam_registration_run` (Stand zur nicht abgeglichenen Tabelle, **vom iPad gesendet**); `messages_seen_up_to`,
  `studip_reply_drafts`, `studip_replies`, `studip_submissions` (das iPad hält diese in den UserDefaults bzw. gar nicht;
  kämen sie vom Dienst oder einer Windows-App älteren Stands an, würden sie jetzt nicht mehr übernommen). Zusätzlich
  nur auf iPad/Mac: die Abrufstände von Schwarzem Brett und Blubber (Schlüssel der Swift-Seite; die Windows-App nutzt
  `studip_bulletin_fetched_at` ohne `_v2` und hat denselben Fehler zwischen zwei PCs – Plan 5.6). Bewusst weiter
  abgeglichen: `study_plan`, `exam_dates_auto` (gehört zu den abgeglichenen Modulen), `certificates`,
  `campus_study_service`, `studip_missing_endpoints` (gleiches Konto, gleiche Hochschule).
- Einträge, die ein iPad mit Build 28 schon gesendet hat, liegen weiter im Dienst; Geräte mit diesem Stand übernehmen
  sie nicht mehr (`apply` prüft `settingIsLocal`, DeviceSync.swift:385).
- Bestehende Tests: tests/test_sync.py, tests/test_device_sync_api.py, tests/test_audit_paket_59_77.py,
  fixtures/sync/cases.json (Swift `DeviceSync`-Tests im Kern). In diesem Auftrag keine neuen Web/Windows-Tests
  (Vorrang Mac, Anweisung 09.11.).

## 5. Web/Windows: Lücken und Plan (nicht umgesetzt)

### 5.1 Grundsatzfrage (Entscheidung des Inhabers)

Zwei Communitys: CloudKit (iPad/Mac, auch ohne StudiNow-Konto, iCloud reicht) und Dienst (Web/Windows, Konto ab Plus).
Der Dienst-Weg auf dem iPad wurde am 07.11.2026 abgeschaltet, weil er keine Fragen/Antworten kannte und Pro-AI-Nutzer
(Dienst) und Plus-Nutzer (iCloud) getrennte Communitys sahen (UEBERGABE-2026-11-06.md:11). Solange iPad-Nutzer ohne
StudiNow-Konto mitmachen dürfen, gibt es nur drei Wege zu „überall gleich“:

- **A (empfohlen): Community auf iPad/Mac nur noch über den Dienst**, Konto Pflicht für die Community (Lesen und
  Schreiben). CloudKit bleibt nur für Geräte ohne Konto als Lesezugang zum Altbestand oder entfällt. Ergebnis: eine
  Community für iPad, Mac, Windows, Web. Aufwand: 5.2 + 5.3 + Umstellung und App-Tests ≈ **4–6 Tage**.
- B: Dienst mit Konto, CloudKit ohne Konto (Auftrag Punkt 3): bleibt gespalten zwischen Nutzern mit und ohne Konto –
  genau der Befund vom 07.11. Nicht empfohlen.
- C: Web/Windows lesen und schreiben CloudKit (CloudKit JS / Web Services mit Apple-Anmeldung). Groß, bindet Windows
  an eine Apple-ID; nicht empfohlen.

### 5.2 Dienst-Weg der App vervollständigen (Kern, `ServiceCommunityService`)

Fehlt heute und war der Grund der Abschaltung:

| Teil | Aufrufe beim Dienst | Aufwand |
|---|---|---|
| Fragen & Antworten (`supportsSpaceDiscussion`, `posts`, `addPost`, `setPostLiked`; Bearbeiten/Löschen/Melden über die Kennung, die Art merkt sich der Dienst-Weg aus der Liste) | `GET /courses/{key}/questions?limit=50`, `GET /questions/{id}` (Antworten), `POST /courses/{key}/questions {title, body}` (erste Zeile = Titel ≤ 160, Rest = Text), `POST /questions/{id}/answers {body}`, `POST/DELETE /questions/{id}/like`, `PATCH /questions/{id}`, `PATCH /answers/{id}`, `DELETE …`, `POST /{questions|answers}/{id}/report-post {reason}` | 1 Tag inkl. Kerntests |
| Korrekturen (`supportsCorrections`, senden, Liste je Lösung, Posteingang, Status je Konto, zurücknehmen, melden) | `POST /solutions/{id}/corrections {id, payload}` (Chiffrat wie `CommunityCorrections.seal`, Geheimnis aus `CommunitySpace.secret` der `community_key`), `GET /solutions/{id}/corrections`, `GET /corrections/inbox`, `GET /corrections/{id}`, `POST /corrections/{id}/status`, `DELETE`, `POST …/report`; braucht `SolutionCipher` im Initialisierer | 1 Tag |
| Mitteilungen (Glocke) und Lesezeichen – auf iPad/Mac bisher gar nicht | `/notifications`, `/notifications/read`, `/bookmarks*` | 1–2 Tage mit Oberfläche |
| Sperren durch den Inhaber | eine Liste (Dienst `bans`) statt CloudKit `Ban` | mit A erledigt |

### 5.3 Karteikarten-Stapel, Wochenstapel, Wochentests

`CardStackCommunityProvider` über den Dienst (`ServiceCardStackCommunity`): `POST /api/community/card-stacks
{community_key, name, kind, week, cards}` (Geräte-Weg der Windows-App, community_cards_api.py:288), `GET
/api/community/card-stacks?module=<key>`, `GET …/{id}` (`cards_list`), `POST|DELETE …/{id}/like`, `POST …/{id}/report`,
`DELETE …/{id}`, `POST …/{id}/adopted`. Die Antwortform ist schon dieselbe (`SharedCardStackSummary.json` =
`community_cards._summary`). Die Oberfläche (CardsPage) bleibt unverändert, weil sie den lokalen Router mit denselben
Pfaden ruft. Wochenstapel/Wochentests: Varianten über `cardshare`/`testshare` des Dienstes. Aufwand ≈ 1 Tag.

### 5.4 Lerngruppen über Geräte und Browser

Mitgliedschaft = Kenntnis des Codes; der Code liegt nie beim Dienst. iPad/Mac teilen ihn jetzt über iCloud. Im Web
liegt er im `localStorage` des Browsers (community-spaces.js), in der Windows-App ebenso: ein zweiter Browser kennt die
Gruppe nicht, obwohl der Dienst die Mitgliedschaft des Kontos kennt. Vorschlag: Code verschlüsselt mit einem
Konto-Schlüssel im Dienst ablegen oder beim Beitritt im zweiten Gerät „Code erneut eingeben“ anbieten. Aufwand ½ Tag.

### 5.5 „Aktualisieren“

Weder iPad noch Mac noch Web aktualisieren eine offene Community-Ansicht von selbst (keine Push-Abos, kein Abfragen
im Takt). Vorschlag für alle Geräte gleich: beim Zurückkommen ins Fenster (`scenePhase .active` bzw.
`visibilitychange`) die offene Liste neu laden, höchstens einmal je Minute. Aufwand ½ Tag, App-Oberfläche → mit
App-Tests.

### 5.6 Abgleich: Abrufstände in der Windows-App

`app/sync_client.py` `LOCAL_SETTINGS` sollte `studip_bulletin_fetched_at`, `studip_blubber_fetched_at` und
`studip_blubber_activity` aufnehmen (zwei PCs desselben Kontos), und der Dienst sollte geräte-eigene Schlüssel gar nicht
erst annehmen (`sync.PRIVATE_SETTINGS` erweitern, Altbestand löschen). Aufwand ½ Stunde mit Test; hier nicht umgesetzt
(Vorrang Mac).

## 6. Prüfungen in diesem Zweig

- Python gesamt: **3288 bestanden, 50 übersprungen, 2 xfailed** (wie develop 574a2603; angepasst
  `test_release_gate.py`: die Gerätekennung beginnt jetzt mit `ipad-` bzw. `mac-`).
- Swift-Kern `swift test`: **1397 Tests, 9 übersprungen, 0 Fehler** (neu `CommunitySharedStateTests` 9,
  `DeviceSyncLocalSettingsTests` 3). Nebenbei behoben: `CardStackShareTests.testShareAdoptWithdrawAndNoCrossModule`
  war zufällig rot (Base64 des Chiffrats enthielt „Q1“/„A1“ in rund jedem zehnten Lauf), geprüft wird jetzt der Klartext
  in den Bytes.
- App-Tests auf einem Klon des iPad-Simulators (Export `~/Studora-Builds/export-community-b28`): Community-Auswahl
  (CommunityCloudKitTests, CommunityCorrection*AppTests, DataSeparationAppTests, StudoraAccountAppTests,
  AbnahmeV1AppTests, AuditPaket353740/40x45AppTests, PurchaseAccountLinkP36Tests, InviteAppTests) **103 Tests, 0
  Fehler**; gesamte App-Suite (Stand 0419f11b): **1369 bestanden, 18 übersprungen, 0 Fehler** (`** TEST SUCCEEDED **`); Klon danach gelöscht.
- Auf dem Mac-Ziel laufen die App-Tests im Zweig `paritaet/mac-b28` (andere Sitzung); dieser Zweig baut nicht für macOS.
