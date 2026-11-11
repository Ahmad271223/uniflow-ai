# iPhone-Fassung: Stand 11.11.2026

Zweig `iphone/universal` (Arbeitsordner `~/Studora-Builds/wt-iphone`), aufgebaut auf `develop` `baddff02` (Build 32).
Der alte Zweig `feature/iphone` (Stand 06.11.2026) ist hineingeführt; seine Teile für das Schreiben am iPhone sind
bewusst **nicht** übernommen. Nichts gepusht, nichts hochgeladen, `develop` unverändert.

Vorgabe des Inhabers (11.11.2026): alles wie am iPad, **außer dem Editor**, aber **mit KI**. Regeln und Aufteilung:
`docs/IPHONE-2026-11-04.md`. Ersetzt `docs/IPHONE-STAND-2026-11-06.md`.

## 1. Was am iPhone geht

| Bereich | Am iPhone |
| --- | --- |
| Rahmen | Untere Leiste Start · Kalender · Module · Dokumente · Mehr; „Mehr“ mit allen übrigen Bereichen (Nachrichten, Uni-Mail, Stundenplan, Studienverlauf, Tests & Wiederholung / Karteikarten, Uni & Noten, Mensa, Raumfinder, Community) und Einstellungen. Kopfzeile mit Logo, Suche, **Sync** (ein Tipp gleicht Stud.IP, QIS und Uni-Mail ab), Profil. Hochformat, quer erlaubt; Dynamic Type geprüft bis accessibility3 |
| Übersicht, Lernkalender, Stundenplan | wie am iPad, einspaltig; Stundenplan mit den Fragen zum Stud.IP-Kalender; Termin-Detail als Blatt von unten |
| Module, Studienverlauf | Module je Semester; Studienverlauf als Semesterliste, Verschieben über Blatt; Prüfungsanmeldung einspaltig mit „Im QIS zur Prüfung anmelden“ in voller Breite |
| Dokumente & Notizen | Bibliothek als Liste; **Leseansicht statt Editor** (Abschnitt 2); Word/PowerPoint/Audio als Text mit KI-Hilfe; ZIP-Ordner ansehen |
| Uni & Noten | Notenspiegel (QIS), Bescheinigungen (Vorschau, Teilen), Prüfungsanmeldung |
| Nachrichten, Uni-Mail | Stud.IP-Nachrichten mit Antworten (Blatt, „Senden“ über der Tastatur); Uni-Mail Ordner → Liste → E-Mail als Ebenen, „Neue E-Mail“ als ganzes Blatt, Lehrende |
| Mensa, Raumfinder | wie am iPad, iPhone-gerecht (Filter als Blatt, Treffer als Karten, Route) |
| Community | lesen, beitreten, Fragen und Antworten (Eingabe unten), Lösungen anderer **lesen**; veröffentlichen und Korrekturen nur in der iPad-App (Hinweis in der App) |
| KI | Nur über die **StudiNow-KI** (Pro AI): „Eigenes ChatGPT“ ist seit 11.11.2026 überall aus (Abschnitt 2a). KI-Hilfe zu Dokumenten (Blatt von unten, Umfang „Diese Seite / Ganzes Dokument / Seiten …“, markierter PDF-Text geht mit), KI-Start, KI-Lernplan, KI-Karteikarten, Wochentests. Gleiche Tarifregeln (Plus / Pro AI) und dieselbe KI-Einwilligung vor der ersten Anfrage wie am iPad (ein Code für beide) |
| Einstellungen | „Uni-Zugang“ (einmal speichern, „Benutzername und Passwort sind überall gleich“ oder je Portal), Knöpfe am iPhone in voller Breite; Tarif/Abos, StudiNow-Konto, Darstellung, Abgleich im Hintergrund. **Keine** Zeilen „Stift & Touch“ und „Schreibhand“ |
| Texte | „dieses iPhone“ statt „dieses iPad“, wo das Gerät gemeint ist (`UFDevice.adapt`); Stellen über das Schreiben sagen „in der iPad-App“ |
| Konto | Gerät meldet sich beim StudiNow-Konto als iPhone (`iphone-…`, „iOS …“ in der Diagnose) statt als iPad |

## 2. Kein Editor am iPhone

`UFEditorAvailability` (in `Views/Library/PhoneDocumentReader.swift`) entscheidet nach **Gerät**: iPhone = nur lesen;
das iPad (auch im schmalen Split View) und der Mac behalten den Editor unverändert.

