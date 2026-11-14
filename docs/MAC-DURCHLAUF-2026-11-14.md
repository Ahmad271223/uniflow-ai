# Mac-Durchlauf 14.11.2026 – Prüfung der Mac-Version („Designed for iPad“)

**Frage:** Der Mac-Testlauf vom Vormittag (Stand Build 39, `5d6b6a45`) wurde nach etwa der Hälfte abgebrochen und zeigte
39 Fehler und 3 Abstürze. Sind das echte Fehler der App am Mac oder liegt es am Testaufbau? Kann der Inhaber in App
Store Connect „Kompatibilität mit Apple Silicon Macs bestätigen“ drücken?

Die Mac-Version ist die iPad-App auf Macs mit Apple-Chip, es gibt kein eigenes macOS-Ziel.

Zweig `fix/mac-durchlauf` (von `develop` `aefee598`, zuletzt mit `develop` `1c2fd03a` zusammengeführt = Stand von
Build 41 plus Doku). Nichts in App Store Connect geändert, nichts hochgeladen, nicht gepusht, nicht in `develop`
gemischt, keine echten Logins.

## Kurzantwort

- **Ein echter Mac-Fehler gefunden und behoben: Absturz beim Öffnen von Blättern.** Am Mac baut SwiftUI den Inhalt
  eines Blatts (Sheet, Vollbild-Blatt, Popover) einmal zu früh auf, bevor die Daten der App (Sitzung, Abgleich, …)
  im Blatt angekommen sind. Liest der Inhalt sie sofort, stürzt die App ab. Im Lauf vom Vormittag passierte das
  dreimal: „Wochentest erstellen“ (KI-Start und Seite „Tests“) und „Frag die KI zu Aufgabe …“, jeweils im schmalen
  Fenster. Diese Blätter gibt es seit der iPhone-Fassung, also **ab Build 39 (Version 1.0.4)**. Die Absicherung steht
  jetzt an allen 103 Stellen, an denen die App ein Blatt öffnet. Am iPad und iPhone ändert sich nichts.
- **Cookies und Anmeldungen (Stud.IP, QIS, LSF) arbeiten am Mac richtig.** Die Fehler „Cookies der Webansicht“ und
  „Anmeldung bei QIS/LSF abgelaufen“ kamen aus dem langen Testlauf selbst, nicht aus der App. Einzeln sind alle
  betroffenen Klassen am Mac grün, die Daten verschiedener Konten und Hochschulen bleiben getrennt.
- **Alle übrigen Fehler sind Testaufbau** (Test-Kaufumgebung von Apple, Mac-eigene Fenster und Dialoge,
  iPhone-Prüfungen mit Bildschirmtastatur, Gerätetexte „Mac“ statt „iPad“). Sie sind jetzt je Test als „am Mac
  übersprungen“ gekennzeichnet, mit Begründung, oder der Test kennt den Mac.
- **iPad und iPhone unverändert:** ganze iPad-Suite 1772 Tests, iPhone-Tests 128, Swift-Kern 1531, alle ohne Fehler
  (Abschnitt 9). Der Inhaber hat am 14.11.2026 entschieden, 1.0.4 erst mit dieser Reparatur einzureichen. Build 41
  enthält sie und ist seit 14.11.2026, 19:56 Uhr bei Apple zur Prüfung eingereicht.
- **Ganze Suite am Mac auf dem Stand von Build 41 gelaufen (abends):** 1794 Tests, **kein Absturz**, 16 rote Tests.
  Keiner davon ist ein Fehler der App: Mac-Texte, die der Test nicht kannte, Dinge, die es am Mac bewusst nicht gibt,
  das dunkle Erscheinungsbild des Mac am Abend und der echte Datenordner der App auf diesem Mac (Abschnitt 6).
- **Neu gefunden, kein App-Fehler, aber wichtig für künftige Mac-Läufe:** Am Mac laufen die Tests im echten
  Datenordner der App, in der der Inhaber angemeldet ist. Ein Test sah dadurch die echte Stud.IP-Sitzung (nur gelesen,
  nichts gesendet), und Tests haben 7 Test-Gespräche in die KI-Ablage der Mac-App geschrieben (Abschnitt 6.3).
- **Empfehlung:** Aus Sicht der Tests spricht nichts mehr gegen „Kompatibilität bestätigen“. Drücken aber erst, wenn
  zwei Dinge erfüllt sind: 1.0.4 (Build 41) ist von Apple freigegeben, und die Handprüfung aus Abschnitt 7 ist am Mac
  mit Build 41 ohne Befund gemacht. Begründung in Abschnitt 8.

## 1. Umgebung

