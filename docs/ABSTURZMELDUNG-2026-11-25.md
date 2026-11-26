# Absturzmeldung (25.11.2026)

Zweig `app/absturzmeldung` (ab `release/1.0.7-b47` @ `9a5983d8`). Nur lokal: nichts gepusht, nichts auf dem Server,
nichts bei Apple, nichts auf der Website.

## Worum es geht

Frage des Inhabers am 25.11.2026: „Gab es bei neuen Nutzern Abstürze?“ Das ließ sich nicht beantworten: Die App
meldete nichts, und Apples eigene Zahlen (Xcode → Organizer → Crashes) kommen mit etwa einem Tag Verzug und nur von
Nutzern, die Diagnosedaten mit Entwicklern teilen.

Jetzt meldet die App Abstürze selbst – so sparsam wie möglich – und der Inhaber kann sie zählen lassen:

```sh
# im Container des Dienstes (nur lesen)
docker compose exec app python -m app.crash_reports --tage 14
# nur App Store, ohne die eigenen Testfassungen
docker compose exec app python -m app.crash_reports --tage 14 --quelle store
```

Ausgabe (Beispiel mit erfundenen Daten):

```
Abstürze von 2026-11-12 bis 2026-11-25 (14 Tage)

Zusammen: 2 Abstürze, 1 Hänger.

Tag         Version     Gerät  Quelle     Abstürze  Hänger  Geräte
----------  ----------  -----  ---------  --------  ------  ------
2026-11-24  1.0.6 (45)  iPad   App Store  1         1       1
2026-11-24  1.0.5 (44)  iPad   Test       1         0       1
```

## Was gemeldet wird

Quelle ist Apples MetricKit (kein fremdes Paket, kein Dienst von Dritten). iOS gibt der App drei Dinge:

| Art | Was es ist | Wann es kommt |
|---|---|---|
| Absturz (`crash`) | die App ist abgestürzt | beim nächsten Start, manchmal erst am Folgetag |
| Hänger (`hang`) | die App hat länger nicht reagiert | wie oben |
| Von iOS beendet (`exit`) | Tageszählung von Apple: wie oft iOS die offene App beendet hat, z. B. weil der Speicher voll war | einmal am Tag für den Vortag |

Die Tageszählung ist dazugekommen (im Vorschlag stand sie nicht), weil „Speicher voll“ der häufigste Grund ist, aus
dem eine App mit großen PDFs verschwindet – und genau dafür gibt es bei Apple keinen Absturzbericht.

Je Meldung geht hinaus – und nichts sonst:

- App-Version und Build (die der abgestürzten App, auch wenn inzwischen ein Update da ist)
- Geräteart (iPhone, iPad, Mac), Modell (z. B. `iPad14,3`), Systemversion
- Quelle: `store` (App Store) oder `test` (TestFlight, Kabel-Fassung) – damit die eigenen Testgeräte die Zahlen der
  Nutzer nicht verfälschen
- Zeitpunkt, Art, Signal, Ausnahme-Typ und -Code, Beendigungsgrund von iOS, Name der Ausnahme-Klasse
- bei Hängern die Dauer, bei „von iOS beendet“ Grund und Anzahl
- die oberste Aufrufkette: je Zeile „Programmdatei + Zahl“ (höchstens 32 Zeilen; zum Zuordnen mit den Symboldateien
  des Builds)

Nie: Name, E-Mail, Konto, Uni-Zugang, Dokumente, Dateinamen, der **Text** einer Ausnahme (kann Dateinamen
enthalten), Speicherangaben, Region, IP-Adresse bei der Meldung. Die Tests prüfen das mit einem Beispiel, das solche
Dinge absichtlich enthält (`packages/shared-contracts/fixtures/crash-report/`).

## Entscheidungen (mit Begründung)