- **Leseansicht** `PhoneDocumentReader`: PDF bzw. Notizbuch mit den Notizen aus dem Notizmodell (Handschrift, Text,
  Formen, Bilder – dieselbe Darstellung wie im Editor), Zoomen mit zwei Fingern, Blättern, Text markieren und kopieren,
  **Suchen** in PDF und Notizen (dieselbe Suche wie am iPad), „Seite x von y“ antippen = Seite wählen, „Erledigt“ für
  Aufgaben aus dem Lernplan, **KI-Hilfe** als Blatt. Hinweis oben: „Schreiben auf Dokumenten geht in der iPad-App …“
  (wegtippbar).
- Die Leseansicht **schreibt nichts**: keine Eingabe auf der Zeichenfläche, beim Schließen kein Abgleich und kein
  Versionseintrag (`closeAfterReading`); geprüft, dass keine Anfrage an die Notizen geht.
- Ausgeblendet am iPhone: Stift-/Werkzeugleiste, Lasso, Schreiblupe, Fixieren/Abpausen, „Übung und Skript
  nebeneinander“, Präsentieren, Seiten einfügen/drehen, „Notizbuch“/„Whiteboard“ anlegen, „Korrektur vorschlagen“,
  Korrekturen über den eigenen Notizen, „Lösung teilen“, „In Stud.IP abgeben“, Bearbeiten von Textdateien im ZIP,
  Stift-Einstellungen.
- **Notizen vom iPad** kommen über den Notizen-Abgleich des StudiNow-Kontos aufs iPhone (Tarif Pro AI, „Notizen auf
  allen deinen Geräten“). Mit Plus bleiben Notizen je Gerät; dann zeigt das iPhone die PDF ohne die iPad-Notizen.

## 2a. „Eigenes ChatGPT“ überall entfernt (Vorgabe 11.11.2026)

Auf Wunsch des Inhabers („dein ChatGPT erstmal überall entfernen“) auf **iPhone, iPad und Mac**: zentraler Schalter
`OpenAIKeyLink.isOffered = false`. Keine Karte „Eigenes ChatGPT“ unter Einstellungen → Erweitert, keine Zeile
„Eigenes ChatGPT verbinden“ auf der Free-Karte, keine Hinweise auf den eigenen OpenAI-Schlüssel (KI-Hilfe, KI-Start,
Tests, Lernplan-Vorschlag), kein „über dein ChatGPT“ in Kostenzeilen. Ein früher eingetragener Schlüssel bleibt im
Schlüsselbund, wird aber nicht benutzt; „Konto löschen“ entfernt ihn weiter. Die KI kommt nur noch über die StudiNow-KI
(Pro AI). Wieder einschalten: Schalter auf `true` (die Tests der Funktion laufen weiter mit eingeschaltetem Schalter).
Dies ist die **einzige gewollte Änderung am iPad** in diesem Zweig. Unverändert: der Pro-AI-Satz „kein eigenes
ChatGPT-Konto nötig“ (steht so im gemeinsamen Tarif-Vertrag mit Web und Server).

## 3. iPad unverändert

Vorgabe des Inhabers (11.11.2026): an der iPad-Fassung ändert sich nichts – einzige gewollte Ausnahme ist das
Entfernen von „Eigenes ChatGPT“ (Abschnitt 2a). Umgesetzt so:
- Die iPhone-Fassung hängt am **Gerät** (`UFCompact.phoneLayouts`, `UFEditorAvailability`): ein iPad – auch schmal
  im geteilten Bildschirm oder in einem Blatt – und der Mac zeigen alles wie in Build 32.
- Eine Durchsicht des ganzen Unterschieds zu `develop` fand Stellen aus dem alten Zweig, die das iPad ohne
  iPhone-Bedingung geändert hätten; alle zurückgenommen bzw. aufs iPhone beschränkt: Platzhalter im Raumfinder
  (Hildesheim), Schrift der unteren Leiste im iPad-Hochformat, Tastatur in „Antworten“, Uni-Mail und Community,
  Uni-Mail beim Abmelden, Text „Nur für iPads“ (Einladung), Wochenansicht im schmalen Fenster, Spalte der
  Dokumentliste im geteilten Bildschirm, „Meine geteilten Lösungen“ (Knöpfe und Rückfrage in Blättern), Texte, die am
  Mac neu „Mac“ statt „iPad“ gesagt hätten.
- Übrig sind nur Änderungen ohne sichtbare Wirkung (z. B. Kennungen für Bedienungshilfen, gleichwertig umgebaute
  Ansichten).
- Geprüft mit der kompletten iPad-Testsuite und einem Bildvergleich vorher/nachher (Abschnitt 7).

## 4. Tests

| Lauf | Ergebnis |
| --- | --- |
| iPhone-Simulator (iPhone 17, iOS 27.2): alle `IPhone*Tests` + `LayoutWidthAuditTests` | siehe Abschnitt 6 |
| iPad-Simulator (iPad Pro 11 M5): komplette `UniFlowTests` | siehe Abschnitt 6 |