| | |
|---|---|
| Mac | MacBook Pro des Inhabers, Apple M5 Pro, macOS 26.6 (25G72), Xcode 27.2 |
| Ziel am Mac | `platform=macOS,arch=arm64,variant=Designed for iPad`, mit `DEVELOPMENT_TEAM=78MQGF36BD` |
| Lauf vom Vormittag | Stand Build 39 (`5d6b6a45`), `~/Studora-Builds/mac-test-b39-2026-11-14.log`: bis zum Abbruch 857 bestanden, 39 Fehler, 20 übersprungen, 3 Abstürze |
| Dieser Zweig | `fix/mac-durchlauf` von `develop` `aefee598` (Stand Build 40); abends mit `develop` `b4ac2ca9` und `1c2fd03a` zusammengeführt (Stand Build 41) |
| Protokolle | `~/Studora-Builds/mac-durchlauf/` (je Lauf eine Datei; ganzer Lauf am Abend: `b42-1.log` bis `b42-20.log`, Zusammenfassung `b42-summe.txt`; Nachläufe `neu-1`, `neu-2`, `nach-1`) |
| iPad-Gegenlauf | Simulator-Klon „iPad Mac-Durchlauf“ von `4495AA80-…` |

Am Mac wurde klassenweise bzw. in Paketen von 12 Klassen getestet, nie die ganze Suite am Stück.

## 2. Die Fehlergruppen vom Vormittag mit Urteil

| Gruppe | Tests | Urteil | Was daraus wurde |
|---|---|---|---|
| **Abstürze** „No ObservableObject of type Session found“ | `IPhoneLearnAITests` (1), `IPhoneLearnExamsTests` (2) | **echter Mac-Fehler** | behoben, Abschnitt 3 |
| „Cookies der Webansicht“: erwartet `["sso-HI"]`, bekommen `[]` | `DataSeparationAppTests` (3) | Testaufbau (langer Lauf) | einzeln 15 von 15 grün, Abschnitt 4 |
| „Anmeldung bei QIS abgelaufen“ | `CertificatesAppTests` (4), `ExamRegistrationAppTests` (1) | Testaufbau (langer Lauf) | einzeln grün, Abschnitt 4 |
| „Anmeldung bei LSF abgelaufen“ | `HildesheimAppTests` (3), `HildesheimParityAppTests` (2), `AuditRunde11AppTests` (1) | Testaufbau (langer Lauf) | einzeln grün, Abschnitt 4 |
| Texte fehlen auf Stationen („nur 1 Texte“, „PDF im Editor“, „erscheint nicht“) | `AbnahmeTarifeAppTests` (3), `AbnahmeV1LUHReleaseAppTests` (3) | Testaufbau | `AbnahmeTarife` einzeln 9 von 9 grün. `AbnahmeV1LUHRelease`: zwei Stationen kennen jetzt den Mac (Rundgang hat dort 5 statt 6 Texte; die Rückfrage „Von Stud.IP abmelden?“ zeichnet der Mac als eigenes Fenster, die Knöpfe stehen nicht im Baum der App) |
| Tarif bleibt „free“ statt „plus“ | `AboNurJahrAppTests` (1) | Testaufbau (Test-Kaufumgebung von Apple) | am Mac übersprungen, Abschnitt 5 |
| „1 zu breit“ in Blättern | 11 iPhone-Tests (`IPhoneCertificates`, `IPhoneExamRegistration`, `IPhoneLearnCards`, `IPhoneLearnLibrary`, `IPhoneMensa`, `IPhoneMessageReply`, `IPhoneRoomFinder`, `IPhoneTerminDetail`, `IPhoneUniMail`) | Testaufbau | der Mac zeichnet um jedes Blatt einen Schattenrand (`UIDropShadowRimPartView`), 54 pt breiter als das Fenster; die Breitenprüfung nimmt ihn jetzt wie die anderen Systemrahmen aus |
| Gerätetexte | `IPhoneNavigationTests` („Mac“ statt „iPad“), `IPhoneReaderTests` („Schreiben mit Maus oder Trackpad“) | Testaufbau | die Tests kennen jetzt die Mac-Texte (die App macht es richtig) |
| Bildschirmtastatur | `IPhoneMessageReplyTests.testComposerKeepsSendReachable` | Testaufbau | der Teil mit der Bildschirmtastatur ist am Mac übersprungen (dort gibt es keine) |
| Liste im Blatt | `IPhoneMensaTests` („Allergene meiden“ fehlt) | Testaufbau | im halbhohen Blatt steht der unterste Abschnitt am Mac nicht im Baum, die Abschnitte darüber schon (vermutlich baut die Liste ihn erst beim Rollen auf); die eine Prüfung gilt am Mac nicht |
| Fokus nach dem Chat | `EditorPaletteReturnAppTests` (1) | Testaufbau | am Mac holt der Editor den Fokus bewusst nicht zurück (`reclaimFocusForWriting`: „Am Mac nichts erzwingen“); am Mac übersprungen |
| Korrekturhinweis in der Community | `CommunityCorrectionWiringAppTests` (1) | Testaufbau (schwankt) | Abschnitt 5 |
| Verweis „Deine Notizen dazu …“ | `AIViewsAppTests` (1) | Testaufbau, **von Hand prüfen** | Abschnitt 5 und 7 |

## 3. Echter Mac-Fehler: Absturz beim Öffnen von Blättern (behoben)

**Was passierte:** Im Lauf vom Vormittag stürzte die App dreimal ab, jedes Mal mit „Fatal error: No ObservableObject of
type Session found“ (Absturzberichte `UniFlow-2026-11-14-123303.ips`, `-123346.ips`, `-123352.ips`). Betroffen waren
„Wochentest erstellen“ (aus dem KI-Start und aus der Seite „Tests“) und „Frag die KI zu Aufgabe …“ im schmalen Fenster,
wo diese Dialoge als Blatt von unten kommen.