1. **Ohne Konto.** Die Meldung geht ohne Anmeldung an `POST /api/diagnose/crashes`. Gründe: Ein Absturz beim
   ersten Start oder in der Begrüßung passiert, bevor es ein Konto gibt – das sind genau die „neuen Nutzer“ aus der
   Frage. Und die Zahlen brauchen keinen Bezug zu einer Person; ohne Konto fällt er gar nicht erst an.
   Preis dafür: ein öffentlicher Weg in den Dienst. Abgesichert durch: höchstens 64 KB je Anfrage, 20 Meldungen je
   Anfrage, 30 Meldungen je Gerät und Tag, 20.000 insgesamt je Tag, 120 Anfragen je IP und Stunde, strenge Prüfung
   jedes Feldes, Unbekanntes wird verworfen. Lesen kann man über diesen Weg nichts.
   Die App nimmt dafür eine eigene Verbindung ohne Cookies: Der Dienst setzt bei der Anmeldung des Kontos ein
   Sitzungs-Cookie, und über die gemeinsame Verbindung der App wäre es bei jeder Meldung mitgegangen.
   Was bleibt: Wer will, kann von außen erfundene Meldungen schicken und die Zahlen verfälschen (bis zu den Grenzen
   oben). Für „wie viele Abstürze ungefähr“ reicht das; wer es fälschungssicher will, braucht Apples App Attest
   (nicht gebaut).
2. **Geräte zählen ohne Geräte-Kennung.** Die App würfelt eine eigene Kennung nur für diese Meldungen (nicht die
   Geräte-Kennung des Kontos). Der Dienst speichert davon nur einen Wert aus Kennung + Tag + Dienst-Geheimnis, der
   jeden Tag ein anderer ist. So lässt sich sagen „3 Abstürze auf 2 Geräten“, aber kein Gerät über Tage verfolgen.
3. **Schalter: ja, und von selbst an.** Einstellungen → Hilfe & Rechtliches → „Absturzberichte an StudiNow senden“.
   An ohne Rückfrage wie beim Datei-Eingang (Entscheidung vom 18.11.2026); Aus löscht die wartenden Meldungen und
   die Kennung. Begründung: Ohne Schalter gäbe es keinen einfachen Widerspruch; mit „erst fragen“ melden so wenige,
   dass die Zahlen kaum etwas sagen. **Vom Inhaber am 25.11.2026 so entschieden („Ja, von selbst an“).**
4. **Debug-Builds und Tests schicken nie.** Nur Release-Builds (App Store, TestFlight, Kabel-Fassung) melden.
5. **Aufbewahrung 90 Tage**, dann löscht der tägliche Aufräumlauf (`app/retention.py`).
6. **Aufrufkette wird roh gespeichert**, erst die Auswertung deutet sie (Absturzstelle zuerst). So lässt sich die
   Deutung später verbessern, ohne dass alte Meldungen wertlos werden.

## Wo was liegt

| Teil | Datei |
|---|---|
| Kern: Apples Daten kürzen, Warteschlange, Senden | `apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/Diagnostics/CrashReports.swift` |
| App: Empfang von MetricKit, Schalter, Karte in den Einstellungen | `apps/apple/UniFlow/Services/CrashReporting.swift` |
| Start der App | `UniFlowApp.init` → `CrashReporter.shared.refresh()` |
| Dienst: Endpunkt, Tabelle `crash_reports` in `accounts.db`, Grenzen, Auswertung | `app/crash_reports.py` |
| Auswertung als Werkzeug | `tools/absturz-auswertung.py` (im Container: `python -m app.crash_reports`) |
| Durchlauf Gerät → Dienst → Auswertung | `tools/absturz-durchlauf.sh` |
| Vertrag zwischen App und Dienst (erfundene Daten) | `packages/shared-contracts/fixtures/crash-report/` |
| Datenschutz-Absatz (Entwurf) | `docs/release/DATENSCHUTZ-ABSATZ-ABSTURZMELDUNG-ENTWURF.md` |
| App-Datenschutz bei Apple (Tabelle) | `docs/release/APP-STORE.md`, Zeile „Diagnose → Absturzdaten“ |
| Datenschutz-Manifest der App | `apps/apple/UniFlow/PrivacyInfo.xcprivacy` (neu: Absturzdaten, nicht verknüpft) |

