# Auftrag an die Mac-Sitzung: Uni Hildesheim in der iPad-App freischalten

Stand 25.10.2026, Zweig `develop`. Geschrieben von der PC-Sitzung. Gilt zusätzlich zu
[`AUFTRAG-APPSTORE-V1.md`](AUFTRAG-APPSTORE-V1.md); bei Widerspruch hat der App-Store-Auftrag Vorrang, außer bei der
**Datentrennung pro Hochschule** (unten), die der Projektinhaber ausdrücklich verlangt.

## Ziel (Wortlaut des Inhabers, sinngemäß)

> Hildesheim direkt in der App freischalten, damit es dort auch immer ausfallsicher klappt. Andere Unis dürfen
> keine Daten vermischen: jede Uni hat ihre Nutzer für sich allein.

1. Die iPad-App unterstützt neben der LUH die **Universität Hildesheim**: Dateien aus dem **Learnweb** (Moodle),
   persönlicher Stundenplan und Noten aus dem **LSF**, Anmeldung über das **CAS** der Uni.
2. **Strikte Trennung pro Hochschule** in allen Speichern (Datenbank, Dateien, Keychain, Cookies, Caches, Sync-Journal).
3. **Ausfallsicher**: Ein Fehler in einer Quelle oder einem Kurs darf nie den Rest abbrechen oder lokale Daten löschen.

## Referenz: PC-Umsetzung (fertig, getestet, live gegen die echte Uni geprüft)

| Teil | Datei | Was sie tut |
|---|---|---|
| Uni-Profile | `app/universities.py` | Schlüssel `luh` / `hildesheim`, URLs, Namen, Dienste |
| Datentrennung | `app/config.py` (`UNIVERSITY`, `data_dir_for`), `app/db.py` (`UniversityMismatch`) | eigener Datenordner je Uni, DB merkt sich ihre Uni |
| CAS-Login | `app/cas.py` | Apereo CAS 7.2, `https://www.uni-hildesheim.de/sso/login?service=…` |
| Learnweb | `app/learnweb.py` | REST mit Schlüssel oder AJAX mit Sitzung, Dateiliste, Pluginfile-Revisionen |
| LSF-Stundenplan | `app/lsf.py`, `timetable.parse_ics` | iCal-Export des Plans, BYDAY, EXDATE, Import nur Quelle `lsf` |
| LSF-Noten | `app/qis.py` Profil `hildesheim` | gleicher HIS-QIS-Notenspiegel wie LUH, ohne Bescheinigungen |
| Ablauf | `app/hildesheim.py` | Learnweb, danach LSF; jeder Kurs einzeln gespeichert |
| Doku | `docs/HILDESHEIM.md` | Endpunkte, Eigenheiten, offene Punkte |
| Tests | `tests/test_hildesheim.py` | 40 Tests ohne Netzwerk |
| **Gemeinsame Fixtures** | `packages/shared-contracts/fixtures/hildesheim/` | ICS, Moodle-JSON und `expected.json`; **dieselben Erwartungen in UniFlowCore prüfen** |

## Stand im Swift-Kern (PC-Sitzung, 25.10.2026 spät)

Fertig in `apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/Hildesheim/`, unter Linux kompiliert und getestet
(`HildesheimFixtureTests`, gleiche Erwartungen wie Python über `tools/gen-hildesheim-fixture.py`):

| Datei | Inhalt |
| --- | --- |
| `Learnweb.swift` | Kurstitel, Abschnitt → „Woche N“, Datei-ID (SHA-256), REST-Dateiliste, Sitzungs-Dateiliste, Pluginfile-Links, Ordnerseiten, **Instanz des Semesters** (`discoverBase`, jährlicher Wechsel learnweb2026 → 2027) |
| `HildesheimCAS.swift` | CAS-Login-Adressen für LSF und Learnweb, Erkennung der Loginseite, Fehlertext (`#loginErrorsPanel`); Formular, Rücksprung und Stand aus `CASLogin` ohne Aufrufer seit `wip/v1-pc-fix` entfernt (ob eine Anmeldung fertig ist, entscheiden `LSFClient.isLoggedIn` und `Learnweb.isLoggedIn`) |
| `LSFCalendar.swift` | ICS-Parser mit BYDAY und EXDATE, LSF-Titel „0449 - Titel (Lehrperson)“, iCal-Link aus der Stundenplan-Seite |
| `GradeRows.swift` | Notenspiegel-Zeilen im Hildesheimer Aufbau (Kopfzeile irgendwo, mehrere Abschlüsse, Modulzeilen weg), Ergebnis `QISGrade`; `QISGradeLayout` (Profil). Gesammelt wird der Hildesheimer Notenspiegel nur über `LSFClient.grades` |
| `TestShare.swift` | Schlüssel der gemeinsamen Wochentests, Inhalts-Hash (`contentHash(file:)`, auf Apple-Geräten mit CryptoKit, sonst `SolutionSHA256`; die eine Fassung für Stud.IP und Learnweb) |
| `Store/Migrations.swift` | `tests.share_key`, `files.content_sha256`, Index wie `app/db.py` |

**Schritt 2 (26.10.2026): Sync im Kern fertig**, 249 Swift-Tests grün unter Linux:

| Datei | Inhalt |
| --- | --- |
| `UniTransport.swift` | Schnittstelle `UniTransport` (send, download in Datei, Weiterleitung abschaltbar), `UniRetry` (3 Versuche bei Netz/5xx/429), `HildesheimError` |
| `LearnwebAPI.swift` | Learnweb mit Schlüssel (REST) oder Sitzung (sesskey + AJAX, Dateilinks über Location-Header); `Learnweb.discoverBase(…, transport:)` fragt die Instanz übers Netz |
| `HildesheimRules.swift` | `UniRules` (classify, fileKind, eventKind wie Python) |
| `MoodleSSO.swift` | `MoodleSSO` (launch.php, Token prüfen mit MD5) und `MoodlePublicConfig`; seit `wip/v1-pc-uni` in einer Datei (früher in `HildesheimRules.swift` und `Universities/MoodleSSO.swift`) |
| `HildesheimSync.swift` | `UniStore` (LSF-Plan, Noten in die SQLite-DB, wie Python; Kurs und Datei seit `wip/v1-pc` in `UniStore.swift`) und `HildesheimSync.run()`: kein Netz in einer Transaktion, je Kurs eine Transaktion, `.part` + `rename`, nie löschen bei Fehlern, Bericht mit `needsLogin` |
| `MD5.swift` | nur für die Moodle-Signatur |

