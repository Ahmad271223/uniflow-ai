# iPhone-Fassung: Stand 06.11.2026

Zweig `feature/iphone` (Worktree `/Users/ahmadfakih/uniflow-ai-iphone`), Grundlage: develop **Build 10** (`bd6f183`).
Regeln und Aufteilung iPhone/iPad: `docs/IPHONE-2026-11-04.md`. Die iPad-Darstellung ist unverändert; entschieden wird
nach Platz (`horizontalSizeClass`), nicht nach Gerät.

## 1. Was auf dem iPhone fertig ist (im Simulator geprüft)

| Bereich | iPhone-Fassung | Tests |
|---|---|---|
| Rahmen | Tab-Leiste Start, Kalender, Module, Dokumente, Mehr; „Mehr“ mit allen übrigen Bereichen (auch Raumfinder, Uni-Mail, Mensa); Kopfzeile mit **neuem Logo** | IPhoneNavigationTests |
| Zurück-Pfeil | genau einer: Wurzeln der Leiste ohne Pfeil, sonst der Pfeil der Kopfzeile; Ebenen in einer Seite (Uni-Mail) gehen zuerst eine Ebene hoch; in Blättern mit `NavigationStack` das System-Zurück | IPhoneBackArrowTests, BackArrowAppTests |
| Raumfinder | Suchfeld und „Suchen“ in voller Breite, Beispiele als Reihe, Treffer als Karten, Ort als Blatt (halb/ganz) mit „In Google Maps öffnen“ und „Route“ in voller Breite | IPhoneRoomFinderTests |
| Uni-Mail | Ordner → Liste → E-Mail als Ebenen, Knöpfe in voller Breite, „Neue E-Mail“ als ganzes Blatt (kein Wegwischen), Zeile „Lehrende“ (LUH) | IPhoneUniMailTests |
| Termin-Detail (neu) | Termin im Stundenplan/Lernkalender → Blatt von unten **halb/ganz**: „Zum Modul“, Raum (Antippen = Route zu Fuß), „Im Raumfinder anzeigen“, „Allen Lehrenden schreiben“ in voller Breite; E-Mail-Adressen 44 pt hoch; Einzeltermin als Dialog-Blatt | IPhoneTerminDetailTests |
| Lehrende (neu) | Seite mit Suche in voller Breite, Personen als Liste, „Nachricht in Stud.IP“ in voller Breite; Bereich auf der Modulseite | IPhoneLecturersTests |
| Bescheinigungen (neu) | Liste nach Art, „Öffnen“/„Neu laden“ nebeneinander bzw. „Herunterladen“ in voller Breite, Semester breit, „Liste aktualisieren“ unter dem Kopf; Vorschau als ganzes Blatt mit „Teilen oder sichern“; Karte unter Uni & Noten mit breitem Knopf | IPhoneCertificatesTests |
| Automatisch anmelden (neu) | Schalter „Passwort auf diesem iPhone merken“ unter jeder Anmeldeseite (erster Start und Blätter), bricht um, auch bei sehr großer Schrift; Karte in den Einstellungen mit „Gespeichertes Passwort löschen“ in voller Breite | IPhoneAutoLoginTests |
| Dialoge | auf dem iPhone Blätter von unten mit Scrollen (develop: Dialoge scrollen auch mittig am iPad) | Breiten-Audit |
| Texte | Gerätename statt „iPad“ in den neuen Texten (`UFDevice.name`) | LecturersAppTests, UniAutoLoginAppTests |
| Ältere Bereiche | Dokument/Editor, KI-Hilfe, Karteikarten, Tests, Bibliothek, Community, Mensa, Studienverlauf, Prüfungsanmeldung, Antworten, Store-Bilder | IPhone*Tests, LayoutWidthAuditTests (390, 402, 440 hoch und quer) |

Breiten-Audit (`LayoutWidthAuditTests.testIPhone*`): alle Seiten auf iPhone 17e (390), 17 (402), 17 Pro Max (440) hoch und
quer ohne Überbreite, neu `testIPhoneBuild10` (Lehrende, Bescheinigungen, Uni & Noten, Termin-Detail).

### Testlauf auf dem iPhone-Simulator

Die ganze Suite `UniFlowTests` läuft jetzt auch auf einem iPhone-Simulator. Dafür hat das Testbundle eine Hauptklasse
(`UniFlowTests/TestBundlePrincipal.swift`, `INFOPLIST_KEY_NSPrincipalClass` in `project.yml`): Testfenster ab 700 pt Breite
bekommen vor dem ersten Zeichnen die Größenklassen des iPads (die Tests in iPad-Größe erwarten die breite Fassung;
`makeKeyAndVisible` wird dafür im Testbundle ausgetauscht), und Stift-Fragen gelten wie am iPad. Die iPhone-Tests setzen
compact weiter selbst. Auf dem iPad-Simulator wirkt nichts davon.