## Geprüft

Stand 25.11.2026, abends, alles auf dem Mac des Inhabers:

| Lauf | Ergebnis |
|---|---|
| Dienst: `tools/tests-schnell.sh` (alle Python-Tests ohne Lasttests, dazu die Browser-Logik) | 4116 bestanden, 0 rot; 472 Browser-Tests bestanden |
| davon neu: `tests/test_crash_reports.py` | 34 Tests |
| App-Kern: `swift test` in `apps/apple/Packages/UniFlowCore` | 1825 Tests, 0 rot (17 übersprungen: brauchen einen laufenden Testdienst) |
| davon neu: `CrashReportTests` | 16 Tests |
| App im Simulator („Absturzmeldung iPad“, eigener Bau-Ordner `~/Studora-Builds/dd-absturzmeldung`): `CrashReportAppTests`, `AIConsentAppTests`, `EinstellungenKlarAppTests`, `AbnahmeV1AppTests`, `WakePushAppTests`, `CourseFileIntakeAppTests`, `LayoutWidthAuditTests` | 83 Tests grün (1 übersprungen); nach den letzten zwei Änderungen noch einmal 36 grün, davon 8 neue in `CrashReportAppTests` |
| Durchlauf `tools/absturz-durchlauf.sh`: echter Dienst lokal → Swift-Kern schickt eine erfundene Meldung in Apples Format → Auswertung | bestanden: 2 Abstürze und 1 Hänger kommen an, je Version und Geräteart richtig gezählt |

Nicht gelaufen: die ganze iPad-Suite (`-only-testing:UniFlowTests`, alle rund 280 Klassen) und die iPhone-Suite – nur
die Klassen oben, die die geänderten Stellen berühren. Vor einem Build bitte einmal ganz laufen lassen
(`docs/TESTLAEUFE.md`).

Der Durchlauf hängt an einem gemeinsamen Beispiel (`packages/shared-contracts/fixtures/crash-report/`): Die
Swift-Tests prüfen, dass die App aus Apples Daten genau `upload.json` baut; die Python-Tests prüfen, dass der Dienst
genau diese Datei annimmt und richtig zählt. `tools/absturz-durchlauf.sh` macht dasselbe einmal über das Netz
(127.0.0.1), mit dem echten Dienst-Prozess.

## Was der Inhaber noch entscheiden muss

1. ~~Von selbst an oder erst fragen?~~ **Entschieden am 25.11.2026: von selbst an.** Der rechtliche Hinweis dazu
   (§ 25 TDDDG) steht im Entwurf des Datenschutz-Absatzes; er gehört zur Prüfung des Textes in Punkt 2.
2. **Datenschutztext.** Seit 26.11.2026 als Abschnitt 10a in `docs/release/DATENSCHUTZ.md` (Zweig
   `recht/1.0.8-rechtstexte`, Website-Fassung im Zweig `site/1.0.8-rechtstexte`); online erst nach dem Upload der Website.
   Ursprünglich: Entwurf lesen, ändern, freigeben. Erst dann kommt er in `docs/release/DATENSCHUTZ.md` und
   `site/datenschutz.html` – und online erst zusammen mit der App-Version (Uploads zur Website sind laut Notiz bis
   05.12.2026 ohnehin gesperrt).
3. **App-Datenschutz bei Apple.** In App Store Connect die Datenart „Diagnose → Absturzdaten“ eintragen (erfasst,
   nicht verknüpft, kein Tracking, App-Funktionalität), bevor der Build eingereicht wird.
4. **Deploy des Dienstes.** Erst der Dienst, dann die App: Vor dem Deploy antwortet der Dienst der App mit „nicht
   angemeldet“; die App hebt die Meldungen dann bis zu 30 Tage auf (höchstens 60) und versucht es bei jedem Start
   wieder. Es geht also nichts kaputt, wenn die App früher draußen ist – es kommt nur nichts an.