`UniStore` ist quellenunabhängig; seit dem Zusammenführen mit der Mac-Sitzung (`wip/v1-pc`) steht der Teil für Kurse
und Dateien in `UniFlowCore/UniStore.swift` (`upsertCourse`, `storeFiles`, `markDownloaded` mit `content_sha256`), und
Stud.IP (S3) und Learnweb schreiben beide darüber.

**Für die Mac-Sitzung bleibt nur die dünne Schicht:**

1. `URLSessionUniTransport: UniTransport` in der App: eigene URLSession je (Nutzer, Uni) mit den Cookies aus
   `WKWebsiteDataStore(forIdentifier: DataContainerKey.websiteDataStoreID)` (der Container, `ContainerManager`); `followRedirects == false` über
   `urlSession(_:task:willPerformHTTPRedirection:...)` → `completionHandler(nil)`; `download` mit
   `URLSession.download(for:)` und Verschieben an `destination`; Kopfzeilen in `UniResponse` übernehmen.
2. Anmeldung (WKWebView mit diesem Datenspeicher):
   - LSF: `HildesheimCAS.lsfLoginURL` laden; fertig, wenn die Seite auf `lsf.uni-hildesheim.de` „Abmelden“ zeigt.
   - Learnweb bevorzugt mit Schlüssel: `MoodleSSO.publicConfig`, `MoodleSSO.newPassport()`, `MoodleSSO.launchURL(config:base:passport:)` laden,
     Weiterleitung auf `moodlemobile://…` in `decidePolicyFor` abfangen (`.cancel`), `MoodleSSO.parseLaunchToken(…, scheme:, siteURLs:)`
     → `LearnwebToken` in den Schlüsselbund (`DataContainerKey.keychainService`) unter
     `DataContainerKey.keychainAccount(service: "learnweb", field: "token")` (`<nutzer>.hildesheim.learnweb.token`).
     Erlaubt die Uni das Schema nicht, Sitzungs-Weg nutzen: `HildesheimCAS.learnwebLoginURL(base:)`.
3. Ablauf: Datenbank des Containers (`ActiveContainer.host`, `DataContainerLayout` mit `settings.university`)
   verwenden; `Learnweb.discoverBase(year:month:transport:)`;
   `HildesheimSync(db:container:learnweb:lsf:transport:)` (Inhalts-Hash im Kern, seit `wip/v1-pc-fix` ohne `hasher`), beim Öffnen
   der App und auf Knopfdruck `run()`; `report.needsLogin` → Anmeldung anbieten, `report.messages` in die Statusleiste.
4. Oberfläche: Uni-Auswahl im ersten Start, „Uni & Noten“ für Hildesheim, Dateien in Dokumente & Notizen (S3-Endpunkte
   lesen dieselben Tabellen; `files.local_path` ist **relativ** zum Container, Learnweb unter `Learnweb/files/…`,
   Stud.IP unter `StudIP/files/…`).
5. Gerätetest mit einem echten Hildesheimer Konto.

**Stand 26.10.2026 (Zweig `wip/v1-pc-hi`):** Punkte 1–4 gebaut und ohne Netz getestet (Abschnitt „Hildesheim in der
App“ unten). Punkt 5 ist offen: Gegen die echten Seiten der Uni wurde nichts aufgerufen.

## Fakten aus dem Live-Test (nicht neu herausfinden)

- **CAS**: Formularfelder `#username`, `#password`, Button `name=submit`. Fehlertext in `#loginErrorsPanel`.
  Gültige CAS-Sitzung leitet ohne Formular zurück.
- **Learnweb** `https://www.uni-hildesheim.de/learnweb2026`, Moodle mit aktivem Mobile-Webservice,
  Identitätsanbieter CAS, `typeoflogin` 1.
  - `core_course_get_contents` ist **per AJAX gesperrt** (`servicenotavailable`), nur mit Token (REST) nutzbar.
  - Kursnamen: `"SoSe 2026: 0406 Titel"` → Semester, Veranstaltungsnummer (wie im LSF), Titel.
  - Abschnitte heißen oft nur `"1"`, `"2"` → als `"Woche N"` speichern (Wochenerkennung im Lernplan).
  - Dateinamen kommen teils in **NFD** (`u` + U+0308). Immer **NFC** normalisieren, auch vor dem Hash der Datei-ID.
    Auf dem PC hat genau das den Sync abgebrochen.
  - Ohne Token zählt Moodle jeden Datei-Abruf als Aufruf (wie ein Klick im Browser). Mit Token nicht.
- **LSF** `https://lsf.uni-hildesheim.de/qisserver/rds`
  - Stundenplan-Seite `?state=wplan&act=show&show=plan&P.subc=plan&week=-2` enthält einen Link mit
    `moduleCall=iCalendarPlan&termine=<ids>`. Dieser ICS-Link braucht **keine Sitzung**.
  - **`DTSTART` ist der Semesterbeginn (Montag), der echte Wochentag steht nur in `BYDAY`** (auch mehrere Tage).
    Vorlesungsfreie Tage stehen als `EXDATE` (mehrere Zeilen, Komma-Listen, Liste endet mit Komma).
  - `SUMMARY` = `"0449 - Titel (Lehrperson)"`, Kommas als `\,`.
  - Veranstaltungsnummern wiederholen sich zwischen Semestern: Zuordnung zu Kursen nur über **Nummer und Semester**.
  - Notenspiegel: auf „Meine Funktionen“ direkt der Link „Studien-/Prüfungsleistungen (Notenspiegel)“, je
    Studiengang ein Reiter. Tabellenaufbau anders als LUH: **vor der Kopfzeile steht eine Zeile „Abschluss: …“**,
    Spalten `Prüfungsnr.` (mit Punkt) · `Bezeichnung der Leistung / der Lehrveranstaltung` · `Note` · `Status` · `Bonus`
    (= LP), mehrere Abschlüsse in einer Tabelle, Modulzeilen ohne Note/Status und Zeilen „Prüfung vorhanden“ sind
    keine Leistungen. Referenz: `qis.parse_grade_rows` und Test `test_grade_rows_hildesheim_layout`.
    `QISParser.grades` im UniFlowCore entsprechend prüfen und erweitern.
  - Live-Ergebnis 25.10.2026: 9 Learnweb-Kurse, 539 Dateien (517 PDF), 24 LSF-Stundenplan-Serien, 17 Leistungen.
    Die Seite zeigt auch Stammdaten (Name, Geburtsdatum, Anschrift, Matrikelnummer): **nie speichern oder loggen**,
    nur die Leistungstabelle.
  - **Nie** auf „Anmelden/abmelden“, „Jetzt anmelden“ oder Prüfungsanmeldung klicken: das ändert echte Belegungen.

