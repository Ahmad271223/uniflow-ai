# Erklärungsspeicher („Einmal erklären, alle profitieren“), Stand 04.11.2026

Entscheidung des Inhabers (04.11.2026): gestuft, nichts vortäuschen. Die Antworten der KI-Hilfe für **ganze Seiten**
werden einmal erzeugt und unter dem Seiten-Abdruck geteilt. Der erste Studierende bekommt die Antwort live; jeder
weitere mit derselben Seite bekommt sie sofort, ehrlich beschriftet, und kann jederzeit neu fragen.

## Was geteilt wird – und was nicht

| Modus der KI-Hilfe | geteilt? | Bedingung |
| --- | --- | --- |
| Erklären, Einfach erklären, Zusammenfassen, Fachbegriffe, Aufgabe lösen, Nur Hinweise | **ja** | nur ohne markierten Text und ohne eigene Frage (`PageExplain.isShareable`) |
| Frage, Lösung prüfen, Ähnliche Aufgabe, Karteikarten, alles mit Markierung oder Frage | nein | bleibt live und ungeteilt |

- Live-Antworten werden lokal gemerkt und veröffentlicht; Quellenmarken `[n]` werden vorher entfernt (die Quellen
  des ersten Fragenden hat der nächste nicht). Der erste Fragende sieht seine Antwort unverändert mit Quellen.
- Eine gespeicherte Antwort zeigt die KI-Hilfe mit **„Schon erklärt · sofort da · 0 Credits“** (vom Dienst) bzw.
  **„Schon erklärt · 0 Credits“** (eigener Zwischenspeicher) und dem Knopf **„Neu erklären lassen“** (`TutorPanel.storedLabel`).
  Beim Öffnen einer Seite wird nichts eingefügt – erst nach dem Antippen des Modus.
- **Eigene Fragen** („Frage“) bleiben live, bekommen aber die Einordnung der Seite aus der Bibliothek (`page_index`:
  Zusammenfassung, Begriffe, Elemente, Aufgaben) als zusätzlichen, als Material gekennzeichneten Block im Prompt
  (`PageExplain.indexContext`, höchstens 1200 Zeichen). Ohne Eintrag bleibt der Prompt byte-gleich mit `app/ai.py`.

## Schlüssel, Varianten, Verschlüsselung

- Schlüssel eines Datensatzes: `<fileKey>#<page>#<mode>#<variant>` (`PageExplain.recordName`). `fileKey` ist der HMAC des
  Datei-SHA wie beim Dokument-Index, `page` ab 1, `mode` einer der sechs geteilten Modi, `variant` 1…3.
- **Varianten wie bei den Wochentests:** höchstens drei je Schlüssel, ein Datensatz wird nie überschrieben (auch kein
  eigener). „Neu erklären lassen“ fragt live und belegt den nächsten freien Platz; bei einem Wettlauf den
  übernächsten; sind alle drei belegt, bleibt die Antwort nur lokal (Variante 0). Leser nehmen die niedrigste
  vorhandene Variante (`PageExplain.choose`: eigener Zwischenspeicher → Dienst → live).
- `payload` ist mit demselben Schlüsselstoff wie der Dokument-Index verschlüsselt (HKDF aus Datei-SHA und
  Seiten-Abdruck, AES-256-GCM über `SolutionCipher`), eigener Namensraum `uniflow-pageexplain`. Die Zusatzdaten binden
  das Chiffrat an `fileKey`, Seite, Modus, Variante und Formatfassung (`format:1`); der entschlüsselte Inhalt muss
  dieselbe Seite, denselben Abdruck, Modus und Variante nennen. Eine andere Datei, ein anderer Modus oder eine andere
  Variante lesen nichts (getestet in `PageExplainTests`, mit CryptoKit in `PageExplainAppTests`).
- Inhalt des Chiffrats: `{v: 1, page, pageHash, mode, variant, text, model, createdAt}`. Kein Seitentext, keine Namen,
  kein Bild.

## Wo was liegt

| Ort | Inhalt |
| --- | --- |
| Gerät: Tabelle `page_explain` im Container (bei Bedarf angelegt wie `page_index`, `PageExplainStore`) | je Datei-SHA, Seite, Modus, Variante: Text, Quelle (`ai` selbst gefragt / `cloud` übernommen), geteilt ja/nein, Modell, Zeitpunkt |
| CloudKit, öffentliche Datenbank, Typ `PageExplain` (`PageExplainCloudKit.swift`) | `recordName` wie oben; `fileKey` (Queryable), `page`, `mode`, `variant`, `payload`, `version`, `createdAt`, `ownerRecordName` |
| Dienst (Python) | in V1 nichts; Format in `packages/shared-contracts/page-explain.md`, damit der Dienst es später spiegeln kann |

Endpunkt: `POST /api/ai/tutor` wie bisher, dazu `force` (true = „Neu erklären lassen“). Die Antwort trägt `explain`:
`{"stored": true, "source": "local"|"cloud", "variant", "created_at"}` für eine gespeicherte, `{"stored": false, "variant",
"shared"}` für eine gerade erzeugte Antwort, `null` bei allem Ungeteilten. `GET /api/index/status` nennt
`explanations`, `explanations_shared`, `explain_library`.

## Schalter „Vorab einordnen“

Einstellungen → Erweitert, KI-Bereich (`DocIndexPrewarmCard`), UserDefaults `uniflow.docIndexPrewarmLevel`:

- **Zusammenfassung und Begriffe (Standard)** (`basic`): das Vorwärmen nach dem Abgleich bleibt wie bisher
  (Dokument-Index, nur WLAN und Laden, höchstens 3 Dateien der laufenden Woche).