5. **In welche App-Version.** 1.0.7 (Build 48) ist eingereicht und enthält das nicht. Vorschlag: 1.0.8. Vorher in
   `release/…` einmischen; geänderte gemeinsame Dateien: `UniFlowApp.swift`, `SettingsPage.swift`,
   `PrivacyInfo.xcprivacy`, `app/server.py`, `app/retention.py`, `docs/release/APP-STORE.md`.
6. **Aufbewahrung 90 Tage** und die Grenzen (30 je Gerät und Tag) – passt das so?

## Nicht geprüft (ehrlich)

- **Kein echter Absturz ist durchgelaufen.** MetricKit liefert nur auf echten Geräten, meist erst beim nächsten Start
  oder am Folgetag; im Simulator kommt nie etwas. Geprüft ist der Weg mit erfundenen Daten in Apples Format.
- **Das Format der Absturz- und Hänger-Pakete** stammt aus den Schlüsselnamen in Apples MetricKit-Bibliothek
  (iOS 27.2, am 25.11.2026 nachgesehen) – ein echtes Paket lag nicht vor. Das Format der **Tageszählung** ist dagegen
  an echten Daten geprüft: Auf dem iPad des Inhabers lagen vier Messwerte-Pakete im Diagnose-Ordner
  (`HaengerSpur`, per Kabel gelesen, Kopie in `~/Studora-Builds/absturz-diagnose/`); Aufbau und Feldnamen stimmen mit
  dem überein, was der Code liest. Nebenbei: Für den 23. und 24.11. meldet iOS auf diesem iPad kein einziges
  ungewolltes Ende im Vordergrund.
- **Reihenfolge der Aufrufkette** (Absturzstelle zuerst oder zuletzt) ist am echten Gerät nicht bestätigt. Die
  Auswertung dreht die Kette, wenn der Programmstart (`dyld`) vorn steht; bei Abstürzen außerhalb des Hauptfadens
  kann die „häufigste Stelle“ deshalb falsch benannt sein. Die Zahlen je Tag, Version und Gerät hängen davon nicht ab.
- **Mac („Designed for iPad“):** ob MetricKit dort überhaupt liefert, ist nicht geprüft. Die Geräteart „Mac“ wird
  richtig erkannt, falls etwas kommt.
- **Quelle „Store“ oder „Test“** ist als Regel getestet, nicht mit einer echten App-Store-Installation.
- **Nicht alle melden:** Wer den Schalter ausschaltet oder die App nach einem Absturz nie wieder öffnet, fehlt in
  den Zahlen. „Keine Meldungen“ heißt also nicht sicher „keine Abstürze“.
- **Symbole:** Die Aufrufkette nennt nur „Programmdatei + Zahl“. Den Funktionsnamen dazu liefert erst die
  Symboldatei (dSYM) des Builds, z. B. `atos -o UniFlow.app.dSYM/Contents/Resources/DWARF/UniFlow -l 0x100000000 <0x100000000 + Zahl>`.
  Ein Werkzeug dafür gibt es noch nicht.

## Erster Test am echten Gerät (wenn der Inhaber will)

Am einfachsten: eine Kabel-Fassung (Release) dieses Zweigs aufs iPad, den Dienst mit dem Zweig auf einem Testserver,
und abwarten – nach einem Tag kommt die Tageszählung von iOS, nach einem echten Absturz beim nächsten Start der
Bericht. `tools/absturz-auswertung.py` zeigt dann, ob es ankommt und wie die Aufrufkette aussieht.

Schneller ginge es mit Apples Beispiel-Paketen (Xcode → Debug → „Simulate MetricKit Payloads“, nur am echten Gerät).
Das läuft aber nur mit einer Debug-Fassung, und die schickt mit Absicht nie etwas. Dafür müsste sie ausnahmsweise
senden dürfen (ein Startargument) – das ist nicht gebaut.