## Anforderungen iPad

### 1. Hochschule wählen

- Beim ersten Start nach „Mit Apple anmelden“ und Tarifwahl: **Hochschule wählen** (LUH, Universität Hildesheim).
  Danach erst die Zugänge.
- Wechsel später nur in den Einstellungen, mit klarem Hinweis, dass die Daten der anderen Uni getrennt bleiben.
- Keine Uni-Erkennung aus E-Mail oder Namen raten.

### 2. Datentrennung (Pflicht, mit Tests)

- Schlüssel jedes Speichers ist **(Apple-Nutzer-ID, Hochschule)**. Für jede Kombination ein eigener Container:
  eigener SQLite-/Dokumentordner, eigenes `LocalJournal`, eigener `BlobStore`-Ordner.
- Keychain-Einträge mit Präfix pro Uni (`hildesheim.cas.user`, `hildesheim.learnweb.token`, `luh.studip…`),
  nie geteilt. Kein Rückfall von Hildesheim auf LUH-Zugangsdaten oder umgekehrt.
- Eigener `WKWebsiteDataStore` (Cookies) je Uni, z. B. `WKWebsiteDataStore(forIdentifier:)` mit einer UUID pro
  (Nutzer, Uni). Abmelden oder Uni-Konto löschen räumt genau diesen Store.
- Jeder Datensatz-Container speichert seine Uni. Passt sie beim Öffnen nicht, **nicht öffnen** (wie
  `UniversityMismatch` auf dem PC) und eine verständliche Meldung zeigen.
- Spätere Server-Anbindung (V2): Mandant pro Uni. Kein Endpunkt darf Daten über Uni-Grenzen liefern.
- Tests: zwei Unis nacheinander befüllen, gegenseitig nichts lesbar; Löschen eines Uni-Kontos lässt das andere unberührt.

### 3. Anmeldung

- CAS-Login im `WKWebView` mit dem Uni-eigenen Website-Datenspeicher. Die Studierenden tippen die Zugangsdaten
  selbst ein; die App speichert das Passwort nicht, es sei denn, sie wählen „merken“ (dann nur Keychain, pro Uni).
- **Entscheidung des Inhabers (25.10.2026):** Nach der Registrierung wählt man LUH oder Hildesheim; die App öffnet die
  Anmeldeseiten dieser Uni (LUH: Stud.IP, QIS; Hildesheim: CAS für Learnweb und LSF) und merkt sich Benutzername und
  Passwort (Schalter „Auf diesem iPad merken“, Standard an). **Nur vorausfüllen:** „Anmelden“ tippt immer der Mensch;
  automatisches Anmelden gibt es bewusst nicht. Einzelheiten und Risiken: `docs/SICHERHEITSKONZEPT-KONTEN.md` 1a.
- **Learnweb-Token bevorzugen**, in dieser Reihenfolge prüfen:
  1. Moodle-SSO-Start `…/admin/tool/mobile/launch.php?service=moodle_mobile_app&passport=<zufall>&urlscheme=<schema>`
     im `WKWebView`; die abschließende Weiterleitung auf `<schema>://token=<base64>` in
     `decidePolicyFor navigationAction` abfangen (nicht an das System geben). Inhalt `siteid:::token[:::privatetoken]`,
     `passport` per MD5 prüfen. **Erst prüfen, ob die Uni das Schema erlaubt** (`tool_mobile_get_public_config`
     → `launchurl`, Einstellung `forcedurlscheme`, Standard `moodlemobile`).
  2. Sonst: Studierende fügen einen selbst erzeugten Schlüssel ein (Profil → Einstellungen → Sicherheitsschlüssel).
  3. Sonst: AJAX mit der Cookie-Sitzung wie auf dem PC (`SessionClient`), mit Hinweis auf die Aufrufzählung.
- Token nie loggen, nie in URLs; erst beim Download mitschicken. Auf dem iPad im POST-Körper an die eigene
  Pluginfile-Adresse (`LearnwebAPI.downloadRequest`), nicht wie `with_token` am PC an die Adresse.

### 4. Sync

- Reihenfolge: Learnweb, danach LSF-Stundenplan, Noten höchstens alle 20 Stunden (wie PC).
- Learnweb: Kurse → je Kurs Dateiliste → nur neue oder geänderte Dateien laden. Geändert = höheres
  `timemodified` (Token) bzw. höhere Pluginfile-Revision (Sitzung). Datei-ID `lw-<cmid>-<sha256(filepath+filename)[:8]>`
  nach NFC, identisch zum PC (siehe Fixtures).
- LSF: iCal-Link aus der Stundenplan-Seite lesen, ICS laden, Serien mit Quelle `lsf` abgleichen: neue anlegen,
  verschwundene entfernen, bestehende samt Nutzer-Ausnahmen behalten; `EXDATE` als Ausfall eintragen.

### 5. Ausfallsicher

- Jede Quelle und **jeder Kurs** in einer eigenen Transaktion; ein Fehler wird protokolliert, der Rest läuft weiter.
- Netzwerkfehler und Zeitüberschreitungen: wiederholen mit Backoff (z. B. 3 Versuche), danach Kurs überspringen.
- **Nie lokale Daten löschen, weil die Gegenseite gerade nicht antwortet** oder eine leere Liste liefert; Entfernen
  nur nach erfolgreicher, vollständiger Antwort (LSF-Serien) und nie bei Dateien mit Notizen.
- Kommt statt einer Datei eine HTML-Seite (abgelaufene Sitzung), nicht speichern: neu anmelden, dann erneut versuchen.
- Abgelaufene CAS-Sitzung erkennen (Weiterleitung auf `/sso/login`) und den Login im WebView anbieten,
  ohne den Sync-Stand zu verlieren.
- Offline: letzter Stand bleibt nutzbar; Status je Quelle anzeigen („Learnweb: 16:30 ok“, „LSF: Anmeldung nötig“).
- Protokollzeilen nur ASCII-sicher bzw. UTF-8; Sonderzeichen dürfen nie einen Absturz auslösen.

