# Übergabe an die Mac-Sitzung: Karteikarten-Stapel, KI-Karteikarten, Karteikarten teilen (04.11.2026)

Gebaut im Python-Dienst, in der Web-Oberfläche und damit in der Windows-App (Paket K). **Swift wurde nicht geändert.**
Diese Seite sagt, was das iPad nachbauen muss und welche Prüfdaten sich geändert haben. Hintergrund: `docs/PREISLISTE.md`,
Entscheidung des Inhabers `docs/ENTSCHEIDUNGEN-INHABER-2026-11-04.md`.

## 1. Was es jetzt gibt (Referenz)

| Teil | Python | Web |
| --- | --- | --- |
| Stapel = (Modul, Lernwoche oder ganzes Modul) | `app/flashcard_stacks.py`, `app/flashcards_api.py` | `app/static/flashcard-stacks.js` (Regeln), `flashcard-stacks-ui.js` |
| KI-Karteikarten auf Auftrag (Pro AI) | `POST /api/ai/flashcards` mit `module_id` (`flashcards_api.ai_stack`) | Dialog „KI-Karteikarten“ |
| Teilen und nutzen (Plus) | `app/community_decks.py`, Routen in `app/community_api.py` | „Teilen“ je Stapel, „Aus der Community“, Reiter „Karteikarten“ im Community-Kanal (`community-decks-ui.js`) |
| Rechte | `app/plans.py`: `can_share_flashcards`, `can_generate_ai_flashcards` jetzt `available` | `can()` aus `/api/entitlements` |

## 2. Pflicht für das iPad (sonst werden Swift-Tests rot)

1. **Schema (Migrations.swift, nicht SchemaSQL):** `flashcards` bekommt drei Spalten, angehängt wie in `app/db.py`
   (`add_col`, nach `last_result`): `module_id INTEGER`, `lecture_week INTEGER`, `origin TEXT`. Kein Backfill. Neu erzeugt:
   `fixtures/schema/schema.json`, `fixtures/schema/legacy.json`. `SchemaSQL.swift` bleibt (CREATE TABLE unverändert).
2. **Geräte-Abgleich G2 (`fixtures/sync/cases.json`):** `flashcards` hat jetzt den Fremdschlüssel
   `module_id -> modules` (`app/sync.py` ENTITIES): neue Module im selben Push (negative lokale IDs) werden aufgelöst, beim
   Abruf auf lokale IDs abgebildet. Fachlicher Schlüssel der Karte (erster Abgleich): `(Frage, file_id, module_id, lecture_week)`
   (`app/sync_client.py natural_key`). Im Dienst lehnt der Push **neue** Karten (ohne `id`) ohne Plus mit
   `{entity: "flashcards", local_id, status: "plan_required", required_plan: "plus"}` ab; bestehende Karten gleichen weiter ab.
3. **Lokales Backend:** `fixtures/local-backend/flashcards.json` und `fixtures/demo/demo.json` enthalten die drei neuen
   Spalten (Wert `null`) in Zeilen und Antworten von `GET /api/flashcards`.
4. **Tarife:** `fixtures/plans/plans.json`: Status `available` für `can_share_flashcards` und `can_generate_ai_flashcards`
   (`Purchases/Plans.swift` angleichen; die Plus-4/Pro-AI-20-Umstellung steht dort noch aus).
5. **Konto:** `fixtures/account/contract.json`: neue Grenze `deck_user` (10 je Tag) und Exportdatei
   `community/meine-karteikarten.json`. `fixtures/community/contract.json`: `GET /api/community/moderation` hat `decks`.

## 3. Nachbauen (Funktion)

**Prüfdaten:** `packages/shared-contracts/fixtures/flashcards/stacks.json` (`tools/gen-flashcard-stacks-fixture.py`,
geprüft in `tests/test_flashcard_stacks.py`):
- `local`: Seed, eingefrorene Uhr (04.11.2026 10:00 Berlin), Schritte mit Status und Antwort für
  `POST /api/flashcards/stack`, `GET /api/flashcards/stacks`, `GET /api/flashcards/stack`, `POST /api/flashcards/move` und
  die Tabelle danach. Der Swift-Kern (LocalBackend) soll dieselben Antworten liefern, wenn das iPad Stapel lokal führt.