**Ursache:** Am Mac (macOS 26.6, „Designed for iPad“) liest SwiftUI beim Anlegen eines Blatts dessen Einstellungen
(`PresentationHostingController.init` → `bridgedPresentation`). Dafür baut es den Inhalt einmal auf, **bevor** die
Umgebung der öffnenden Ansicht im Blatt angekommen ist. Hat eine Ansicht im Blatt eine Verzweigung (`if`, `switch`) und
liest dabei ein Umgebungsobjekt (`@EnvironmentObject`: Sitzung, Abgleich, Navigation, …), gibt es das Objekt in diesem
Moment noch nicht, und die App stürzt ab. Am iPad und iPhone kommt die Umgebung vorher an.

Das ist kein Fehler des Testaufbaus. Ein kleiner Probetest ohne App-Code und ohne Bedienungshilfen stellt es nach:

| Inhalt des Blatts | Mac ohne Absicherung |
|---|---|
| Text, der ein Umgebungsobjekt liest (ohne Verzweigung) | läuft |
| `if` im `body` und ein Umgebungsobjekt | **Absturz** (Blatt, Vollbild-Blatt und Popover) |
| dasselbe in einer `ScrollView` oder in einer äußeren Ansicht | **Absturz** |
| dasselbe in einem `NavigationStack` | läuft |
| dasselbe hinter der neuen Absicherung | läuft, Höhe des Blatts und „nicht wegwischbar“ kommen weiter an |

Dieselbe Ursache hatte der Absturz „Nachricht in Stud.IP“ vom 09.11.2026 (`e057f3da`), damals an drei Stellen einzeln
behoben.

**Behebung:** Neue Datei `apps/apple/UniFlow/Design/UFSheetGate.swift`. Die App öffnet Blätter nur noch über
`ufSheet`, `ufFullScreenCover` und `ufPopover`. Sie setzen ein Kennzeichen in die Umgebung, und der Inhalt wird am Mac
erst aufgebaut, wenn das Kennzeichen im Blatt angekommen ist; dann sind auch alle Umgebungsobjekte da. Am iPad und
iPhone wird der Inhalt wie bisher sofort aufgebaut. Alle 103 Stellen in 43 Dateien sind umgestellt (nur der Name des
Aufrufs, sonst nichts).

**Tests dazu:** `SheetGateAppTests` (7 Tests): Blatt, Vollbild-Blatt und Popover mit genau der Absturz-Form bauen ihren
Inhalt auf und behalten ihre Einstellungen; ein Quelltest sorgt dafür, dass kein neues Blatt an der Absicherung vorbei
geöffnet wird. Am Mac laufen die drei Tests vom Vormittag jetzt durch.

**Wer ist betroffen:** Die schmalen Blätter gibt es seit der iPhone-Fassung, also in den Builds 39 und 40
(Version 1.0.4, nur TestFlight). In 1.0.3 (Build 35, im Store) gibt es sie noch nicht. Die Reparatur ist nicht in
Build 40; sie kommt mit Build 41. Ob in 1.0.3 andere Blätter am Mac betroffen sind, ist nicht geprüft; in den
Mac-Läufen vom 09.11.2026 fiel nur „Nachricht in Stud.IP“ auf.

## 4. Cookies und Anmeldungen: am Mac in Ordnung

Vorrangig geprüft, weil ein Fehler hier echte Logins und die Trennung der Konten träfe.

- **Einzeln am Mac grün:** `DataSeparationAppTests` 15 von 15; `AuditRunde11AppTests` 20, `CertificatesAppTests` 7,
  `ExamRegistrationAppTests` 11, `HildesheimAppTests` 12, `HildesheimParityAppTests` 3 zusammen in einem Lauf, 53 von 53.
- **Nach den Abnahme-Tests grün:** `AbnahmeTarife`, `AbnahmeV1`, `AbnahmeV1LUHRelease`, `AboNurJahr`, danach
  `AuditRunde11AppTests` 20 von 20 und `DataSeparationAppTests` 15 von 15 im selben Prozess.
- **Probe, viele Datenspeicher:** 300 dauerhafte Datenspeicher (`WKWebsiteDataStore(forIdentifier:)`) nacheinander in
  einem Prozess, einmal freigegeben und einmal alle behalten: jedes gesetzte Cookie ist lesbar, kein Ausfall.
- **Probe, Pause:** Cookie setzen, 50 Sekunden nichts tun (WebKit beendet dann seine Hilfsprozesse), danach: derselbe
  Speicher liest sein Cookie, nimmt ein neues an, ein frischer Speicher arbeitet, eine neue Webansicht lädt. Auch mit
  einer Webansicht davor.