### 5a. Gemeinsame Wochentests (Vorgabe des Inhabers)

- Gleiche Vorlesung und gleiche Übung ergeben denselben Wochentest. Schlüssel wie `app/testshare.py`:
  Uni, Dauer-Stufe, sortierte SHA-256-Hashes des Dateiinhalts, Version `wt1`. Erwartungswerte:
  `packages/shared-contracts/fixtures/testshare/cases.json`. Konzept: `docs/GEMEINSAME-WOCHENTESTS.md`.
- Hash beim Download berechnen und speichern; vorhandenen Test mit gleichem Schlüssel wiederverwenden.

### 6. Abnahme

- `swift test` in UniFlowCore: Fixtures aus `packages/shared-contracts/fixtures/hildesheim/` ergeben genau
  `expected.json` (Kurstitel, Learnweb-Dateien inkl. NFC-Name und Ordner, LSF-Serien mit Wochentag und EXDATE).
- Tests für Datentrennung (Abschnitt 2) und Ausfallsicherheit (ein Kurs wirft, andere werden gespeichert;
  leere Antwort löscht nichts).
- Im Simulator: Uni wählen → CAS-Login → Kurse und Dateien sichtbar → Stundenplan mit Donnerstags-Kurs am
  Donnerstag und Ausfall an Heiligabend → Notenspiegel (leer ist ok).
- `WEB-IPAD-PARITAET.md`/`docs/paritaet/status.json` um die Hildesheim-Punkte ergänzen.

## Stand iPad (26.10.2026, Zweig `wip/hochschulen-2` ab `develop` 2706e52)

Grundlagen gebaut, **noch nicht** in Start, Speicher und Sync eingebunden (das folgt nach der S3–S5-Integration).
Gegen echte Uni-Seiten wurde nichts geprüft (keine Anmeldung, keine Abfrage); alle Tests laufen mit erfundenen
Fixtures und lokalen HTML-Seiten.

| Teil | Datei(en) | Stand |
|---|---|---|
| Hochschul-Profile wie `universities.py` (Schlüssel, Namen, Dienste, Anmelde-/Datenadressen, Keychain-Präfix, erlaubte Anmeldeseiten) | `UniFlowCore/Universities/UniversityProfile.swift` | gebaut, Kern-Tests grün |
| CAS: Login-URL mit service, Anmeldeseite/abgelaufene Sitzung (`/sso/login`), Formular `#username`/`#password`/`name=submit`, Fehlertext `#loginErrorsPanel`, Erfolg = Rücksprung zur service-URL | seit `wip/v1-pc-uni` in `Hildesheim/HildesheimCAS.swift` (früher `Universities/CASLogin.swift`) | gebaut, Kern-Tests grün |
| Learnweb: Kurse, Dateilisten (REST mit Schlüssel, AJAX mit Sitzung als Rückfall), Kurstitel → Semester/Nr./Titel, „Woche N“, NFC, Datei-ID wie PC, Änderung = höheres `timemodified`/Revision, HTML statt Datei = Sitzung abgelaufen, 3 Versuche mit Backoff, Fehler je Kurs überspringt nur diesen Kurs (auch 429/5xx einer Ressourcen- oder Ordnerseite nach allen Versuchen: Kurs in `failures`, nie still eine kürzere Liste; 403/404 bleiben wie am PC leer), Abbruch = `cancelled` + `notAttempted` statt Kursfehler, `needsDownload` lädt wie `store_course_files` auch ohne lokale Kopie (`present`), Netz über `LearnwebTransport` | seit `wip/v1-pc-uni` in `Hildesheim/Learnweb.swift`, `LearnwebAPI.swift`, `HildesheimSync.swift` (früher `Universities/LearnwebParsing.swift`, `LearnwebClient.swift`, `InsecureHash.swift`; Datei-ID jetzt SHA-256 wie Python, SHA-1 entfällt) | gebaut; `learnweb-course-contents.json` ergibt genau `expected.json` (inkl. NFC-Name, Ordner) |
| Moodle-SSO: `tool_mobile_get_public_config` (launchurl, forcedurlscheme, Standard `moodlemobile`), Start-URL mit zufälligem passport, Antwort `<schema>://token=<base64>` zerlegen, passport per MD5 prüfen | `Hildesheim/MoodleSSO.swift` | Kern gebaut und getestet; seit `wip/v1-pc-hi` fängt die App die Antwort in `decidePolicyFor` ab (`HildesheimLogin.intercept`) |
| Token nur beim Download: im POST-Körper an die eigene Pluginfile-Adresse (nie in der Adresse, nie an fremde Rechner) | `LearnwebAPI.downloadRequest` | **Abweichung vom PC** (`?token=`); dass Moodle den Token im Körper annimmt (`required_param` liest POST), ist gegen das echte Learnweb ungeprüft |
| Notenspiegel Hildesheim wie `qis.parse_grade_rows` (Abschluss-Zeile, Kopfzeile irgendwo, `Prüfungsnr.`, Bonus = LP, Modulzeilen/„Prüfung vorhanden“ keine Leistung); LUH unverändert | seit `wip/v1-pc-uni` `Hildesheim/GradeRows.swift` (früher zusätzlich `Universities/QISHildesheim.swift`), `QISCollector.absorb(…, layout:)` | gebaut, Kern-Tests grün. Keine Bescheinigungs-Links für Hildesheim (`collectsDocuments`/`qisDocuments` wie `qis.PROFILES["hildesheim"]["documents"] = False`). Steht eine Stammdaten-Zeile in derselben Tabelle wie die Leistungen, wird die ganze Tabelle verworfen (Stammdaten nie lesen) – dann bleibt der Notenspiegel leer; beim ersten echten Test prüfen |
| Zugangsdaten je Hochschule im Schlüsselbund (`luh.studip.*`, `luh.qis.*`, `hildesheim.cas.*`), `WhenUnlockedThisDeviceOnly`, nicht synchronisiert, kein Rückfall auf die andere Uni (LUH-QIS füllt ohne eigene Daten die LUH-ID aus Stud.IP vor, wie `service_credentials` am PC), Löschen je Uni, Neuinstallation leert den Dienst | `UniFlow/Services/UniversityCredentials.swift` | gebaut, App-Tests grün; Konto löschen räumt alle Unis, Stud.IP abmelden alle LUH-Einträge, Uni-Wechsel nur als Schnittstelle |
| Anmeldeseite merkt sich Benutzername und Passwort, füllt beim nächsten Mal vor, schickt nie ab | `UniFlow/Services/UniversityLoginAutofill.swift`, `Views/UniversityLoginViews.swift`, Einbau in `StudIPLoginView` | gebaut; WKWebView-Tests mit lokalen Seiten grün (nur mit Zustimmung, nur erlaubter Host/Pfad, nur das Dokument der letzten echten Navigation – `history.replaceState` einer Seite desselben Rechners hilft nicht –, Skript weg nach Verlassen der Anmeldeseiten, Vorausfüllen ohne Absenden, Löschen je Uni, andere Uni sieht nichts). In der App bisher nur die Stud.IP-Anmeldung angebunden; Oberfläche im Simulator nicht angesehen (öffnet die echte Stud.IP-Seite) |

