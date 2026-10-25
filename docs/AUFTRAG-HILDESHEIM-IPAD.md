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
| `Learnweb.swift` | Kurstitel, Abschnitt → „Woche N“, Datei-ID (SHA-256), REST-Dateiliste, Sitzungs-Dateiliste, Pluginfile-Links, Ordnerseiten, Token anhängen, **Instanz des Semesters** (`discoverBase`, jährlicher Wechsel learnweb2026 → 2027) |
| `HildesheimCAS.swift` | CAS-Login-Adressen für LSF und Learnweb, Erkennung der Loginseite |
| `LSFCalendar.swift` | ICS-Parser mit BYDAY und EXDATE, LSF-Titel „0449 - Titel (Lehrperson)“, iCal-Link aus der Stundenplan-Seite |
| `GradeRows.swift` | Notenspiegel-Zeilen im Hildesheimer Aufbau (Kopfzeile irgendwo, mehrere Abschlüsse, Modulzeilen weg) |
| `TestShare.swift` | Schlüssel der gemeinsamen Wochentests, Inhalts-Hash |
| `Store/Migrations.swift` | `tests.share_key`, `files.content_sha256`, Index wie `app/db.py` |

**Für die Mac-Sitzung bleibt:** CAS-Anmeldung im `WKWebView` mit eigenem Datenspeicher je (Nutzer, Uni);
Learnweb-Zugriff (Moodle-SSO-Token zuerst prüfen, sonst Schlüssel einfügen, sonst AJAX mit Cookies); LSF-Seiten mit
den Cookies laden und an die Parser geben; Sync-Ablauf mit Wiederholungen und je Kurs eigener Transaktion;
Speicher je (Nutzer, Uni); Uni-Auswahl im ersten Start; Oberfläche „Uni & Noten“ für Hildesheim; Gerätetest.
Die Sitzungs-Dateiliste braucht pro Material-Link die Weiterleitung von `mod/resource/view.php?id=…&redirect=1`
(ohne ihr zu folgen: Location-Header lesen) bzw. das HTML der Ordnerseite.

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
- **Learnweb-Token bevorzugen**, in dieser Reihenfolge prüfen:
  1. Moodle-SSO-Start `…/admin/tool/mobile/launch.php?service=moodle_mobile_app&passport=<zufall>&urlscheme=<schema>`
     im `WKWebView`; die abschließende Weiterleitung auf `<schema>://token=<base64>` in
     `decidePolicyFor navigationAction` abfangen (nicht an das System geben). Inhalt `siteid:::token[:::privatetoken]`,
     `passport` per MD5 prüfen. **Erst prüfen, ob die Uni das Schema erlaubt** (`tool_mobile_get_public_config`
     → `launchurl`, Einstellung `forcedurlscheme`, Standard `moodlemobile`).
  2. Sonst: Studierende fügen einen selbst erzeugten Schlüssel ein (Profil → Einstellungen → Sicherheitsschlüssel).
  3. Sonst: AJAX mit der Cookie-Sitzung wie auf dem PC (`SessionClient`), mit Hinweis auf die Aufrufzählung.
- Token nie loggen, nie in URLs speichern; erst beim Download anhängen (`with_token`).

### 4. Sync

- Reihenfolge: Learnweb, danach LSF-Stundenplan, Noten höchstens alle 20 Stunden (wie PC).
- Learnweb: Kurse → je Kurs Dateiliste → nur neue oder geänderte Dateien laden. Geändert = höheres
  `timemodified` (Token) bzw. höhere Pluginfile-Revision (Sitzung). Datei-ID `lw-<cmid>-<sha1(filepath+filename)[:8]>`
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

## Regeln

- Nur `develop`, kein Merge nach `main`, kein Release. Commits mit `[skip ci]`, solange die GitHub-Abrechnung offen ist.
- Keine echten Zugangsdaten in Code, Tests, Fixtures oder Logs. Passwörter tippt nur der Mensch selbst.
- Keine Stammdaten (Name, Geburtsdatum, Anschrift, Matrikelnummer) speichern oder committen.
- Fragen an den Inhaber, nicht raten: insbesondere ob das Moodle-SSO-Schema erlaubt ist, wenn es im Test scheitert.