**Warum dann die Fehler am Vormittag?** Im langen Lauf fielen ab 12:23:52 alle Cookie-Zugriffe aus, in jedem neuen
Datenspeicher, bis zum Abbruch. Kurz davor (12:23:40) meldete WebKit „Could not signal service
com.apple.WebKit.WebContent/GPU“. Der Netzwerkdienst von WebKit im Testprozess war danach nicht mehr erreichbar. Das
ist derselbe Befund wie am 09.11.2026 (`docs/paritaet/MAC-B28-2026-11-09.md`, Gruppe E). Nachstellen ließ es sich in
kurzen Läufen nicht, weder mit vielen Datenspeichern noch mit einer Pause noch nach den Abnahme-Tests. Es tritt nur im
Testprozess nach vielen Minuten und hunderten Tests auf. Die App selbst hat je Hochschule und Konto genau einen
Datenspeicher.

**Urteil:** Testaufbau. Die Cookie-Speicher arbeiten am Mac wie am iPad, die Trennung je Konto und Hochschule hält.
Ein echter Login am Mac bleibt trotzdem auf der Handliste (Abschnitt 7), weil kein Test die echten Uni-Seiten aufruft.

**Nebenbefund:** Im Container der App auf diesem Mac (`~/Library/Containers/6196C4B8-…`) liegen 533 alte
Datenspeicher aus Testläufen der letzten Tage. Sie stören nicht (die Läufe oben sind damit grün), ich habe sie nicht
gelöscht, weil im selben Container auch echte Daten des Inhabers liegen können.

## 5. Tests, die nur am Mac nicht passen

Diese Tests prüfen die App richtig, treffen am Mac aber auf Dinge, die es dort im Testprozess anders oder gar nicht
gibt. Sie sind im Testcode gekennzeichnet (`ContainerTestBed.skipOnMac(…)` bzw. `requireVisibleTestPurchases()`), jeweils
mit Begründung. Der iPad-Simulator prüft sie weiter in vollem Umfang.

| Was | Tests | Begründung |
|---|---|---|
| **Test-Kaufumgebung von Apple** (`SKTestSession`) | 25 Kauf-Tests in `PurchaseTests`, `PurchaseV2PlanSwitchTests`, `PurchaseP44Tests`, `PurchaseServiceRetryP78Tests`, `AboNurJahrAppTests` | Die Testsitzung bucht jeden Kauf, StoreKit 2 sieht im Mac-Testprozess aber höchstens den ersten Kauf eines Prozesses. Der Tarif bleibt „free“. Befunde 08.11., 09.11. und 14.11. Die Produkte, Preise und Texte prüfen die Tests am Mac weiter. **Den Kauf selbst kann am Mac nur ein Mensch prüfen.** |
| Bildschirmtastatur des iPhones | `IPhoneMessageReplyTests.testComposerKeepsSendReachable` (zweiter Teil) | am Mac gibt es keine Bildschirmtastatur, das Blatt bleibt beim Tippen halb hoch |
| Fokus zurück zum Editor | `EditorPaletteReturnAppTests.testWritingOnThePageAgainAfterTheChatBringsThePaletteBack` | am Mac bewusst abgeschaltet (`reclaimFocusForWriting`) |
| Bedienungshilfen-Baum schwankt | `AIViewsAppTests.testDocIndexCardShowsKnownPageWithReferencesNotesAndRebuild` | siehe unten; mit der Maus von Hand prüfen (Abschnitt 7) |

Angepasst statt übersprungen (der Test läuft am Mac und kennt den Unterschied):

- Breitenprüfung (`LayoutWidthAuditTests.overflows`): Schattenrand um Blätter am Mac ausgenommen.
- `IPhoneNavigationTests`, `IPhoneReaderTests`: Mac-Texte („Mac“, „Schreiben mit Maus oder Trackpad“).
- `IPhoneMensaTests`: Abschnitt „Allergene meiden“ steht am Mac im halbhohen Blatt nicht im Baum.
- `AbnahmeV1LUHReleaseAppTests`: Rundgang mit fünf Texten, Rückfrage „Von Stud.IP abmelden?“ ohne die Knöpfe.
- Aus dem Lauf am Abend (Abschnitt 6): `DeviceRuleAppTests`, `PlanContractTests`, `LockVisibilityAppTests`,
  `TutorCardsRunAppTests`, `StoreScreenshotTests`, `QISAnmeldungAppTests`, `CommunityCorrectionAppTests`,
  `ForeignInkWidthTests`, `RecordingSourcesAppTests`; übersprungen `StudyPlanChoiceAppTests` (Rückfrage) und
  `FlashcardsAppTests` (ein Test, echter Container).

**Tests, die am Mac schwanken (Urteil: Testaufbau):**

- `CommunityCorrectionWiringAppTests.testInboxBannerOnSpacePageOpensAndIgnores`: Der Test setzt den Tarif auf Plus.
  Am Mac steht der Tarif beim Prüfen wieder auf „free“ (gemessen), die Seite zeigt die Sperrkarte „Community ab
  StudiNow Plus“. Einzeln grün, nach den Abnahme-Tests mit Kaufumgebung rot. Vermutlich meldet sich StoreKit im
  Testprozess später noch einmal und die App rechnet den Tarif neu; nachgewiesen ist nur der überschriebene Tarif. Der
  Test überspringt sich am Mac, wenn genau das passiert ist.