### Hochschulwahl und Datentrennung (26.10.2026, Zweig `wip/hochschulwahl` ab der Integration S3–S5)

| Teil | Datei(en) | Stand |
|---|---|---|
| Erster Start: Mit Apple anmelden → Tarifwahl → **Hochschule wählen** (LUH, Universität Hildesheim; nichts vorausgewählt, keine Erkennung aus E-Mail oder Name) → Oberfläche. Wahl je Apple-Nutzer (UserDefaults mit Kurzkennung, nie die Apple-ID). Debug: `-UFUniversity luh\|hildesheim`, `-UFOnboarding university`; `-UFOnboarding skip` wählt ohne `-UFUniversity` die LUH | `Services/AccountStore.swift`, `Views/Onboarding/UniversityPickerView.swift`, `OnboardingFlow.swift`, `Session.swift` (`DebugLaunch`) | gebaut, App-Tests grün |
| Wechsel nur in den Einstellungen (Karte „Hochschule“): Hinweis, dass die Daten der anderen Uni getrennt bleiben (auch gemerkte Zugangsdaten und Anmeldungen); danach sofort der Speicher der neuen Uni ohne Neustart (Oberfläche baut sich neu auf, Objekte halten ihren Container fest). „Daten dieser Hochschule löschen“ | `Views/Settings/UniversitySettings.swift`, `SettingsPage.swift` | gebaut, App-Tests grün (Logik); im Simulator angesehen und bedient (Debug-Konto): Hochschulwahl ohne Vorauswahl, Hildesheim gewählt → Übersicht ohne Karte „Stud.IP verbinden“, Einstellungen mit Karte „Hochschule“ und „Learnweb & LSF – folgt“, Wechsel Hildesheim → LUH ohne Neustart (danach Stud.IP-Karte der LUH). „Daten dieser Hochschule löschen“ und „Konto löschen“ nur in App-Tests, nicht im Simulator gedrückt. Offen: Die Übersicht (S6, nicht angefasst) zeigt auch in Hildesheim die Überschrift „Neu aus Stud.IP“ |
| Container je (Apple-Nutzer, Hochschule): feste UUID aus SHA-256 von Nutzer und Uni, Ordner `Application Support/UniFlowContainers/<uuid>/` mit Datenbank (`settings.university` = Uni des Containers, `UniversityMismatch` → nicht öffnen, Meldung mit Hochschulnamen), Journal, PDF-Zwischenspeicher, Vorschaubilder, Antwort-Zwischenspeicher, Lösungs-Bibliothek, eigene Dokumente und Bilder, `StudIP/` (später `Learnweb/`); `container.json` mit Uni und Nutzer-Kurzkennung, Abweichung → nicht öffnen. Pfade in `files.local_path` relativ zum Container | UniFlowCore `Containers/DataContainer.swift`, App `Services/DataContainers.swift`, `LocalBackendHost.swift` | gebaut, Kern- und App-Tests grün |
| Je Container eigene UserDefaults-Suite (Stud.IP-Kursauswahl, letzter Abgleich), eigenes Stud.IP-Sitzungs-Cookie (`de.uniflow.ai.studip` / `session-cookies.<uuid>`), gemerkte Zugangsdaten mit Nutzer-Präfix (`<nutzer>.luh.studip.user`; der Speicher eines Containers liest und schreibt nur seine Uni), eigener `WKWebsiteDataStore(forIdentifier: <uuid>)` für alle Anmelde-Webansichten (statt `.default()`). `/api/services` liefert die Dienste der Uni der Datenbank | `StudIPSync.swift`, `UniversityCredentials.swift`, `StudIPView.swift`, `PendingServicesEndpoints.swift` | gebaut, App-Tests grün (Schlüsselbund und Cookies im Simulator) |
| Abmelden (Stud.IP) räumt Sitzung und Webdaten genau dieses Containers; „Daten dieser Hochschule löschen“ den ganzen Container samt Webdaten-Speicher, Cookie, Zugangsdaten und Einstellungen (die andere Uni bleibt); **Konto löschen** alle Container des Nutzers (beide Unis) | `DataContainers.swift` (`deleteUniversityData`, `deleteAllData`) | gebaut, App-Tests grün |
| Umzug: Daten ohne Container (bisher alles LUH) ziehen beim ersten Start mit dieser Version in den LUH-Container des angemeldeten Nutzers (verschoben, nicht kopiert; `UniFlow` als Ganzes umbenannt, dann `StudIP`), Pfade in der Datenbank umgeschrieben, Notizen und Journale unverändert, Kursauswahl/Cookie/Zugangsdaten mit; Ziel steht vor dem ersten Schritt fest (`legacy-move.json`), „done“ erst nach Abschluss, Neustart setzt beim selben Ziel fort; danach ist die Uni LUH ohne erneute Abfrage. Scheitert der Umzug, bleibt der LUH-Container zu (Meldung, nichts gelöscht) | UniFlowCore `Containers/LegacyDataMigration.swift`, `DataContainers.swift` | gebaut, Kern-Tests (auch Abbruch nach jedem Schritt und Dateisystemfehler) und App-Tests grün |
| Universität Hildesheim in der Oberfläche: keine Karte „Stud.IP verbinden“, Sync-Knopf und Einstellungen sagen ehrlich, dass Learnweb und LSF folgen | `ConnectStudIPCard.swift`, `AppShell.swift`, `UniversitySettings.swift` | gebaut, App-Tests grün; seit `wip/v1-pc-hi` ersetzt durch die Karten „Learnweb verbinden“/„LSF verbinden“ und den echten Abgleich (unten) |