Neu: `IPhoneReaderTests` (Notizen vom iPad sichtbar, keine Eingabe, keine Schreib-Anfrage, Seite wählen, Suche,
„Erledigt“, drei iPhone-Größen und sehr große Schrift, keine Notizbücher im „Neu“-Dialog, Texte, Gerätename),
`LayoutWidthAuditTests.testIPhoneDokument` / `testIPhoneDokumentOhneEditor` / `testIPhoneEinstellungenUniZugangOhneStift`.
Entfernt: `IPhoneDocumentLayoutTests` (prüfte das Schreiben am iPhone). Angepasst an develop: Uni-Zugang-Karte,
eingeklappte Lehrende im Modul, Beschriftung „Im QIS zur Prüfung anmelden“.

Gefunden durch den iPad-Lauf: Dialoge und Knöpfe in **Blättern am iPad** zeigten wegen des alten Zweigs die
iPhone-Fassung („Meine geteilten Lösungen“: Menü statt Knöpfe, Rückfrage „Zurückziehen“ als zweites Blatt) – behoben
(Abschnitt 3).

## 5. Nur am echten iPhone prüfbar

1. Leseansicht: Zoomen/Blättern großer PDFs (500 Seiten) mit vielen Notizen, Speicher; Text markieren → KI-Hilfe.
2. Notizen-Abgleich iPad → iPhone mit echtem StudiNow-Konto (Pro AI): erscheinen neue Striche ohne neues Öffnen?
3. Bildschirmtastatur: Uni-Zugang, Antworten, Neue E-Mail, Suche – nichts verdeckt.
4. Uni-Zugang: Schlüsselbund „nur dieses Gerät“ auf dem iPhone, stille Anmeldung bei Stud.IP, QIS, Uni-Mail (LUH),
   „Sync“ gleicht alle drei ab; abgelehntes Passwort wird nicht erneut gesendet.
5. Käufe (Plus, Pro AI) in der Sandbox auf dem iPhone; „Käufe wiederherstellen“; Probe einmal je Gerät.
6. Mit Apple anmelden (StudiNow-Konto) auf dem iPhone; Geräteliste zeigt „iPhone“.
7. Google-Maps-Route (Raumfinder, Termin-Detail), Bescheinigung teilen/sichern, Mitteilungen (Uni-Mail, Fristen),
   Hintergrund-Abgleich, Vorlesungsaufnahme mit gesperrtem Bildschirm.
8. Kleine Geräte (iPhone 17e / SE-Größe) quer und mit sehr großer Schrift; Dunkelmodus.

## 6. Store, Datenschutz, Bildschirmfotos (nur Liste, nichts eingetragen)

**App Store Connect**
- Plattform bleibt die iOS-App (App-ID 6830632088); mit dem Build aus diesem Zweig wird sie Universal
  (`TARGETED_DEVICE_FAMILY` „1,2“). Vor dem Hochladen: Build-Nummer hochzählen, `MARKETING_VERSION` z. B. 1.1.
- **iPhone-Bildschirmfotos 6,9"** (1320 × 2868) sind Pflicht: `IPhoneStoreScreenshotTests` (8 Motive, Abschnitt
  „iPhone“ in `docs/release/SCREENSHOTS.md`; Bild 2 zeigt jetzt die Leseansicht mit iPad-Notizen und KI-Hilfe, Bild 7
  „Stundenplan“ statt „In Stud.IP abgeben“).
- **Untertitel/Werbetext** (`APP-STORE.md` Zeile „…auf dem iPad – mit Apple Pencil…“): auf „iPhone und iPad“
  umstellen, Apple Pencil als iPad-Funktion nennen.
- **Beschreibung**: „– auf dem iPad“ → „– auf iPhone und iPad“; ein Satz „Auf dem iPhone liest du deine Unterlagen
  und Notizen vom iPad, mit KI-Hilfe; geschrieben wird mit dem Apple Pencil auf dem iPad.“; Tarife: „Plus … das
  Schreiben mit dem Apple Pencil (iPad)“.
- „einmal je iPad“ (Probe) → „einmal je Gerät“; „Passwort auf diesem iPad merken“ / „Schlüsselbund dieses iPads“ →
  „dieses Geräts“ (die App sagt am iPhone „dieses iPhone“).
- **Prüfhinweise (Englisch)**: iPhone ergänzen – „On iPhone documents open read-only (no Apple Pencil editor); AI help,
  study plan, flashcards and weekly tests work as on iPad.“; „once per iPad“ → „once per device“.