- `AIViewsAppTests.testDocIndexCardShowsKnownPageWithReferencesNotesAndRebuild`: Der Bedienungshilfen-Baum der Karte
  „Schon erklärt“ schwankt im Mac-Testprozess. Mal fehlt ein Verweis, mal steht „Deine Notizen dazu …“ als Knopf im
  Baum und lässt sich über die Bedienungshilfe nicht auslösen. Am Mac übersprungen, von Hand prüfen (Abschnitt 7).
- `LecturersAppTests.testModuleCardShowsContactsAndOpensStudIPMessage` („Lehrende ausklappen“): Der Inhalt erscheint
  am Mac erst nach den 10 Sekunden, die der Test wartet. Im Lauf davor grün (0,2 Sekunden). Vermutlich war das
  Testfenster verdeckt (der Inhaber arbeitete währenddessen am Mac); das ist nicht nachgewiesen. **Gegenprobe:** derselbe Test auf unverändertem `develop`
  (`57d7197c`, eigener Ordner und eigener Bau) ist zur selben Zeit genauso rot. Es liegt also nicht an der Reparatur.
  Nicht übersprungen, weil der Test am Mac auch grün lief.

Das passt zum Befund vom 09.11.2026 (`docs/paritaet/MAC-B28-2026-11-09.md`, Gruppe D): Tests, die Knöpfe über die
Bedienungshilfen suchen, schwanken am Mac zwischen den Läufen.

## 6. Ganze Suite am Mac auf dem Stand von Build 41 (Abend)

Nach der Freigabe der Hauptsitzung (Build 41 eingereicht) lief nicht nur die zweite Hälfte, sondern die ganze Suite
noch einmal am Mac, auf dem Stand von `develop` `b4ac2ca9` (= Build 41 plus Doku; darin die Reparatur aus Abschnitt 3
und die neuen Ansichten: Geräte-Regel, Studiengangswahl Hildesheim, iPhone-Wochenraster). 233 Klassen in 20 Paketen von
je 12 Klassen, die zweite Hälfte zuerst, 20:02 bis 20:38 Uhr.

| | |
|---|---|
| Tests | 1794 |
| Abstürze | **0** |
| übersprungen | 74 (alle mit Begründung: Kaufumgebung, Sandbox, Mac-Besonderheiten) |
| rote Tests | 16 (59 einzelne Meldungen), dazu 4 im Vorlauf der neuen Klassen |

### 6.1 Neue Ansichten aus dem Kandidaten

- Alle neuen Blätter laufen über die Absicherung aus Abschnitt 3 (108 Aufrufe, kein direktes `.sheet`).
- **Hinweis-Bildschirm der Geräte-Regel** (`DeviceRuleViews.swift`): Am Mac steht richtig „Mit Pro AI nutzt du
  StudiNow auf iPhone, iPad und Mac – mit Abgleich.“ Der Test erwartete den iPad-Wortlaut („iPhone und iPad“) und war
  darum viermal rot; er kennt jetzt beide. Bilder vom Mac angesehen (hell und dunkel, breit und schmal, auch der
  Plus-Hinweis): Texte ganz zu lesen, drei Knöpfe, nichts abgeschnitten. `DeviceRuleAppTests` 12 von 12.
- **Blatt „Studiengang wählen“:** `StudyPlanBoardAppTests.testProgramQuestionAndPicker` und `IntroProgramAppTests`
  am Mac grün; das Blatt geht auf und zeigt die Liste.
- `IPhoneWeekGridTests` 6 von 6, `HildesheimAppTests`, `ViewTypeDepthAppTests`, `SheetGateAppTests` grün.

### 6.2 Die 16 roten Tests mit Urteil

Kein Fehler der App darunter. Alle Tests sind angepasst und danach am Mac noch einmal gelaufen (`nach-1.log`, die
letzten zwei Zeilen der Tabelle `nach-3.log`): alle grün bzw. mit Begründung übersprungen.