### Hochschulen entdoppelt (26.10.2026, Zweig `wip/v1-pc-uni` ab `wip/v1-pc`)

Die Hochschul-Grundlagen und die Hochschulwahl der Mac-Sitzung sind mit dem Hildesheim-Kern der PC-Sitzung
zusammengeführt. Zu jeder Aufgabe gibt es genau eine Fassung; wo die PC-Fassung gleichwertig war, blieb sie, und was
ihr fehlte, kam hinein. Alle Tests beider Seiten laufen gegen die verbleibende Fassung.

| Aufgabe | eine Fassung | entfernt | aus der Mac-Fassung übernommen |
| --- | --- | --- | --- |
| Learnweb lesen | `Learnweb` (Parser), `LearnwebAPI` (REST/AJAX über `UniTransport`), Ablauf in `HildesheimSync` | `LearnwebParsing`, `LearnwebClient`, `LearnwebTransport`, `LearnwebRetry`, `LearnwebError`, `LearnwebSnapshot` | `LearnwebToken` (geschwärzt, nur alphanumerisch), Schlüssel nur im POST-Körper und nur an den eigenen Rechner über HTTPS, sesskey nur von angemeldeten Seiten (`notloggedin`), Webseite statt JSON = Sitzung abgelaufen, Moodle-Fehler-JSON statt Datei (`invalidtoken`) wird nie gespeichert, Abbruch = `cancelled` + `notAttempted` statt Kursfehler, abgelaufene Anmeldung beendet den Learnweb-Teil, Meldungen ohne Abfrage/sesskey, `module_name`, MIME-Tabelle, `unquote`/`urlparse` wie Python |
| CAS | `HildesheimCAS` | `CASLogin`; seit `wip/v1-pc-fix` auch Formular, Rücksprung und Stand nach dem Laden (ohne Aufrufer) | Selektoren, Fehlertext |
| Moodle-SSO | `MoodleSSO` (`Hildesheim/MoodleSSO.swift`) | zweite `MoodleSSO`-Fassung | `MoodlePublicConfig` (launchurl, forcedurlscheme), Start aus der Konfiguration, Schema-Prüfung, http/https und „/“ bei der Signatur, Ergebnis `LearnwebToken`; `Learnweb.publicSitename` nutzt dieselbe Abfrage |
| MD5 | `MD5` | `InsecureHash` (MD5 und SHA-1) | Testvektoren |
| Notenspiegel | `GradeRows.parse` → `QISGrade`, gesammelt nur über `LSFClient.grades` | `QISParser.parseGradeRows`, zweite Kopfzeilen-Tabelle, `GradeRows.Grade`; seit `wip/v1-pc-fix` auch `QISPage.grades(layout:)`, `gradeTableCount(layout:)` und `QISCollector.absorb(layout:)` (zweiter Weg ohne Aufrufer; `QISPage`/`QISCollector` sind der Weg des QIS der LUH) | Stammdaten-Zeilen werden übersprungen, `QISGradeLayout` (Profil) |
| Hochschul-Profile | `UniversityProfile`/`UniversityKey` (auch für `HildesheimCAS.casBase`/`lsfBase`, `LocalSettings.knownUniversities`, `Migrations.defaultUniversity`, `/api/services` beider Unis) | `UniversityStorage.known`, zweite LUH-Dienste-Liste in `PendingServicesEndpoints` | – |
| Speicherorte | `DataContainerKey`/`DataContainerLayout` (Ordner, `websiteDataStoreID`, `keychainService`, `keychainAccount(service:field:)`), App `ContainerManager` | `UniversityStorage` (containerPath, keychainService, websiteDataStoreID) | Learnweb-Schlüssel `<nutzer>.hildesheim.learnweb.token` (`tokenServices`); Schlüsselbund-Namen der App über `UniversityProfile.keychainAccount(…, userScope:)` |
| Webseite statt Datei | `UniStore.isWebPage`/`startsLikeWebPage` (Stud.IP und Learnweb, auch mit UTF-8-BOM) | `looksLikeHTML` | BOM |

`HildesheimSync` schreibt in denselben Container wie der Stud.IP-Abgleich (`HildesheimSync(db:container:…)`, Dateien
unter `Learnweb/files/…`, Zwischenstand in `Learnweb/.laden`) und gleicht nur ab, wenn Container (Kennzeichnung, Konto)
und Datenbank (`settings.university`) zur Uni Hildesheim gehören; sonst `refused` mit der Meldung von
`UniversityMismatch` bzw. `DataContainerError`, ohne Anfrage an die Uni und ohne Schreiben.

Damals noch nicht gebaut, seit `wip/v1-pc-hi` in der App (nächster Abschnitt): LSF-ICS-Auswertung in der App,
Learnweb-Abgleich in die Datenbank, CAS-/Learnweb-/LSF-Anmeldeansichten (mit dem Datenspeicher des Containers), Abfangen
der Moodle-SSO-Antwort im WebView, Speichern des Learnweb-Schlüssels (`<nutzer>.hildesheim.learnweb.token`).

### Hildesheim in der App (26.10.2026, Zweig `wip/v1-pc-hi` ab `wip/v1-pc-uni`)

Die dünne Schicht über dem Kern (Punkte 1–4 oben). Abgleich, Regeln, Speichern und Ausfallsicherheit bleiben im Kern
(`HildesheimSync`, `LearnwebAPI`, `LSFClient`, `MoodleSSO`, `HildesheimCAS`, `UniStore`); die App hat keine zweite
Fassung davon. Gegen die echten Seiten der Uni wurde nichts aufgerufen und nichts angemeldet: alle Tests laufen mit
`URLProtocol`-Stub, lokalen HTML-Seiten und erfundenen Daten.

