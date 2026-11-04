# Gemeinsamer Dokument-Index („Bibliothek“), Stand 04.11.2026

Idee des Inhabers: Hat jemand eine Kursdatei, die noch niemand analysiert hat, analysiert die App sie **einmal für alle**.
Jeder weitere Studierende mit derselben Datei bekommt die Einordnung sofort und ohne KI-Anfrage (0 Credits).

## Was je Seite entsteht

Ein Eintrag nach `packages/shared-contracts/doc-index.schema.json`. Swift (`DocIndexSchema`) und Python
(`app/doc_index.py`) verwenden dasselbe Schema Byte für Byte, geprüft durch `DocIndexTests` und `tests/test_doc_index.py`.

- `summary` (höchstens 500 Zeichen), `terms` (höchstens 12 Fachbegriffe)
- `elements`: was auf der Seite steht, in Lesereihenfolge (`order` 1..n ohne Lücken). Jedes Element hat einen Typ
  (Skizze, Diagramm, Tabelle, Formel, Definition, Satz, Beispiel, Aufgabe, Text), einen Titel, eine kurze Erklärung, die
  Position und das Kennzeichen `uncertain`.
- `tasks`: je Aufgabe, *was gefragt ist*. Eine Lösung kommt nur auf ausdrücklichen Wunsch dazu (`solutions`) und wird
  dann ebenfalls geteilt.
- Seite 0 ist die Zusammenfassung der Datei: Name, Seitenzahl, Seiten-Abdrücke und Katalog. Der Katalog umfasst
  Hochschule, Studiengang, Semester, Modul, Lehrwoche, Datum und Art (Vorlesung, Übung, …).

Seiten mit Abbildungen, Tabellen, Formeln oder Scans gehen als **Text und Bild** an die KI (PDF-Seite gerendert, 1200 px
breit, JPEG). Reine Textseiten gehen nur als Text. Die Erkennung (`DocIndexPageRule`) wertet eingebettete Bilder, sehr
wenig Text (Scan), mindestens 40 Zeichenbefehle (Diagramm, Tabelle) und mindestens 6 Formelzeichen aus. Jede Antwort
wird gegen das Schema geprüft. Pro Seite gibt es höchstens 3 Versuche (ein Versuch, zwei Wiederholungen); danach wird
die Seite ausgelassen, bis jemand „Neu erklären lassen“ wählt.

## Wo was liegt

| Ort | Inhalt |
| --- | --- |
| Gerät: Tabelle `page_index` im Container (eigener Name neben dem Aufgaben-Index `doc_index` der Wochentests) | geprüfter Eintrag je Datei-SHA und Seite, Status, Versuche, Quelle (`ai`/`cloud`), geteilt ja/nein |
| CloudKit, öffentliche Datenbank, Typ `DocIndex` | `recordName` `<fileKey>#<page>`; `fileKey` (Queryable), `page`, `payload` (verschlüsselt), `version`, `createdAt`, `ownerRecordName` |
| nirgends | Seitentext, Seitenbild, eigene Notizen, Namen |

- `fileKey` ist ein HMAC des Datei-SHA, nicht der SHA selbst.
- `payload` ist mit AES-256-GCM verschlüsselt. Der Schlüssel entsteht per HKDF aus Datei-SHA und Seiten-Abdruck, die
  Zusatzdaten binden das Chiffrat an Datei, Seite und Schemafassung. Lesen kann nur, wer **dieselbe Datei** hat; mit einer
  anderen Datei schlägt das Entschlüsseln fehl (getestet).
- Ein fremder Datensatz wird nie überschrieben. Wer eine Seite als Zweiter baut, speichert nichts erneut.

## Ablauf auf dem iPad (V1, ohne Server)

1. **Seite öffnen, KI-Hilfe offen:** `GET /api/index/file/{id}/page/{n}?lookup=1`. Kennt der lokale Zwischenspeicher die
   Seite, erscheint sie sofort. Sonst schaut die App in der Bibliothek nach, nur über den Datei-Schlüssel und ohne KI.
   Gibt es die Seite dort, zeigt die Karte **„Schon erklärt · aus der Bibliothek · 0 Credits“** mit:
   - den Elementen und Aufgaben,
   - Verweisen auf dasselbe Element an anderer Stelle des Moduls („auch in Vorlesung 2, Seite 12“, höchstens 3 je Element),
   - Verweisen auf **eigene Notizen** derselben Datei („Deine Notizen dazu vom 31.10. auf Seite 5“). Diese kommen nur aus
     dem lokalen Versionsverlauf der Annotationen; nichts davon verlässt das Gerät.
2. **Seite einordnen / Neu erklären lassen** (nur mit verbundener KI): `POST …/page/{n}` (`force` = mit Bild in voller
   Auflösung neu bauen). Vorher prüft die App immer: „Kenne ich die Seite schon?“
3. **Vorwärmen nach einem vollen Abgleich:** höchstens 3 Dateien der laufenden Lehrwoche ohne Index. Zuerst wird die
   Bibliothek gefragt, dann das sparsame Modell, nur Text. Das passiert **nur im WLAN und beim Laden** (`DocIndexPrewarm`)
   und lässt sich jederzeit abbrechen; der nächste Lauf macht dort weiter.
4. Ohne verbundene KI kann man nur lesen und übernehmen. Ohne iCloud-Container im Build (Simulator, CI) gibt es nur den
   lokalen Zwischenspeicher.