| Tests | Ursache | Was daraus wurde |
|---|---|---|
| `PlanContractTests` (3) | Am Mac nennt die App Maus und Trackpad statt des Apple Pencil (`UFDevice.adapt`, so gewollt). Der Test verglich mit dem iPad-Wortlaut. | Test vergleicht mit dem Wortlaut des Geräts. Grün. |
| `LockVisibilityAppTests` (2) | Die Leistenlage „Schwebend“ gibt es am Mac bewusst nicht (`EditorToolbarPlacement.resolve`). | Am Mac prüft der Test, dass die Wahl auf „Oben fest“ fällt, und den Teil „unten fest“. Grün. |
| `PurchaseServiceRetryP78Tests` (2) | Test-Kaufumgebung von Apple (Abschnitt 5). | am Mac übersprungen wie die anderen Kauf-Tests |
| `QISAnmeldungAppTests` (1) | Der Test las eine Vorlage aus dem Repo-Ordner; das verbietet die Sandbox am Mac. | Vorlage kommt aus dem Testbundle. Grün. |
| `TutorCardsRunAppTests` (2), `StoreScreenshotTests.test02KIDokument` (1) | Der Umschalter „Diese Seite / Ganzes Dokument / Seiten …“ steht im Baum der Bedienungshilfe, lässt sich im Mac-Testprozess aber nicht darüber auslösen (bekannt seit 09.11.2026). | Am Mac wählt der Test das Segment direkt; der Rest (Karten in drei Teilen usw.) läuft. Grün. **Der Klick mit der Maus steht auf der Handliste.** |
| `StudyPlanChoiceAppTests.testDropRestoreAndResetWithConfirmation` (1) | Die Rückfrage „Plan zurücksetzen?“ zeichnet der Mac als eigenes Systemfenster (wie „Von Stud.IP abmelden?“). | Die Rückfrage erscheint; ab dem Knopf „Zurücksetzen“ am Mac übersprungen. **Handliste.** |
| `CommunityCorrectionAppTests` (1), `ForeignInkWidthTests` (1) | Der Mac stand abends auf dunklem Erscheinungsbild (schaltet automatisch um). Beide Tests gingen stillschweigend von „hell“ aus; am Vormittag waren sie grün. | Tests hängen nicht mehr vom Erscheinungsbild ab. Der Test zur fremden Tinte prüft jetzt wirklich in einem dunklen Fenster, dass sie hell bleibt. Grün. |
| `RecordingSourcesAppTests.testCookiesOnlyForStudIPFiles` (1) | echter Datenordner der App, Abschnitt 6.3 | Test hat jetzt einen eigenen, leeren Cookie-Speicher. Grün. |
| `FlashcardsAppTests.testResultAsksTheAIWithTheQuestionContext` (1) | echter Datenordner der App, Abschnitt 6.3 | Test überspringt sich, wenn der Testprozess einen aktiven Container hat (am Mac der Fall, im Simulator nicht) |

**Gegenprobe:** Die letzten zwei Tests sind am Mac auf unverändertem `develop` `57d7197c` (ohne die Reparatur, eigener
Ordner und eigener Bau) zur selben Zeit genauso rot. Es liegt also nicht an der Reparatur.

### 6.3 Befund: Am Mac laufen die Tests im echten Datenordner der App

Im Simulator ist die Test-App leer und nicht angemeldet. Am Mac ist der Testprozess dieselbe App wie die, die der
Inhaber von Hand benutzt (gleiche Kennung, gleicher Ordner `~/Library/Containers/6196C4B8-…`). Der Inhaber ist dort
angemeldet, die App öffnet beim Start seinen echten Container. Tests, die davon ausgehen, dass es keinen aktiven
Container gibt, treffen dadurch auf echte Daten:

- **Gelesen:** `RecordingSourcesAppTests` bekam die echte Stud.IP-Sitzung zu sehen (fünf Cookies von
  `studip.uni-hannover.de`). Im Protokoll stehen nur die Namen der Cookies, keine Werte. Der Test fragt nur, ob Cookies
  da sind; er schickt nichts ins Netz. Nach dem ganzen Lauf war die Sitzung weiter da (dieselben fünf Cookies).
- **Geschrieben:** Tests, die die KI-Hilfe über die Oberfläche bedienen, haben ihre Test-Gespräche in die echte
  KI-Ablage der Mac-App geschrieben. Dort liegen jetzt 7 Einträge, alle von heute und alle aus Tests (Kennungen
  `exam:8:1`, `f-1`, `f-area-…`, `f-sn-…`; nur die Kennungen angesehen, keine Texte). Daran scheiterte auch der
  Karteikarten-Test: Er fand sein eigenes Gespräch vom Vormittag vor.
  Datei: `~/Library/Containers/6196C4B8-…/Data/Library/Application Support/UniFlowContainers/<Container>/tutor-conversations.json`.
  **Nicht gelöscht**, weil es der Datenordner des Inhabers ist. In der App können sie unter den letzten
  KI-Gesprächen auftauchen (z. B. „Aufgabe 1 – Zahlensysteme“). Einen Knopf zum Löschen einzelner Gespräche habe ich
  in der App nicht gefunden. Am einfachsten leert die Hauptsitzung die Datei mit Okay des Inhabers (vorher sichern);
  andere als die 7 Test-Einträge stehen nicht darin.
- Dazu passen die 533 alten Web-Datenspeicher aus Testläufen im selben Ordner (Abschnitt 4). Tests ändern außerdem
  echte Einstellungen der Mac-App: `LockVisibilityAppTests` setzt die Leistenlage und löscht sie am Ende, eine eigene
  Wahl des Inhabers („Unten fest“) wäre danach wieder auf der Vorgabe „Oben fest“.

**Urteil:** kein Fehler der App, sondern eine Lücke im Testaufbau am Mac. 66 Stellen in den Tests legen einen
Stud.IP-Abgleich ohne eigenen Cookie-Speicher an und nähmen am Mac den des echten Containers. Ich habe nur die zwei
Tests abgesichert, die rot waren.

**Vorschlag (eigene Aufgabe, nicht in diesem Zweig):** Unter XCTest darf die App am Mac den echten Container gar
nicht erst öffnen, oder die Mac-Testläufe bekommen eine eigene App-Kennung mit eigenem Ordner. Bis dahin: Mac-Läufe
nur, wenn es sein muss, und danach die Test-Gespräche in der Mac-App löschen.

### 6.4 Für künftige Mac-Läufe