| Teil | Datei(en) | Stand |
| --- | --- | --- |
| `URLSessionUniTransport: UniTransport`: je Lauf eine eigene, flüchtige URLSession mit den Cookies aus `WKWebsiteDataStore(forIdentifier: DataContainerKey.websiteDataStoreID)` des Containers; Cookies setzt der Transport selbst je Ziel (auch bei Weiterleitungen, nie fremde), Set-Cookie der Antworten bleibt im Lauf; `followRedirects == false` über `willPerformHTTPRedirection` → `nil` (Location-Header in `UniResponse`); Download mit `URLSession.download(for:)` und Verschieben an `destination`; nur HTTPS auf `*.uni-hildesheim.de` (aus dem Profil), Weiterleitungen anderswohin werden nicht verfolgt, ein Formular-Körper (Learnweb-Schlüssel) geht nie an einen anderen Rechner; Meldungen ohne Adresse | `UniFlow/Services/UniTransportSession.swift` | gebaut, App-Tests grün (Stub: Weiterleitung aus/an, Cookies je Container und je Rechner, Download in Datei, fremde Rechner/http/Port abgelehnt) |
| Inhalts-Hash: seit `wip/v1-pc-fix` nur `TestShare.contentHash(file:)` im Kern (auf Apple-Geräten mit CryptoKit), für Stud.IP und Learnweb über `UniDownloads`; `UniFileHash` der App entfernt | Kern `TestShare.swift`, `UniDownloads.swift` | gebaut, Kern-Test vergleicht mit `SolutionSHA256` (bis 2,5 MB, über Blockgrenzen) |
| Anmeldung (`HildesheimLogin`, `HildesheimLoginView`) in der Webansicht des Containers mit Vorausfüllen (`UniversityLoginAutofill`, Dienst `cas`; nie absenden): LSF über `HildesheimCAS.lsfLoginURL`, fertig auf einer angemeldeten LSF-Seite (`LSFClient.isLoggedIn`, dieselbe Regel wie im Abgleich); Learnweb: `Learnweb.discoverBase`, `MoodleSSO.publicConfig`, `newPassport`, `launchURL(config:base:passport:)`, die Weiterleitung `<schema>://token=…` fängt `decidePolicyFor` ab (`.cancel`, alles außer http(s)/about geht nie an das System), `parseLaunchToken(…, scheme:, siteURLs:)`, Schlüssel in den Schlüsselbund (`DataContainerKey.keychainService`, Eintrag aus `UniversityProfile.keychainAccount`: `<nutzer>.hildesheim.learnweb.token`); ohne SSO (Schema nicht erlaubt, Mobile-Webservice aus) der Sitzungsweg `HildesheimCAS.learnwebLoginURL(base:)`, fertig auf einer angemeldeten Learnweb-Seite (`Learnweb.isLoggedIn`); Fehlertext des CAS (`#loginErrorsPanel`) unter der Webansicht | `Services/HildesheimConnection.swift`, `Views/HildesheimViews.swift`, `StudIPView.swift` (`StudIPWebView` mit `interceptNavigation`, eine Webansicht für alle Anmeldungen), `UniversityCredentials.swift` (`token`/`saveToken`/`deleteToken`) | gebaut; App-Test mit echter WKWebView und lokaler Seite (Inhaltsregel sperrt jedes Nachladen): Schlüssel abgefangen und gespeichert, falscher Passport abgelehnt, zweite Antwort nicht angenommen, `mailto:` nie weitergegeben; Sitzungsweg und LSF-Erkennung über `pageLoaded`. Die echten Seiten (CAS, launch.php) im Simulator nicht geöffnet |
| Ablauf (`HildesheimConnection`, je Hildesheimer Container eine, `ContainerManager.hildesheim`): Datenbank des Containers (`LocalBackendHost`, `migrate(university: "hildesheim")`); Learnweb-Instanz über `Learnweb.discoverBase` (nicht erreichbar: die beim Verbinden gemerkte); Schlüssel nur für die Instanz, bei der er geholt wurde (learnweb2027 → neu verbinden, kein Schlüssel an die neue Instanz); `HildesheimSync(db:container:learnweb:lsf:transport:clock:retry:)` beim Öffnen der App (höchstens alle 30 Minuten) und auf Knopfdruck, Noten höchstens alle 20 Stunden („Noten abrufen“ sofort); Stand je Quelle aus `report.needsLogin` und neu `report.completed` (Kern), `report.messages` in der Statusleiste; Stand und Meldungen in der UserDefaults-Suite des Containers; „Abmelden“ löscht Schlüssel, Verbindungen, Webdaten und gemerkte Zugangsdaten der Uni Hildesheim, Dateien/Stundenplan/Noten bleiben | `HildesheimConnection.swift`, `DataContainers.swift`, `UniFlowApp.swift` | gebaut, App-Tests grün |
| Oberfläche: statt „Stud.IP verbinden“ die Karten „Learnweb verbinden“/„LSF verbinden“ (bzw. „…-Anmeldung abgelaufen“), danach die Statusleiste („Learnweb: 10:00 ok“, „LSF: Anmeldung nötig“, Meldungen, „Jetzt abgleichen“/„Erneut versuchen“) oberhalb der Seiten und auf der Übersicht (über `ConnectStudIPCard`, `StudIPLink.otherSources`; die Übersicht selbst ist nicht angefasst); Sync-Knopf der Kopfzeile gleicht Learnweb/LSF ab; Seiten laden nach jedem Abgleich neu (`ufReload`); Einstellungen und „Uni & Noten“ mit der Karte „Learnweb & LSF“; Dateien in Dokumente & Notizen und Module über die S3/S4-Endpunkte (`files.local_path` = `Learnweb/files/…` relativ zum Container); Stundenplan mit den LSF-Serien; „Uni & Noten“ lokal mit dem Hildesheimer Notenspiegel (nur die Leistungstabelle; `GET /api/grades` ist jetzt der Port von `qis.summary` über `QISParser.summary`, `GradesEndpoints`); Hochschulwahl beschreibt Learnweb und LSF statt „folgen“. LUH unverändert (Stud.IP-Karte, „Uni & Noten“ lokal leer, QIS folgt) | `ConnectStudIPCard.swift`, `HildesheimViews.swift`, `AppShell.swift`, `UFKit.swift`, `SettingsPage.swift`, `ServicesPage.swift`, `UniversityPickerView.swift`; Kern `LocalBackend/Endpoints/GradesEndpoints.swift` | gebaut, App-Test: Hildesheim gewählt → Abgleich über den Transport mit Stub → Dokumente (Bibliothek, Datei-Inhalt, Kurs, Modul, Inhalts-Hash), Stundenplan (Donnerstags-Kurs am Donnerstag, nicht am Montag aus DTSTART, Ausfall an Heiligabend), Noten (2 Leistungen, keine Stammdaten), zweiter Lauf ohne Downloads und ohne Notenabruf; danach LUH: nichts aus Hildesheim, Stud.IP-Karte. Oberfläche im Simulator angesehen (siehe `docs/STAND-MAC-SITZUNG.md`), Anmeldeseiten nicht geöffnet |
| Noten nicht doppelt: `UniStore.storeGrades` vergleicht NULL-sicher (Hildesheim hat weder Semester noch Versuch; mit `ON CONFLICT` legte jeder Abruf alle Leistungen neu an). Derselbe Fehler war am PC; `app/qis.py` hat jetzt `store_grades` mit derselben Regel | Kern `HildesheimSync.swift`, `app/qis.py` | gebaut, Kern-Test, Python-Test `test_store_grades_updates_rows_without_semester` (mit der alten Speicherung rot) |

