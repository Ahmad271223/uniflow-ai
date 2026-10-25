# UniFlow auf dem iPad ohne PC: Stand, Serverabhängigkeiten, Architektur, Reihenfolge

Stand 25.10.2026, `develop`. Vorgabe des Inhabers: Die fertige iPad-App funktioniert für jeden Studenten **ohne PC,
MacBook oder Python-Server**. Stud.IP-Anmeldung, Import und Abgleich laufen auf dem iPad; Dashboard, Module,
Kalender, Lernplanung, PDF-Editor und Suche funktionieren lokal und offline. Der Windows-Server dient nur noch der
Entwicklung und dem Vergleich. Zentrale Onlinedienste nur für Community und Konten, nie der PC des Studenten.
Keine kostenpflichtigen Dienste ohne Zustimmung, keine Änderungen an `main`. Vorrang für Abos und ersten Start hat
`docs/AUFTRAG-APPSTORE-V1.md`.

Grundlage: Codeanalyse mit vier Lesern, Architekturentwurf und Gegenprüfung (25.10.2026). Diese Datei wird nach
jedem Umsetzungsschritt fortgeschrieben (Abschnitt 2 und 7).

## 1. Tarife (Entscheidung vom 25.10.2026)

| | Free (0 €) | Plus (1,99 €/Monat, 1 Woche gratis) |
|---|---|---|
| Stud.IP verbinden und abgleichen, Dokumente öffnen und durchsuchen | ✓ | ✓ |
| Fächer und Module geordnet, Stundenplan | ✓ | ✓ |
| Lernkalender und **Lernplanung** (Lernplan, Lernkombination, freie Zeitfenster, Nachholen, Woche retten) | ✓ | ✓ |
| Zeitmesser, vorhandene Notizen ansehen und als PDF exportieren | ✓ | ✓ |
| **Schreiben mit Apple Pencil**, Seiten einfügen/drehen/Papierkorb, Lesezeichen | – | ✓ |
| **Community** (Lösungen teilen und ansehen) | – | ✓ (folgt) |
| Übung und Skript nebeneinander mit Skriptsuche, eigene Karteikarten | – | ✓ |

Pro und alle KI-Funktionen entfallen vorerst. Umgesetzt auf `develop` (Tarifwahl, Berechtigungen, StoreKit-Test).

## 2. Stand heute: was ohne PC läuft

| Bereich | Stand | Was fehlt |
|---|---|---|
| Erster Start (Mit Apple anmelden, Tarifwahl, Konto löschen) | **nativ fertig** (echte Apple-Anmeldung braucht das Developer Program) | – |
| Stud.IP-Anmeldung auf der echten Seite, Sitzung im Schlüsselbund, Ablauf erkennen | **nativ fertig** | Navigationsgrenzen und Fehlermeldungen in der Webansicht; Logout beendet die Sitzung nicht beim Server; stilles Erneuern; OAuth2 (Freigabe LUH) |
| Kurse, Ordnerbaum, Dateien laden | **nativ teilweise** | Dateien nur in einer eigenen Liste und QuickLook; ein Fehler bricht den ganzen Lauf ab; ganze Dateien im Arbeitsspeicher; kein ETag/If-Modified-Since; keine Einordnung (Fach, Art, Lehrwoche) |
| Kurszeiten (seminar-cycle-dates) | **Kern fertig**, nicht angebunden | Abruf in der App, lokale Ablage, Gruppenauswahl |
| Einzeltermine (course-events) | **nur Server** | Swift-Abruf |
| QIS (Noten) | **Kern fertig** (Parser), nicht angebunden | Webansicht, Ablage, Anzeige |
| Übersicht, Lernkalender, Stundenplan, Module, Dokumente, Einstellungen (Lernzeit, Semester) | **nur Server** | lokales Backend (Abschnitt 4) |
| PDF-Editor mit Apple Pencil | **nur Server** (`/api/files/{id}/content` und `/annotations`) | lokale Datei und lokale Notizablage |
| Suche, Skriptsuche | **nur Server** | lokaler Index, Port von `scriptsearch.py` |
| Geänderte Original-PDF bei vorhandenen Notizen | **fehlt** | Fingerabdruck, Neuzuordnung der Seiten, alte Fassung aufbewahren |
| Hintergrundabgleich | **fehlt** | BGAppRefresh; vorher Sitzungsdauer messen bzw. OAuth2 |
| Zeitmesser | **nativ fertig** | Mitteilung bei Ablauf im Hintergrund |
| Community | **fehlt** | zentraler Dienst (Entscheidung des Inhabers) |

## 3. Serverabhängigkeiten

Die iPad-App ruft heute **75 verschiedene Endpunkte an 129 Stellen in 19 Dateien** auf; **keiner** wird auf dem
iPad selbst beantwortet. Ohne Server zeigen die Seiten deshalb leere Zustände mit „Stud.IP verbinden“.