- **Der Mac muss entsperrt und wach sein.** Der Nachlauf von 20:40 bis 21:51 Uhr fiel in die Zeit, in der der
  Bildschirm aus war: 102 Tests brauchten 72 Minuten statt weniger Minuten (ein Test 16 Minuten), die Ergebnisse
  stimmten aber. Bei gesperrtem Mac (ab etwa 22:00 Uhr) kam der Testprozess gar nicht in Gang („test runner hung
  before establishing connection“). Nach dem Entsperren lief der letzte Nachlauf normal.
- **Helles und dunkles Erscheinungsbild** machen am Mac einen Unterschied für Tests; der Simulator ist immer hell.
- `LecturersAppTests.testModuleCardShowsContactsAndOpensStudIPMessage` (Abschnitt 5) war im Lauf am Abend grün.

## 7. Was nur ein Mensch am Mac prüfen kann

Die Tests rufen keine echten Uni-Seiten auf, kaufen nicht echt und bewegen keine echte Maus. Bitte am Mac mit einem
Build aus diesem Zweig von Hand prüfen (etwa 30 Minuten):

1. **Echter Uni-Login:** Einstellungen → Stud.IP & QIS → anmelden. Danach „Jetzt abgleichen“: Dateien, Stundenplan und
   Noten kommen. App beenden, neu öffnen: noch angemeldet. Dasselbe für Uni-Mail.
2. **Abo-Kauf:** Tarifseite öffnen, „StudiNow Plus“ mit einem Sandbox-Konto kaufen. Der Tarif muss sofort „Plus“ zeigen.
   Danach „Käufe wiederherstellen“.
3. **Mit Apple anmelden** beim ersten Start.
4. **Blätter im schmalen Fenster** (das war der Absturz): Fenster schmal ziehen, bis unten die Tab-Leiste erscheint.
   Dann KI-Start → „Wochentest“, Seite „Tests“ → „Wochentest erstellen“, einen abgegebenen Test öffnen → „Frag die KI zu
   Aufgabe …“. Jedes Blatt muss aufgehen und sich schließen lassen.
5. **Blätter im breiten Fenster:** Dokument öffnen → Suche, Info, Gliederung, Papierkorb, „Dokument daneben“; Tarifwahl
   über ein Schloss; Community → eine Lösung lesen; Nachricht in Stud.IP beantworten.
6. **Editor mit Maus und Trackpad:** „Maus blättert“ und „Maus schreibt“, zwei Finger wischen blättert, Cmd-Z, Cmd +/−/0,
   Pfeiltasten. Liste dazu in `docs/paritaet/MAC-BEDIENUNG-2026-11-09.md`, Abschnitt 5.
7. **Fenster vergrößern und verkleinern:** von ganz breit bis ganz schmal (515 pt), dabei Übersicht, Einstellungen, ein
   Dokument und der Lernkalender. Nichts darf abgeschnitten sein. Zweites Fenster mit Cmd-N.
8. **KI-Erklärung zur Seite:** im Dokument die KI-Hilfe öffnen, bei einer schon erklärten Seite auf „Deine Notizen dazu
   vom … auf Seite …“ klicken. Die Seite muss aufgehen (Abschnitt 5, Bedienungshilfe).
9. **Rückfragen des Systems:** „Von Stud.IP abmelden?“ erscheint am Mac als eigenes kleines Fenster; „Abbrechen“ und
   „Abmelden“ müssen gehen. Dasselbe im Studienplan: „Plan zurücksetzen“ → „Zurücksetzen“ und „Abbrechen“.
10. **Umschalter in der KI-Hilfe:** im Dokument die KI-Hilfe öffnen und oben „Ganzes Dokument“ und „Seiten …“ mit der
    Maus anklicken, auch im Reiter „Karteikarten“. Die Auswahl muss umspringen.
11. **Dunkles Erscheinungsbild:** den Mac auf „Dunkel“ stellen und Übersicht, ein Dokument mit Notizen und eine
    Community-Lösung kurz ansehen. Tinte und Texte müssen lesbar bleiben.
12. **Test-Gespräche:** nachsehen, ob in der Mac-App unter den letzten KI-Gesprächen Einträge aus den Tests stehen
    (z. B. „Aufgabe 1 – Zahlensysteme“, Abschnitt 6.3). Wenn ja, der Hauptsitzung Bescheid geben; sie räumt die Datei auf.

## 8. Empfehlung zu „Kompatibilität mit Apple Silicon Macs bestätigen“

**Aus Sicht der Tests: ja, der Knopf kann gedrückt werden. Aber erst, wenn zwei Dinge erfüllt sind.**

Was dafür spricht:

- Der einzige echte Mac-Fehler (Absturz beim Öffnen von Blättern, Abschnitt 3) ist behoben und in Build 41.
- Die ganze Suite ist am Mac auf dem Stand von Build 41 gelaufen: 1794 Tests, kein Absturz, kein roter Test, der auf
  einen Fehler der App zeigt (Abschnitt 6).
- Cookies, Anmeldungen und die Trennung der Konten arbeiten am Mac wie am iPad (Abschnitt 4).
- Die neuen Ansichten (Geräte-Regel mit dem Text „iPhone, iPad und Mac“, „Studiengang wählen“) sind am Mac in Ordnung.