Stand 06.11.2026 (Commit „iPhone: develop Build 10 gemergt …“): `UniFlowTests` auf dem iPhone-Simulator (iPhone 17,
iOS 27.2) 1289 Tests, 19 übersprungen, alle grün; auf dem iPad-Simulator 1289, 19 übersprungen, alle grün; pytest 1734
(50 übersprungen), `node --test tests/js/` 430, `swift test` (UniFlowCore) 1245 (9 übersprungen). Hinweis: ein voller
Lauf auf dem iPhone-Simulator braucht etwa 25 Minuten; einmal hing `PurchaseTests.testAskToBuyIsPendingUntilApproved`
(StoreKit-Testsitzung), im nächsten Lauf lief er in 0,2 s durch. Für lange Läufe
`-test-timeouts-enabled YES -default-test-execution-time-allowance 180` mitgeben.

## 2. Was ein Test am echten iPhone braucht (Simulator reicht nicht)

1. **Schreiben mit dem Finger** im Dokument (Modus „Zeichnen“, zwei Finger scrollen), Palette kompakt, „Bereich an KI“
   mit dem Finger, Fixieren/Abpausen (Helligkeit).
2. **Bildschirmtastatur**: Antwortfenster (Stud.IP, Prüfungsanmeldung), Neue E-Mail, Suche – „Senden“ steigt mit der
   Tastatur, nichts verdeckt.
3. **Automatisch anmelden**: Schlüsselbund ThisDeviceOnly auf dem iPhone, Mitlesen/Einsetzen auf den echten
   Anmeldeseiten (LUH, HsH, Hildesheim), Löschen beim Abmelden; iOS-AutoFill daneben.
4. **Google-Maps-Route** aus Termin-Detail und Raumfinder (App installiert / nicht installiert).
5. **Bescheinigungen**: echte PDF, Vorschau, „Teilen oder sichern“ → Dateien, AirDrop.
6. **Uni-Mail** senden/antworten vom iPhone (LUH, Hildesheim), Mitteilungen bei neuen Mails.
7. Querformat und Dynamic Type bis accessibility3 auf einem kleinen Gerät (iPhone 17e / SE-Größe).
8. Hintergrund-Abgleich (BGTaskScheduler), Mitteilungen, Aufnahme einer Vorlesung (Mikrofon, gesperrter Bildschirm).
9. Käufe (Plus) in der Sandbox auf dem iPhone: dieselben Abos wie am iPad (gleiche Bundle-ID).

## 3. Universal-Build bauen (iPhone + iPad)

**Auf develop bleibt `TARGETED_DEVICE_FAMILY: "2"` (nur iPad), bis der Inhaber die iPhone-Fassung freigibt.** Nichts davon
ist auf develop geändert. Schritte, wenn es so weit ist:

1. `feature/iphone` nach develop mergen (oder develop in `feature/iphone` mergen und von dort bauen). Auf `feature/iphone`
   steht schon `TARGETED_DEVICE_FAMILY: "1,2"` und `UISupportedInterfaceOrientations~iphone` (hoch, quer links/rechts) in
   `apps/apple/project.yml`. Beim Merge nach develop diese Zeile bewusst übernehmen.
2. `CURRENT_PROJECT_VERSION` in `apps/apple/project.yml` hochzählen (nächste freie Build-Nummer nach dem letzten Upload,
   heute 10 → 11); `MARKETING_VERSION` für ein Update z. B. „1.1“.
3. Sauberer Export: `git archive HEAD | tar -x -C ~/Studora-Builds/export-<build>`; `apps/apple/Config/Team.xcconfig` aus
   dem Arbeitsordner hineinkopieren (gitignored); dort `cd apps/apple && xcodegen generate`.
4. Tests vorher: pytest, `node --test tests/js/`, `swift test` (UniFlowCore) und `UniFlowTests` auf **einem iPad- und
   einem iPhone-Simulator** (Simulator-Vorlagen klonen, danach löschen; `export DEVELOPER_DIR=…` im selben Befehl).
5. Archiv: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && xcodebuild archive -project UniFlow.xcodeproj
   -scheme UniFlow -configuration Release -destination 'generic/platform=iOS' -archivePath ~/Studora-Builds/StudiNow-<build>.xcarchive`
   (nie `CODE_SIGNING_ALLOWED=NO`). Prüfen: `plutil -p …/Info.plist | grep -E "UIDeviceFamily|CFBundleVersion"` zeigt
   `UIDeviceFamily => [1, 2]`.
6. Upload über Xcode → Organizer → Distribute App → App Store Connect (per `xcodebuild -exportArchive` scheitert es mit
   „Failed to Use Accounts“).
7. App Store Connect: iPhone-Bildschirmfotos 6,9" (`~/Studora-Builds/appstore-screenshots-iphone/`,
   `IPhoneStoreScreenshotTests`, siehe `docs/release/SCREENSHOTS.md`) hochladen; Beschreibung um das iPhone ergänzen;
   „Designed for iPad“ auf dem Mac bleibt.

## 4. Offen

- Lineal nur auf einer Seite der geteilten Ansicht: am iPad offen (siehe `docs/UEBERGABE-2026-11-06.md`), auf dem iPhone
  gibt es keine geteilte Ansicht.
- HsH-Mail, Lehrende und Raumfinder für HsH und Hildesheim: wie am iPad noch nicht da.
- Echte-Geräte-Abnahme (Abschnitt 2) durch den Inhaber.