- **Was ist neu**: iPhone-Fassung nennen.
- **App-Datenschutz**: Datenarten ändern sich nicht. Geräte-ID-Text: Kennung jetzt `ipad-…`, `iphone-…` oder `mac-…`.
- Preise/Abos: unverändert (gleiche Bundle-ID, gleiche Abos).

**„Eigenes ChatGPT“ entfernt (gilt für iPad und iPhone):**
- `APP-STORE.md`: Beschreibung „oder in jedem Tarif deinen eigenen API-Schlüssel (Einstellungen → Erweitert)“
  streichen; Prüfhinweise (Englisch): Absatz „Own OpenAI key (Einstellungen → Erweitert → Eigenes ChatGPT …)“ streichen;
  Tarif-Angaben ohne „Eigenes ChatGPT verbinden“.
- `DATENSCHUTZ.md`: Abschnitt „Eigenes ChatGPT mit deinem OpenAI-Schlüssel“ (8a) und die Hinweise darauf (u. a.
  Abschnitt 2 „Du verbindest dein eigenes ChatGPT“) als „derzeit nicht angeboten“ kennzeichnen oder streichen.
- App-Datenschutz in App Store Connect: die Angaben zur Weitergabe an OpenAI über den eigenen Schlüssel entfallen;
  die Weitergabe über die StudiNow-KI bleibt.

**Datenschutz** (`docs/release/DATENSCHUTZ.md`, `site/datenschutz.html` – Upload nur durch den Inhaber)
- Geltungsbereich „StudiNow-Apps (iPad und Mac, …)“ → „iPhone, iPad und Mac, …“.
- „iPad-App“ an rund 35 Stellen → „App für iPhone und iPad“ (Uni-Zugang/Schlüsselbund, Uni-Mail, Konto, eigenes
  ChatGPT, CloudKit-Community, Konto löschen). Inhaltlich gilt alles gleich; neu nur: auf dem iPhone werden Notizen
  nicht bearbeitet.
- `PrivacyInfo.xcprivacy`: Kommentar zur Geräte-ID um `iphone-<UUID>` ergänzen (Datenart unverändert).

**Website** (`site/index.html`, `support.html`): „für das iPad“ → „für iPhone und iPad“, Bildschirmfotos.

## 7. Testergebnisse dieses Stands

| Lauf | Ergebnis |
| --- | --- |
| iPhone-Simulator (iPhone 17, iOS 27.2): alle `IPhone*Tests` (19 Klassen) + `LayoutWidthAuditTests` + `IPhoneStoreScreenshotTests` + `OwnChatGPTOffTests` | **115 Tests**, grün nach einer Testkorrektur (Termin-Detail im schmalen iPad-Split-View lässt sich auf einem iPhone-Simulator nicht nachstellen; einzeln nachgeprüft) |
| iPad-Simulator (iPad Pro 11 M5): komplette `UniFlowTests`, nach dem Entfernen von „Eigenes ChatGPT“ | **1.555 Tests, 1 rot** (`KIAbnahmeLUHAppTests.test3ProAIUeberDenDienst`, auch auf develop rot); davor ohne die ChatGPT-Änderung 1.553 Tests, 0 Fehler |
| UniFlowCore (`swift test --filter CommunitySharedStateTests`, Geräte-Kennung) | 9 Tests, 0 Fehler |
| Bildvergleich iPad vorher (`develop`) / nachher, je einzeln aufgenommen | Store-Bilder 32 von 40 pixelgleich, Layout-Bilder 271 von 312; **alle Abweichungen erklärt**: Uhrzeiten („Stand 11:41“, „QIS: 11:37 ok“), die Jetzt-Linie im Lernkalender, Ladezustand der Community ohne iCloud-Konto im Simulator. Keine Abweichung durch diese Arbeit |

Schon auf `develop` rot (nicht durch diese Arbeit, auf dem unveränderten Stand nachgeprüft):
`KIAbnahmeLUHAppTests.test3ProAIUeberDenDienst` (scheitert einzeln, im Gesamtlauf zuletzt grün) und
`LayoutWidthAuditTests.testGemeinsamUndEinstellungen` (Community lädt im Simulator ohne iCloud-Konto nicht).

Bildschirmfotos: iPhone-Prüfbilder (hell/dunkel, 186) in `~/Studora-Builds/iphone-bildschirmfotos-2026-11-11/`,
App-Store-Bilder 6,9" (1320 × 2868, 8 Motive hell/dunkel) in `~/Studora-Builds/appstore-screenshots-iphone-2026-11-11/`;
iPad vorher/nachher in `~/Studora-Builds/ipad-vorher/` und `~/Studora-Builds/ipad-nachher3/`.