| Bereich | Endpunkte | Ziel |
|---|---|---|
| Übersicht, Dateien als gesehen | `/api/dashboard`, `/api/files/mark-seen` | lokal (Free) |
| Module und Kurse | `/api/modules*`, `/api/courses*` (9) | lokal (Free) |
| Bibliothek, Ordner, Notizbücher, Favoriten | `/api/library*`, `/api/folders*`, `/api/notebooks`, `/api/files/{id}/favorite` (7) | lokal (Free; Notizbücher Plus) |
| Datei-Inhalt und Notizen | `/api/files/{id}/content`, `/annotations` (GET/PUT, Versionen) | lokal (Lesen Free, Schreiben Plus) |
| Lernkalender, Pakete, Aufgaben, Zeitfenster | `/api/calendar*`, `/api/tasks*`, `/api/packages*`, `/api/timetable/reslot` (16) | lokal (Free) |
| Stundenplan, Termine, Import, Konflikte | `/api/timetable/*` (12) | lokal (Free) |
| Einstellungen, Semester | `/api/settings`, `/api/terms` | lokal |
| Suche, Skriptsuche | `/api/search`, `/api/related` | lokal |
| Abgleich und Status | `/api/sync`, `/api/sync/status`, `/api/bg` | lokal als Stud.IP-Abgleich |
| Karteikarten | `/api/flashcards*` | lokal (Plus), eigenes Anlegen ohne KI |
| Uni & Noten | `/api/services`, `/api/grades*`, `/api/qis/*` | Dienste-Liste lokal; QIS auf dem Gerät (später) |
| Zugänge | `/api/credentials*` | entfällt (keine Passwörter in der App) |
| Tests, KI | `/api/tests*`, `/api/ai/tutor`, `/api/tasks/{id}/start-test` | entfällt (keine KI) |
| Community, Konto | – | zentraler Dienst (Entscheidung) |

## 4. Architektur

1. **Lokales Backend:** Es beantwortet dieselben `/api/`-Pfade mit derselben JSON-Form wie `app/server.py`. Die
   fertigen 1:1-Ansichten bleiben unverändert. Angeschlossen wird es über ein Transport-Protokoll im `APIClient`
   (die beiden URLSession-Aufrufe werden zu `transport.send`); die Basis-URL `uniflow-local://device/` trennt den
   Zwischenspeicher von Serverdaten.
2. **SQLite ohne Fremdpaket:** iOS-System-SQLite3; im Kern unter Linux über eine `systemLibrary` (CI braucht
   `libsqlite3-dev`). Schema wörtlich aus `app/db.py` (Generator), Migrationen 1:1 wie `db.py`. Ein Actor mit einer
   Verbindung; **kein `await` innerhalb einer Transaktion** (Actors sind reentrant). Datenbank mit Dateischutz
   `completeUntilFirstUserAuthentication`.
3. **Python bleibt die Referenz:** Logik wird nach Swift portiert, Ergebnisgleichheit über Fixtures, die
   `tools/gen-logic-fixtures.py` mit eingefrorener Uhr aus Python erzeugt. Korrekturen zuerst in Python.
4. **Stud.IP-Abgleich in die lokale Datenbank:** wiederaufnehmbar, Fehler nur je Kurs/Datei, Versionen über chdate,
   Größe und SHA-256, Downloads als Datei statt im Arbeitsspeicher. Dateien erscheinen in Dokumente & Notizen,
   Modulen und Übersicht und öffnen sich direkt im UniFlow-Editor (keine eigene Stud.IP-Liste als Hauptoberfläche).
5. **Neue Original-Fassung:** Notizen bekommen einen Herkunftsstempel (Hash, Seitenzahl, Seitenfingerabdruck);
   beim Wechsel werden Seiten über den Inhalt neu zugeordnet, die alte Fassung wird aufbewahrt, der Nutzer sieht
   einen Hinweis.
6. **Hintergrund:** Abgleich sicher beim Start und Wiederöffnen; BGAppRefresh „frühestens 8/15/20 Uhr“ ohne
   Versprechen fester Zeiten – sinnvoll erst mit längerer Sitzung bzw. OAuth2.
7. **Community „Lösungen teilen“:** Nur die eigene Anmerkungsebene wird veröffentlicht (Vorschau, Bestätigen,
   Zurückziehen), angezeigt direkt im Editor über der eigenen Original-PDF des Betrachters. Zuordnung über den
   SHA-256 der Original-PDF; der Hash ist **kein Besitznachweis**. Deshalb zusätzlich: Prüfung auf dem Gerät, dass
   die Datei aus dem eigenen Stud.IP-Abgleich stammt und ihr Kurs in den eigenen Kursen liegt; Inhalt verschlüsselt
   mit einem Schlüssel, der aus den Bytes der Original-PDF abgeleitet ist (wer die Datei nicht hat, kann nichts
   lesen); Melden und Blockieren (App Store 1.2); Hinweis auf die Prüfungsordnung. Eine echte Prüfung der
   Kursmitgliedschaft auf dem Dienst ginge nur mit Mitwirkung der Hochschule (z. B. signierter Beleg), denn
   Stud.IP-Cookies oder -Tokens dürfen nie an einen Dienst.