Offen: Gerätetest mit einem echten Konto (Punkt 5), insbesondere ob die Uni das Schema `moodlemobile` erlaubt und ob
Moodle den Schlüssel im POST-Körper an `webservice/pluginfile.php` annimmt; Cookies, die die Uni während eines
Abgleichs neu setzt, gehen nicht in den Datenspeicher der Webansicht zurück (nach Ablauf meldet die App „Anmeldung
nötig“, eine gültige CAS-Sitzung meldet dann ohne Passwort an).

### Zusammenführen nachgebessert (26.10.2026, Zweig `wip/v1-pc-fix` ab `wip/v1-pc-hi`)

Gegenlese-Punkte zu `wip/v1-pc-hi`; jede Regel steht an genau einer Stelle, neue Regeln zuerst in Python, dann im Kern.
Alles ohne Netz geprüft (Stub-Transporte, lokale Server, erfundene Daten); jeder neue Test ist ohne die Korrektur rot.

| Punkt | eine Fassung | entfernt / geändert | Tests |
| --- | --- | --- | --- |
| Inhalts-Hash | `TestShare.contentHash(file:)` (Kern; CryptoKit auf Apple-Geräten, sonst `SolutionSHA256`) | `UniFileHash` (App), `hasher` von `HildesheimSync` | `UniStoreTests` (CryptoKit = `SolutionSHA256`, bis 2,5 MB) |
| Datei in den Container laden und eintragen | `UniDownloads` (Kern): Zwischenordner `.laden` (vor dem Lauf geleert, danach entfernt), keine leere Antwort, Container noch gekennzeichnet, `rename`, Dateischutz, Hash, `UniStore.markDownloaded` | eigener Ablauf in `StudIPSync` (`place`, eigener Zwischenordner) und in `HildesheimSync.download`; `URLSessionStudIPTransport` ist nur noch eine Übersetzung auf `URLSessionUniTransport` (eine URLSession-Umsetzung, Cookies je Ziel, nur HTTPS auf Stud.IP und den LUH-Anmeldeseiten) | Kern `HildesheimSyncTests`, `LearnwebTests`; App `LocalDocumentsAppTests`, `TimetableLocalAppTests` |
| Leere Antwort (HTTP 200, 0 Bytes) | `empty_download` (Python, `stream_download`/`download`), `UniDownloads.load` (Kern): Fehler der Datei, wenn die Quelle eine Größe meldet oder es schon eine Fassung gibt; alte Datei bleibt, Datei gilt weiter als geändert | – | `test_empty_answer_*` (Python), `testEmptyDownloadNeverReplacesAGoodFile` (Kern) |
| LSF-Kalender ohne Termin | `lsf.fetch_plan_ics` (Python), `LSFClient.planEntries` (Kern): bei vorhandenem Export-Link ein Fehler, nichts importiert, keine Serie entfernt; leerer Plan = kein Export-Link | – | `test_lsf_calendar_without_events_removes_nothing`, `testCalendarWithoutEventsRemovesNoSeries` |
| LSF angemeldet | `LSFClient.isLoggedIn(html:url:)` (Abgleich und Anmeldung in der App) | eigene Regel in `HildesheimLogin.pageLoaded`; `HildesheimCAS.state/form/returnedToService` | `UniversityProfileTests`, `HildesheimAppTests` |
| Hildesheimer Notenspiegel | `LSFClient.grades` | `QISPage.grades(layout:)`, `gradeTableCount(layout:)`, `QISCollector.absorb(layout:)` | `QISHildesheimTests` auf `LSFClient.grades` umgezogen |
| Beschreibungen von Anfragen | `UniRequest` (description, debugDescription, Mirror): Methode und Adresse ohne Abfrage, kein Körper | – | `LearnwebTests` (sesskey, Schlüssel) |
| Löschen während eines Abgleichs | `ContainerManager.remove` hält die Abgleiche des Containers an (`stop`, auch abgelöste nach einem Wechsel) und wartet, löscht danach und prüft noch einmal; `UniDownloads`/`HildesheimSync` schreiben nur in einen gekennzeichneten Container (`DataContainerLayout.verifyPresent`); Löschknöpfe gesperrt, solange ein Abgleich läuft | – | `testDeletingDuringARunningSyncLeavesNothingBehind` (Hochschule, Konto, LUH), `testDeletedContainerIsNeverRecreated` (Kern) |
| Zweite Quelle während eines Laufs verbunden | `HildesheimConnection`: der Lauf bewertet nur die Quellen, die zu Beginn verbunden waren; die neue bleibt „verbunden“ und bekommt direkt danach einen eigenen Lauf | – | `testSourceConnectedDuringARunGetsItsOwnRunInsteadOfAnError` |
| Anzeigename beim Teilen | `SolutionDisplayName` in der Einstellungs-Suite des Containers; Umzug nimmt ihn mit, Löschen entfernt ihn | `@AppStorage` in `UserDefaults.standard` | `testSolutionDisplayNameStaysWithItsContainer`, Umzugs-Test |

## Regeln

- Nur `develop`, kein Merge nach `main`, kein Release. Commits mit `[skip ci]`, solange die GitHub-Abrechnung offen ist.
- Keine echten Zugangsdaten in Code, Tests, Fixtures oder Logs. Passwörter tippt nur der Mensch selbst (danach füllt
  die App sie auf Wunsch nur vor; „Anmelden“ tippt immer der Mensch).
- Keine Stammdaten (Name, Geburtsdatum, Anschrift, Matrikelnummer) speichern oder committen.
- Fragen an den Inhaber, nicht raten: insbesondere ob das Moodle-SSO-Schema erlaubt ist, wenn es im Test scheitert.