- **Alles (auch Erklärungen und Lösungen)** (`full`): dieselben Dateien bekommen zusätzlich je Seite `explain` und für
  Seiten mit Aufgaben laut Index `steps`, erzeugt mit dem Prompt der KI-Hilfe (nur Kurs, Datei, Seite, Seitentext) und
  geteilt wie oben (`PageExplainBuilder.prewarm`, Plan `PageExplain.prewarmPlan`). Vorher wird je Punkt nachgesehen
  (Zwischenspeicher, Dienst), der nächste Lauf macht nach einem Abbruch weiter.
- Kostenhinweis in der Einstellung: „Alles vorab kostet je Seite ein Vielfaches und löst Übungsaufgaben für alle,
  bevor jemand fragt.“

**Kosten, in zwei Sätzen:** Eine geteilte Antwort ersetzt jede weitere KI-Anfrage zur selben Seite im selben Modus –
bei 30 Studierenden je Datei fallen statt 30 nur eine (bis drei) Anfragen an. „Alles vorab“ dreht das um: es bezahlt
Erklärungen und Lösungen für jede Seite, bevor jemand fragt, darum bleibt es ausdrücklich abschaltbar und Standard aus.

## Was der Dienst später spiegeln muss

`packages/shared-contracts/page-explain.md`: Datensatzname, Felder, Varianten-Regel (nie überschreiben, höchstens
drei), die Verschlüsselung mit `info` und Zusatzdaten und den Inhalt des Chiffrats. Der Dienst sieht nie den Datei-SHA
und kann die Antworten nicht lesen; er verwahrt nur Chiffrate je `fileKey`.

## Offen

- `PageExplain` im CloudKit-Dashboard für Production anlegen (docs/CLOUDKIT-SCHEMA-PRODUCTION-2026-11-03.md).
- Lokal erzeugte Antworten ohne Dienst (Variante 0) werden später nicht nachgereicht.
- Test auf dem echten iPad mit iCloud (zwei Konten, dieselbe Datei): erster „Erklären“ live, zweiter „sofort da“.

## Dienst (Python), Stand 04.11.2026 – Spiegel fuer Web und Windows

`app/page_explain.py` (Regeln, Ablage) und `app/page_explain_api.py` (Routen), Tests in `tests/test_page_explain.py`. Das iPad
bleibt in V1 bei CloudKit; der Dienst bietet dieselben Regeln fuer spaeter, damit kein Geraet etwas aendern muss.

| Endpunkt | Was |
| --- | --- |
| `GET /api/explain?file_key=&page=&mode=` | Varianten eines Schluessels, niedrigste zuerst; dazu `free` (freie Plaetze), `full`, `preferred`. Ohne `page`/`mode`: alle Datensaetze der Datei (hoechstens 900) |
| `GET /api/explain/{file_key}/{page}/{mode}/{variant}` | ein Datensatz (`404 not_found`) |
| `POST /api/explain` | `{file_key, page, mode, payload, version?, variant?}` → `201` mit dem Datensatz. Ohne `variant` der niedrigste freie Platz 1…3, mit `variant` genau dieser (belegt: `409 explain_taken`). Sind alle drei belegt: `409 explain_full` („Fuer diese Seite gibt es schon drei geteilte Antworten in diesem Modus. Die neue Antwort bleibt nur auf dem Geraet.“). Nie ueberschreiben, auch nicht der Ersteller. `created_at` setzt der Dienst (UTC) |
| `DELETE /api/explain/{file_key}/{page}/{mode}/{variant}` | nur Ersteller oder Inhaber (Rolle admin), sonst `403 not_owner` |

- Sitzung noetig (gehosteter Dienst, sonst `501 not_hosted`); Speichern nur mit bestaetigter E-Mail-Adresse
  (`403 email_unverified`, wie Veroeffentlichen in der Community). Speichern und Loeschen zaehlen gegen
  `accounts.LIMITS["explain_user"]` (120 je Konto und Tag, `LERNAPP_LIMIT_EXPLAIN_USER`), `429 rate_limited` mit `Retry-After`.
- Pruefung nur der Form: `file_key` 64 Hexziffern, `page` 1…10000, `mode` einer der sechs geteilten Modi, `variant` 1…3,
  `payload` Base64 ohne Zeilenumbrueche, hoechstens 256 KiB (wie `DocIndexCrypto.maxPayloadChars`), erstes Byte des
  Chiffrats = `version` (`400 version_mismatch`). Der Dienst kennt weder Datei-SHA noch Seiten-Abdruck und liest nichts.
- Antwort eines Datensatzes: `record_name, file_key, page, mode, variant, payload, version, created_at, mine`; die
  Ersteller-Kennung (`owner_id`) sieht nur der Inhaber (Moderation), wie `ownerRecordName` bei CloudKit.
- Ablage: Tabelle `page_explain` in `accounts.db` (`UNIQUE(file_key, page, mode, variant)` entscheidet einen Wettlauf;
  der zweite bekommt den naechsten freien Platz). Beim endgueltigen Loeschen eines Kontos (`accounts._purge_user`)
  bleibt das Chiffrat fuer die anderen, der Besitzer wird anonymisiert wie in `credit_ledger` (`deleted:<zufall>`).
- Offen: Web und Windows rufen die Endpunkte noch nicht; iPad und Dienst teilen sich noch keinen Speicher (CloudKit
  und `page_explain` sind getrennte Welten, bis der Dienst die CloudKit-Datensaetze spiegelt oder umgekehrt).