Endpunkte des lokalen Backends: `GET/POST /api/index/file/{id}/page/{n}`, `POST /api/index/file/{id}/prewarm`,
`GET /api/index/shelf?module=` (Regal: Hochschule › Studiengang › Semester › Modul › Woche › Art › Datei),
`GET /api/index/status`.

## Regeln des Inhabers (Ergänzung 04.11.2026)

1. **Dedupe vor jeder Analyse.** Vor dem ersten KI-Aufruf fragt das Gerät die Bibliothek nach dem **Datei-Abdruck**
   (`fileKey` = HMAC des SHA-256 der Datei): „Kenne ich die Datei schon?“ Eine bekannte Datei wird nie noch einmal
   analysiert, eine bekannte Seite (Seiten-Abdruck stimmt) nie noch einmal gesendet. Das Protokoll des Laufs nennt
   `bereits bekannt: <Datei> (lokal|Bibliothek)` bzw. `Seite n bereits bekannt (Bibliothek)` (`DocIndexBuildReport.log`,
   getestet in `DocIndexTests`). Erst danach gehen ausschließlich die fehlenden Seiten an die KI.
2. **Geordneter Katalog („Regal“).** Jede Zusammenfassung (Seite 0) trägt die Katalogangaben `catalog`:
   Hochschule → Studiengang (aus dem Notenspiegel, sonst „Allgemein“) → Semester (z. B. „WiSe 2026/27“, aus dem Kurs,
   sonst das aktive Semester) → Modul (`moduleKey` wie die Community, `moduleName`) → Lehrwoche des Moduls (`week`) + Datum
   der Datei (`date`) → Art (`kind`/`kindLabel`) → Datei → Seiten/Elemente. Die Art kommt aus der bestehenden Einordnung
   der Bibliothek (`StudyClassify.effectiveType`: `doc_type` + `sub_label`), damit Regal und Bibliothek dieselben Worte
   benutzen: Vorlesung, Übung, Hörsaalübung, Gruppenübung, Tutorium, Klausur, Altklausur, Skript, Lösung, Sonstiges
   (`DocIndexCatalog.kind`, in Python `catalog_kind`, Erwartungswerte in `fixtures/doc-index/cases.json`). Bei CloudKit
   liegt der Katalog nur im verschlüsselten `payload` und enthält nur, was sich aus den Kursdaten ableiten lässt – keine
   Namen. Das Regal selbst ist eine **lokale** Abfrage über die eigenen Dateien: `GET /api/index/shelf?module=<id>`
   liefert den Baum `university → programs → semesters → modules → weeks (week, label, from, to) → kinds → files`
   (je Datei Stand des Index: `ready`, `partial`, `none`, `indexed_pages`, `failed_pages`). Die KI-Hilfe zeigt den Platz
   der Datei im Regal („Im Regal: … › Woche 3 › Vorlesung“, `shelf_path`).
3. **Sehr genau.** Feste Reihenfolge überall: Elemente nach `order` (1..n lückenlos, sonst ungültig), Aufgaben nach
   `label`, Begriffe ohne Doppelte, Datensätze nach Seite; im Regal Studiengänge und Module nach Name, Semester neueste
   zuerst, Wochen wie das Moduldetail, Arten in fester Reihenfolge, Dateien nach Name und Kennung. Deterministische
   Kennungen: `recordName` = `<fileKey>#<page>`, Seiten-Abdruck aus normalisiertem Text (Bildseiten aus Datei-SHA und
   Seitennummer). Versioniertes Schema: `version` im Vertrag, im Datensatz (`version`), im Inhalt (`v`) und in den
   Zusatzdaten der Verschlüsselung (`schema:1`); eine neue Fassung lässt alte Einträge unberührt und wird nicht
   vermischt.

## Dienst (V2, Web/Windows): Entwurf mit Stub, 15-Minuten-Regel

`app/doc_index.py`:

- `POST /api/index/file` nimmt ein PDF an, nur für Konten, die KI nutzen dürfen, und nur mit bestätigter Adresse.
  Geprüft werden PDF-Kopf, Größe (≤ 60 MB) und `file_sha` (muss zum Inhalt passen). Optional nimmt der Endpunkt
  `pages` an, also nur die fehlenden Seiten.
- **Die hochgeladene Datei wird spätestens nach 15 Minuten gelöscht**, auch wenn die Verarbeitung nicht fertig ist. Eine
  Aufräumschleife läuft jede Minute, jeder Upload räumt Abgelaufenes zusätzlich mit weg. Das ist implementiert und
  getestet. Was bleibt, sind die Metadaten des Auftrags mit Löschzeit und Grund, keine Datei und kein Text.
- `GET /api/index/jobs/{id}` liefert den Stand des Auftrags.
- Der KI-Aufruf selbst (`analyze_page`) ist noch ein Stub.

## Offen

- KI-Aufruf im Dienst (V2) anschließen; Speicherort der Einträge beim Dienst festlegen.
- `DocIndex` im CloudKit-Dashboard für Production anlegen (docs/CLOUDKIT-SCHEMA-PRODUCTION-2026-11-03.md).
- Regal (`/api/index/shelf`) hat noch keine eigene Ansicht in der App; die KI-Hilfe zeigt nur den Pfad der offenen Datei.
- Tabellenname im Container ist `page_index` (der Name `doc_index` war schon durch den Aufgaben-Index der Wochentests
  belegt, `SchemaSQL.weekly`).
- Test auf dem echten iPad mit iCloud (zwei Konten, dieselbe Datei).