Die zwei Bedingungen:

1. **1.0.4 (Build 41) ist von Apple freigegeben und im Store.** Mit dem Knopf erklärt der Inhaber Apple gegenüber,
   dass er die App am Mac geprüft hat; im Mac App Store verschwindet dann der Hinweis „Nicht für macOS überprüft“. Das
   soll für die Version gelten, die die Reparatur enthält. Die Builds 39 und 40 (nur TestFlight) haben den Absturz
   noch. Für 1.0.3 (im Store) ist nicht geprüft, ob andere Blätter am Mac betroffen sind.
2. **Die Handprüfung aus Abschnitt 7 ist am Mac mit Build 41 gemacht** (TestFlight für Mac oder direkt aus Xcode,
   etwa 30 bis 40 Minuten). Kauf, echter Uni-Login und „Mit Apple anmelden“ kann kein Test prüfen, und sie sind am Mac
   noch nie von Hand bis zum Ende geprüft (so auch `docs/paritaet/MAC-B28-2026-11-09.md`, Abschnitt 6). Am wichtigsten
   sind die Punkte 1 bis 4 und 10.

Sind beide erfüllt und ohne Befund: drücken. Bis dahin darf die App im Mac App Store verfügbar bleiben. Für iPad und
iPhone hat das alles keine Folgen.

## 9. iPad-Gegenlauf

Die Absicherung fasst 103 Stellen an. Darum lief nicht nur eine Auswahl, sondern alles (App- und Testquellen wie
Commit `9aa5f70a`; danach kam nur noch die Build-Nummer 41 aus `develop` dazu):

| Lauf | Tests | übersprungen | Fehler | Protokoll |
|---|---|---|---|---|
| iPad-Simulator, Klon „iPad Mac-Durchlauf“ von `4495AA80-…`, ganze Suite | 1772 | 31 | 0 | `sim-ipad-voll.log` |
| iPhone 17, Klon „iPhone Mac-Durchlauf“ von `5D435FE8-…`, alle `IPhone*Tests` und `LayoutWidthAuditTests` | 128 | 2 | 0 | `sim-iphone.log` |
| Swift-Kern (`swift test` in `Packages/UniFlowCore`) | 1531 | 12 | 0 | `swift-test.log` |

- Keiner der am iPad übersprungenen Tests kommt aus den Mac-Kennzeichnungen (die greifen nur am Mac).
- `ViewTypeDepthAppTests` grün: `DocumentView.chrome` Tiefe 50 (Grenze 70), erstes Zeichnen 308 KB (Grenze 768 KB).
  Die neuen Aufrufe schachteln den Typ nicht tiefer als `.sheet` vorher.
- Nicht gelaufen: Python- und Browser-Tests (von der Änderung nicht berührt) und ein Release-Bau. Beides macht die
  Hauptsitzung mit dem Kandidaten für Build 41.

**Nachtrag am Abend (Stand Build 41):** Der App-Code dieses Zweigs ist jetzt gleich `develop` `1c2fd03a`; es
unterscheiden sich nur Tests und dieser Bericht. Darum lief am iPad-Simulator nicht noch einmal alles, sondern die 13
geänderten Testklassen und zwei Nachbarn: 148 Tests, 2 übersprungen, 0 Fehler (`sim-ipad-b42.log`). Darunter der neue
Test, dass fremde Tinte im dunklen Fenster hell bleibt.

## 10. Commits

| Commit | Inhalt |
|---|---|
| `0d3f8b48` | App: Absicherung der Blätter (`UFSheetGate.swift`, 103 Aufrufe umbenannt), Test `SheetGateAppTests` |
| `bd13f742` | Tests kennen den Mac (übersprungen mit Begründung bzw. angepasst) |
| `9aa5f70a` | zwei am Mac schwankende Tests gekennzeichnet; App sonst wieder wie `develop` |
| `3d82d034` | `develop` (`57d7197c`, Build-Nummer 41) hereingeholt; dieser Stand ist der Hauptsitzung für Build 41 gemeldet |
| `b121eef6` | Bericht, Zwischenstand vom Nachmittag |
| `b5c5298a`, `212a9cba` | `develop` (`b4ac2ca9`, dann `1c2fd03a`: Stand Build 41) hereingeholt |
| `5a4082e0` | Tests aus dem Lauf am Abend angepasst (Abschnitt 6.2), nur Testcode |
| danach | dieser Bericht, fertig |

**Aufgeräumt:** Die Simulator-Klone „iPad Mac-Durchlauf“ und „iPhone Mac-Durchlauf“, der Vergleichsordner
`~/Studora-Builds/wt-macdev-vergleich` und die Bau-Ordner `dd-mactest-dev` und `dd-macdurchlauf-sim` sind gelöscht.
Geblieben sind die Protokolle in `~/Studora-Builds/mac-durchlauf/` (mit den Bildern der Geräte-Regel vom Mac im
Unterordner `bilder/`) und der Mac-Bau-Ordner `dd-mactest`. Nicht angefasst: der Datenordner der Mac-App
(Abschnitt 6.3).