- `ai_stack`: Anfrage, Material (Quellen je Datei und Seite), **genauer Prompt** und Antwort des KI-Auftrags gegen eine
  Attrappe, dazu die Fehler `no_content` (404), `ai_no_cards` (502), `week_invalid`, `module_not_found`.
- `community`: alle Stapel-Endpunkte im Dienst mit Status/Antwort, auch Fehlerfälle (Tarif, E-Mail, Mitgliedschaft, Grenzen).
- `rules`: Zahlen (5–50 Karten, Woche 1–30, 500 Karten je Stapel, 1000 Zeichen je Seite in der Community, 4000 lokal).

**Regeln, die das iPad gleich machen muss:**
- Stapel einer Karte: `module_id`, sonst das Modul ihres Dokuments (`file_id` → Kurs → Modul); ohne beides „Weitere Karten“.
  Woche `null` = ganzes Modul. Anzeige: „Woche N · TT.MM. – TT.MM.“ (`study.week_label`) bzw. „Ganzes Modul“.
- In einen Stapel legen: gleiche Frage (klein, nur Buchstaben/Ziffern) oder fast gleiche (Wortüberschneidung ≥ 0,85 bei
  mindestens 3 Wörtern über 2 Zeichen) im selben Stapel wird übersprungen (`flashcard_stacks.without_duplicates`).
- Herkunft `origin`: `null` (selbst), `ai` (KI-Auftrag), `community:<deck-id>` (übernommen).
- **KI-Auftrag (Pro AI):** das iPad ruft den Dienst `POST /api/ai/flashcards {module_id, lecture_week, count, topic?,
  request_id, again?}` (Recht `can_generate_ai_flashcards`, bestätigte E-Mail, Kontingent `ai_assist`, eine `request_id` je
  Auftrag, Rückbuchung bei Fehlern im Dienst). Die Modul-ID ist die **Dienst-ID** (nach G2). Hat der Dienst keinen
  Seitentext (Gerät gleicht selbst ab), schickt das iPad `material: [{title, text}]` (bis 30 Teile, zusammen höchstens
  24 000 Zeichen); Antwort `{cards, count, module_id, module_name, lecture_week, sources, duplicates_removed, existing}`
  ist nur ein Vorschlag, gespeichert wird nach Bestätigung (lokal mit `origin = "ai"`, danach G2).
- **Ohne Pro AI:** „KI-Karteikarten“ mit Schloss und Weg zur Tarifseite; mit eigenem ChatGPT (Plus) gibt es den Auftrag
  laut Preisliste nicht (dort bleibt „Karteikarten aus Dokument“).
- **Teilen/Übernehmen (Plus):** Tarif `can_share_flashcards`; ein Stapel je Konto, Community und Woche („Aktualisieren?“ über
  `GET /decks/mine` oder 409 `already_published` + `deck_id`); versteckte Karten werden nicht geteilt.

**Community auf dem iPad (zu entscheiden):** Der Dienst speichert Stapel im Klartext und schützt über die Mitgliedschaft
(Entscheidung in `docs/LOESUNGEN-TEILEN.md` 6c). Läuft die iPad-Community in V1 weiter über CloudKit, braucht es einen
Typ, Vorschlag:

| Typ | Feld | Typ | Index |
| --- | --- | --- | --- |
| `FlashcardDeck` | `courseKey` | String | Queryable |
| | `week` (0 = ganzes Modul) | Int(64) | Queryable |
| | `payload` (Titel, Karten, Pseudonym; verschlüsselt mit dem Community-Schlüssel wie `Comment`, HKDF-Info z. B. `uniflow-community-deck/v1|<deckID>`) | String | – |
| | `createdAt`, `ownerRecordName`, `status` | String | – |
| `DeckUse` | `deckID` | String | Queryable |
| `Report` | `deckID` (neu) | String | Queryable |

Sobald das iPad den StudiNow-Dienst nutzt, gelten die Endpunkte aus `docs/LOESUNGEN-TEILEN.md` 6c direkt (ohne CloudKit).

## 4. Offen / Hinweise

- Benachrichtigung an den Autor, wenn jemand seinen Stapel übernimmt, gibt es noch nicht.
- Sperren eines Autors geht weiter nur über eine Lösung (`/solutions/{id}/block`); seine Stapel blendet die Sperrliste aus.
- Web-Dateien mit geänderten Imports: `views-misc.js`, `community-channel.js` (Cache-Versionen zählt der Inhaber mit
  `tools/bump-static.py` hoch).