## 5. Reihenfolge der Umsetzung

Zuerst der größte Nutzen: Dokumente öffnen und mit dem Pencil schreiben ohne PC.

| Schritt | Inhalt | Abnahme ohne PC |
|---|---|---|
| S1 | SQLite-Schicht, Schema, Migrationen, gemeinsame Uhr | Tests im Kern grün (macOS und Linux) |
| S2 | Transport-Weiche und Router; Journal-Namensraum je Datenquelle; **Übernahme der eigenen Notizen und Pläne vom PC** (Entwicklung); gültige leere Antworten für noch nicht portierte Pfade | Seiten laden lokal ohne Fehler; Wechsel PC ↔ lokal verliert keine Notizen |
| S3 | Stud.IP-Dateien in die Datenbank; Endpunkte Bibliothek, Datei-Inhalt, Notizen; Editor lokal | Stud.IP verbinden → Dokumente erscheinen → im Editor öffnen und schreiben, offline |
| S4 | Fach, Art, Lehrwoche ohne KI (`classify`, `effective_type`, `week_hint`); Module-Endpunkte | Fächer geordnet, Moduldetail mit Wochen |
| S5 | Stundenplan: Kurszeiten und Einzeltermine aus Stud.IP, `timetable.py`-Port | Stundenplan aus Stud.IP |
| S6 | Lernlogik (`study.py`): lesen, verschieben, planen; Übersicht, Kalender | Lernplan erstellen, Aufgaben abhaken, Übersicht |
| S7 | Neue Original-Fassung mit erhaltenen Notizen; Suche und Skriptsuche | Notizen überleben neue PDF; Suche offline |
| S8 | Hintergrundabgleich (nach Messung der Sitzungsdauer bzw. OAuth2) | Abgleich beim Öffnen und, wenn iPadOS es erlaubt, im Hintergrund |
| S9 | Community „Lösungen teilen“ (nach Entscheidung zum Dienst) | Lösung veröffentlichen, im Editor ansehen, zurückziehen |
| S10 | Anmeldung härten, Release-Bereinigung, Demo-Modus für die App-Prüfung, Abnahmeliste | Abnahme nach AUFTRAG 2a und dieser Datei |

Nach jedem Schritt: bauen, Unit-Tests, Prüfung „funktioniert auf einem iPad ohne Windows-PC“, Abschnitt 2 dieser
Datei fortschreiben.

## 6. Hochschul-Freigaben (vom Inhaber zu klären)

- **ZQS/elsa:** schriftliche Erlaubnis für den Abruf über die JSON:API durch eine App für andere Studierende
  (Abrufmuster nennen); OAuth2-Client mit PKCE und Lebensdauer von Sitzung und Refresh-Token; ob Teilen der eigenen
  Anmerkungsebene innerhalb eines Kurses in Ordnung ist. Entwurf: `docs/ANFRAGE-STUDIP-ZUGANG.md`.
- **LUH:** Erlaubnis für den App Store nach Richtlinie 5.2.2 (Nutzung der Hochschuldienste und Namen).
- **LUIS:** Anmeldung in der eingebetteten Webansicht als Übergang zulässig oder nur `ASWebAuthenticationSession`.
- **Datenschutz und Urheberrecht:** Datenschutzerklärung; lokale Speicherung der Skripte; Teilen eigener
  Anmerkungen über fremden Folien; Hinweis zu bewerteten Abgaben (Prüfungsämter).
- **Messung am Gerät (ohne Freigabe):** Wie lange hält die Stud.IP-Sitzung? Liefert Stud.IP ETag oder
  Last-Modified?

## 7. Entscheidungen des Inhabers

**Entschieden am 25.10.2026** (Vorschläge 1–7 bestätigt):

1. **Python-Korrekturen** (Stichtag des Semesterbeginns, gespeicherte Uhrzeit von Lernpaketen, ICS mit UTC/TZID)
   werden als Fehlerbehebung auch in der Web-App übernommen – zuerst in Python, danach portiert.
2. **Lernplan ohne Testaufgaben** (keine KI): Standard `tests_per_subject` = 0, in Python und auf dem iPad.
3. **Demo-Modus** für die App-Prüfung nur über einen versteckten Schalter für Prüfer; sonst keine Beispieldaten.
4. **Eigener Server** (Entwicklungsmodus) nur in Debug-Builds; im Release nicht erreichbar.
5. **Nur LUH** in V1.
6. **Backup:** Notizen, Plan und Einstellungen ins iCloud-Backup; Stud.IP-Dateien, alte Fassungen und Seitentexte
   ausgenommen.
7. **Große Dateien** (z. B. Videos über 100 MB) werden nur auf Wunsch geladen.

**Offen:**

8. **Community-Dienst:** CloudKit (gehört zum Developer Program, 99 €/Jahr) oder Supabase (ca. 25 USD/Monat) –
   entscheidet der Inhaber später; bis dahin wird die Community nur vorbereitet (ohne echten Dienst).
