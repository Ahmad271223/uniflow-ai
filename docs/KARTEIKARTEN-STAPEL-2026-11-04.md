# Karteikarten: geschlossene Stapel und nachträgliches Bearbeiten (Entscheidungen vom 04.11.2026)

Gilt für den Python-Dienst (`app/server.py`, `app/db.py`), den Swift-Kern (`FlashcardEndpoints.swift`, `Migrations.swift`),
die iPad-App (`CardsPage.swift`, `FlashcardTrainer.swift`, `FlashcardComposer.swift`) und das Web (`flashcards.js`,
`views-misc.js`). Python und Kern sind gleich: gemeinsame Fixture `packages/shared-contracts/fixtures/local-backend/flashcards.json`
(`tools/gen-flashcards-fixture.py`, Szenario `stapel`), geprüft von `tests/test_flashcards_hidden.py` und `LocalFlashcardTests`.

## Regeln

1. **Jede Karte gehört zu genau einem Stapel.** Ein Stapel hat einen Namen, ein Modul (`subject`, der Name des Moduls wie
   `flashcards.subject`) und optional ein Quelldokument (`file_id`). Die Karten eines Stapels tragen sein Fach: beim Anlegen
   mit `stack_id`, beim Verschieben einer Karte (`PATCH stack_id` ohne `subject`), beim Verschieben des Stapels
   (`PATCH /api/flashcard-stacks/{id}` mit `subject`) und beim Löschen mit Umzug.
2. **Geübt wird in einem Stapel, nie gemischt.** „Heute fällig“, Wiederholen (Leitner, `POST /review`) und der Trainer
   („Frei üben“) laufen mit den Karten eines gewählten Stapels (`GET /api/flashcards?stack_id=&due=1`). „Heute fällig (n)“
   steht je Stapel; ohne gewählten Stapel wird nichts abgefragt. Der Gesamtzähler (`?due=true` ohne Stapel) bleibt für
   Tests-Seite und Dashboard.
3. **Stapelliste** je Modul: Name, Modul, Zahl der Karten, Heute fällig (n), zuletzt geübt (`last_practised`: letzte
   Wiederholung oder Trainer-Antwort mit Urteil im Stapel).
4. **Karte anlegen** verlangt einen Stapel: Vorgabe ist der zuletzt benutzte Stapel des Moduls (zuletzt geübt, sonst der
   neueste), sonst „Neuer Stapel …“ mit Namensvorgabe (Titel des Dokuments, sonst „Allgemein“ im Modul, sonst „Ohne Modul“).
   KI-Karten („Karteikarten aus Dokument“, `FlashcardComposer`) landen in einem gewählten oder benannten Stapel
   (`stack_name`, Vorgabe = Dokumenttitel; der Server nimmt einen gleichnamigen Stapel des Fachs, sonst legt er ihn mit dem
   Dokument als Quelle an). `POST /api/flashcards` ohne Stapelangabe (ältere Clients, Editor-Seitenleiste im Web) nimmt den
   Stapel des Dokuments bzw. „Allgemein“/„Ohne Modul“ (wie die Migration).
5. **Karten nachträglich bearbeiten:** Frage, Antwort, Modul und Stapel (`PATCH /api/flashcards/{id}`). Fach und Termin
   (Leitner), Lesezeichen und „versteckt“ bleiben unberührt. iPad: „Bearbeiten“ aus der Kartenliste, aus „Heute fällig“
   und aus dem Trainer (Symbol auf der Karte, VoiceOver-Aktion), derselbe Dialog wie „Karte anlegen“. Web: Bearbeiten in
   der Zeile und als Dialog im Trainer bzw. in der Wiederholung.
6. **Stapel umbenennen, verschieben, löschen.** Löschen fragt: Karten mit dem Stapel löschen oder in einen anderen Stapel
   verschieben (`?move_to=`; Lernstand bleibt, die Karten bekommen das Fach des Ziels).
7. **Lehrwoche und Art je Stapel** (Ergänzung des Inhabers, 04.11.2026): `week` (1…n, `null` = „Allgemein“) und `kind`
   (`vorlesung` | `uebung` | `eigene`, Standard `eigene`). Ein Stapel zu einem Dokument (POST mit `file_id`, `stack_name`
   der KI-Karten, automatischer Dokumentstapel) bekommt ohne eigene Angabe die Art aus der Einordnung des Dokuments
   (`study.effective_type`/`StudyClassify.effectiveType`: Vorlesungsfolien → `vorlesung`, Übungsblätter → `uebung`, sonst
   `eigene`) und die Lehrwoche aus Dateiname/Ordner (`week_hint`), wenn bekannt; eigene Angaben gehen vor. iPad: Filterzeile
   „Alle · Allgemein · W1 … Wn“ (nur Wochen, die vorkommen) und Etikett je Stapel („Übung · W3“); Web dieselben Felder und
   derselbe Filter. Teilen und geteilte Wochenstapel: Abschnitt „Einmal erzeugen, alle profitieren“ unten. Die
   Migration vergibt `eigene`/`null`.
8. **Dokument endgültig löschen:** seine Karten gehen weg (wie bisher); ein dann leerer Stapel des Dokuments auch, ein
   Stapel mit weiteren Karten bleibt ohne Quelle (`file_id = NULL`).

## Endpunkte (Python und Kern gleich)

| Aufruf | Rumpf / Parameter | Antwort |
|---|---|---|
| `GET /api/flashcard-stacks` | – | Stapel (neueste zuerst) mit `file_name`, `cards`, `due` (heute fällig, ohne versteckte) |
| `POST /api/flashcard-stacks` | `name` (Pflicht, 422 „Name des Stapels fehlt“), `subject` (Text oder null, sonst 422; ohne Angabe das Fach des Dokuments), `file_id` (vorhandenes Dokument, sonst 404 „Dokument nicht gefunden“; kein Text: 422), `week` (ganze Zahl ab 1 oder null, sonst 422 „week: ganze Zahl ab 1 oder null erwartet“), `kind` (`vorlesung`/`uebung`/`eigene`, sonst 422 „kind: vorlesung, uebung oder eigene erwartet“; ohne Angabe aus dem Dokument) | der Stapel |
| `PATCH /api/flashcard-stacks/{id}` | `name`, `subject` (die Karten folgen), `file_id` (auch null), `week`, `kind` | der Stapel; 404 „Stapel nicht gefunden“ |
| `DELETE /api/flashcard-stacks/{id}?move_to=` | ohne `move_to`: Karten weg; mit: Karten in den Zielstapel (404 „Zielstapel nicht gefunden“, 422 wenn gleich) | `{ok, moved, deleted}` |
| `GET /api/flashcards?stack_id=&due=1&file_id=` | `stack_id` ganze Zahl (sonst 422) | Karten mit `file_name` und `stack_name` |
| `POST /api/flashcards` | `cards`, `file_id`, dazu `stack_id` (404 wenn unbekannt; die Karten bekommen sein Fach) oder `stack_name`, sonst automatischer Stapel | `{ok, count, stack_id}` |
| `PATCH /api/flashcards/{id}` | wie bisher `bookmarked`, `hidden`, `last_result`; neu `question`, `answer` (nicht leer, sonst 422 „Frage und Antwort dürfen nicht leer sein“; ohne Leerraum außen), `subject` (Text oder null), `stack_id` (ganze Zahl, sonst 422; unbekannt 404 „Stapel nicht gefunden“; ohne `subject` bekommt die Karte das Fach des Stapels) | die Karte; 404 „Karteikarte nicht gefunden“ |
| `POST /api/flashcards/{id}/review` | wie bisher | setzt zusätzlich `last_practised` des Stapels |

## Schema und Migration

- Tabelle `flashcard_stacks (id, name, subject, file_id, created_at, last_practised, week, kind)` in `db.SCHEMA` (auch `SchemaSQL.swift`);
  Spalte `flashcards.stack_id INTEGER` per `add_col` (bleibt hinter `last_result`, damit alte und neue Datenbanken dasselbe
  Schema haben).
- `db.FLASHCARD_STACK_SQL` = `Migrations.flashcardStackSQL` (wörtlich gleich, vier Anweisungen, idempotent): Karten ohne
  Stapel bekommen einen. Karten eines Dokuments den Stapel dieses Dokuments (Name = Titel, sonst Dateiname, sonst die
  Kennung; eine Zeile je `file_id`), die übrigen je Fach „Allgemein“, ohne Fach „Ohne Modul“. `created_at` des Stapels =
  älteste Karte (deterministisch für die Fixtures). Läuft bei jedem Start (`init_db`, `Migrations.steps`) und vor dem Lesen
  der Karten und Stapel (`GET /api/flashcards`, `GET /api/flashcard-stacks`), damit auch Karten aus einem Abgleich mit einem
  älteren Gerät einen Stapel haben. Fixture: `packages/shared-contracts/fixtures/schema/legacy.json` (Zeilen `flashcard_stacks`).
- Geräte-Abgleich (G2, `app/sync.py`, `DeviceSync.swift`): neue Entität `flashcard_stacks` vor `flashcards`,
  `flashcards.stack_id` als Fremdschlüssel; natürlicher Schlüssel `(name, subject, file_id)`. Fixture `sync/cases.json` neu erzeugt.
- Datenexport eines Kontos (`app/account_export.py`): die Stapel liegen in `lernapp.db` (Tabelle `flashcard_stacks`), die
  LIESMICH nennt sie. Demo-Inhalte: `DELETE … flashcard_stacks WHERE file_id LIKE 'demo-%'` beim Abschalten.
- Community: Karteikarten werden nur stapelweise geteilt (`app/community_cards.py`, Abschnitt unten); übernommene Karten
  bekommen einen eigenen Stapel mit dem Namen der Quelle.
- Neue Spalten (per `add_col`, auch `SchemaSQL.swift`/`Migrations.swift`): `flashcard_stacks.source` (`week` |
  `community` | NULL), `source_ref` (Schlüssel des Wochenstapels bzw. Kennung des geteilten Stapels), `shared_id`
  (Kennung des eigenen geteilten Stapels, NULL = privat). Sie reisen im Geräte-Abgleich mit (gewöhnliche Spalten).

## Tests

- Python: `tests/test_flashcard_stacks.py` (Stapel-CRUD, geschlossenes Üben, Bearbeiten ohne Fachverlust, Löschen mit Umzug,
  Migration alter Datenbanken, Dokument löschen, Sync/Export), Fixture-Prüfung in `tests/test_flashcards_hidden.py`.
- Kern: `LocalFlashcardTests` (Szenario `stapel` gegen die Fixture, Tabellen `flashcards` und `flashcard_stacks`,
  Einzeltests), `SQLiteStoreTests` (Schema, Legacy-Migration), `DeviceSyncTests`, `LocalBackendTests` (App-Pfade).
- iPad: `FlashcardsAppTests` (Stapel je Modul, Auswahl nach dem Anlegen, Wiederholung nur im Stapel, Bearbeiten aus Liste,
  Wiederholung und Trainer, Stapel-Dialoge), `FlashcardTrainerTests`, `AIViewsAppTests` (Composer mit Stapelwahl).
- Web: `tests/js/flashcards.test.mjs` (Gruppierung, Stapelzeile, Vorgaben, Prüfung und PATCH-Rumpf beim Bearbeiten).
- Teilen (unten): `tests/test_flashcard_share.py` (Python, Fixture `cardshare/cases.json`), `CardStackShareTests` (Kern),
  `CardStackShareAppTests` (iPad, CloudKit-Nachbau), `tests/js/flashcards.test.mjs` (Wochenstapel, Teilen).

## Einmal erzeugen, alle profitieren: geteilte Wochenstapel und Stapel teilen (Entscheidung vom 04.11.2026)

Python `app/cardshare.py` (Wochenstapel, Pool `shared_card_stacks` in library.db), `app/community_cards.py` und
`app/community_cards_api.py` (Modul-Community, Tabellen `card_stacks`, `card_stack_likes`, `card_stack_reports` in
community.db), Routen der Wochenstapel in `app/server.py`. Kern `LocalBackend/Flashcards/CardStackShare.swift` und
`Endpoints/CardStackEndpoints.swift`; iPad `Services/CardStackCloudKit.swift`, Seite `CardsPage.swift`
(`FlashcardDeck`, `FlashcardWeekFetchDialog`); Web `flashcards.js` (Regeln ohne DOM) und `viewCards` in `views-misc.js`.
Gleiche Erwartungswerte: `packages/shared-contracts/fixtures/cardshare/cases.json` (`tools/gen-cardshare-fixture.py`).

### Regeln

1. **Wochenstapel**: je Modul und Lehrwoche zwei erzeugte Stapel, Art `vorlesung` (Dateien der Woche mit
   `doc_type` vorlesung/skript) und `uebung` (uebung/loesung). Erzeugt nur auf Wunsch („Karten für Woche n holen“ in der
   Karteikarten-Ansicht, je Modul bei gewählter Woche oder über „Karten für eine Woche holen …“), nie im Hintergrund.
2. **Schlüssel** `cs1:` + sha256 über `{kind, materials (sortierte eindeutige Inhalts-Hashes), uni, v}` – ohne Nutzer,
   Modulname und Wochennummer: wer dieselben Dateien hat, bekommt denselben Stapel. Fehlt einer Datei der Hash, wird nicht
   geteilt (Status `unshared`, eigener Stapel). Varianten wie Wochentests (`testshare.variant`/`pick`, höchstens 3 je
   Schlüssel, Platz belegen, verwaiste Belegung nach 10 Minuten frei, Scheitern gibt den Platz frei); Übernehmen = 0 Credits.
3. **Übernehmen** legt einen lokalen Stapel an: Name „Vorlesung Woche n“ / „Übung Woche n“, `kind`, `week`, `source =
   week`, `source_ref` = Schlüssel; Karten Fach 1, heute fällig; Lernstand privat. Ein vorhandener Wochenstapel kommt
   zurück (`exists`), keine zweite KI-Anfrage.
4. **„Woche n komplett“** ist eine Übungsoption (Trainer), wenn beide Wochenstapel da sind: erst die Vorlesungskarten,
   dann die Übungskarten, je in der Reihenfolge des Anlegens. Kein dritter erzeugter Stapel.
5. **Stapel teilen** (freiwillig, Standard privat): je Stapel, nie einzelne Karten, nur Stapel eines Moduls mit Karten.
   Kopie (Frage, Antwort) unter dem Community-Schlüssel des Moduls (`community_module_key` = `CommunityKeys.courseKey`),
   ohne Lehrwoche unter „Allgemein“, sonst unter der Woche; Autor nur als Pseudonym. Der eigene Stapel trägt danach
   `shared_id`. Zurückziehen nur durch den Autor; wer übernommen hat, behält seine Kopie. Kein Teilen über Module hinweg
   (Gruppen-Communities: 422 `community_invalid`).
6. **Geteilte Stapel anderer** stehen in der Karteikarten-Ansicht je Modul (Wochenfilter wie die eigene Liste),
   meistgelikte zuerst; „Übernehmen“ kopiert (`source = community`, `source_ref` = Kennung, zweimal = derselbe Stapel),
   Like und Melden wie Lösungen (einmal je Konto, ab `REPORTS_TO_HIDE` Meldungen verborgen im Dienst; CloudKit über die
   Moderation). Gesperrte und gebannte Autoren erscheinen nicht.

### Endpunkte (Python im Dienst, Kern über CloudKit; Fehler `{detail, code}`)

| Aufruf | Antwort / Regeln |
|---|---|
| `GET /api/flashcard-stacks/week/{module_id}/{week}/{kind}` | `{stack (oder null), files, name, shareable}`; nichts erzeugt |
| `POST /api/flashcard-stacks/week/{module_id}/{week}/{kind}` | `{stack, status: exists / adopted / generated / unshared, variant (1–3), of: 3, credits}`; 404 `no_materials`; 422 bei `kind` ≠ vorlesung/uebung oder `week` < 1; im Dienst Pro AI (`can_use_ai_generated_questions`) und bestätigte E-Mail (403) |
| `POST /api/flashcard-stacks/{id}/share` | Zusammenfassung des geteilten Stapels + `stack`; 409 `already_shared`, 422 `no_module`/`stack_empty` |
| `DELETE /api/flashcard-stacks/{id}/share` | `{withdrawn, already, stack}`; 404 `not_shared`, 403 `not_owner` |
| `GET /api/community/card-stacks?module_id= (oder module=)&week=` | `{community_key, stacks: [{id, name, kind, week, cards, pseudonym, likes, liked_by_me, reported_by_me, mine, adopted, …}]}`; `week=0` = Allgemein |
| `GET /api/community/card-stacks/{id}` | dazu `cards_list` |
| `POST /api/community/card-stacks/{id}/adopt` | `{stack, already, count}`; 404 `module_not_here` |
| `POST`/`DELETE /api/community/card-stacks/{id}/like`, `POST …/report {reason, note}` | `{id, liked, likes}` bzw. `{reported, hidden, reports}` |
| `GET /api/community/card-stacks/mine` | nur Python (eigene geteilte Stapel) |

Ohne Dienst: Python 501 `not_hosted` (Einzelplatz erzeugt Wochenstapel selbst, Status `unshared`), Kern 503
`not_available` ohne iCloud-Container, 503 `community_unavailable` bei CloudKit-Fehlern. Die Windows-App (Einzelplatz mit
verbundenem Konto) leitet `/api/community/...` an den Dienst weiter, kennt dort aber keine lokale `module_id`: Teilen
und geteilte Stapel sind dort noch nicht verfügbar (offen), Wochenstapel entstehen als eigener Stapel. Die Oberflächen blenden das
Teilen dann aus.

### CloudKit-Datensätze (öffentliche Datenbank; vom Koordinator in `apps/apple/Config/cloudkit-schema.ckdb` zu übernehmen)

```
    RECORD TYPE WeekCardStack (
        "___createTime"  TIMESTAMP,
        "___createdBy"   REFERENCE,
        "___etag"        STRING,
        "___modTime"     TIMESTAMP,
        "___modifiedBy"  REFERENCE,
        "___recordID"    REFERENCE QUERYABLE,
        shareKey         STRING QUERYABLE,
        variant          INT64,
        status           STRING,
        payload          STRING,
        createdAt        STRING,
        ownerRecordName  STRING,
        GRANT WRITE TO "_creator",
        GRANT CREATE TO "_icloud",
        GRANT READ TO "_world"
    );

    RECORD TYPE CardStackShare (
        "___createTime"  TIMESTAMP,
        "___createdBy"   REFERENCE,
        "___etag"        STRING,
        "___modTime"     TIMESTAMP,
        "___modifiedBy"  REFERENCE,
        "___recordID"    REFERENCE QUERYABLE,
        communityKey     STRING QUERYABLE,
        kind             STRING,
        week             INT64,
        name             STRING,
        cardCount        INT64,
        displayName      STRING,
        payload          STRING,
        createdAt        STRING,
        ownerRecordName  STRING,
        withdrawn        INT64,
        GRANT WRITE TO "_creator",
        GRANT CREATE TO "_icloud",
        GRANT READ TO "_world"
    );
```

- `WeekCardStack`: recordName `<shareKey>#<variant>` (Anlegen atomar je Variante); `status` pending|ready; `payload`
  verschlüsselt wie `WeeklyTest` (HKDF aus den Inhalts-Hashes, AES-256-GCM; Klartext `SharedWeeklyTest` mit `title` =
  Art und den Karten), leer bei pending. Felder und Rechte wie `WeeklyTest`.
- `CardStackShare`: recordName = UUID (klein, = `shared_id`/`source_ref`); `week` 0 = Allgemein; `payload` verschlüsselt
  mit dem Modul-Geheimnis (`CommunityKeys.secret`, AES-256-GCM, Zusatzdaten binden `communityKey` und Kennung), leer nach
  dem Zurückziehen (`withdrawn` = 1). Kein Name, keine E-Mail, kein Modulname, kein Lernstand.
- Likes und Meldungen: vorhandene Typen `Like` und `Report` mit `solutionID = "cards:<Kennung>"` (kein neuer Typ).
- Fabriken nur mit iCloud-Container (`CardStackCloudFactory.makeWeek()`/`makeCommunity()`, sonst nil →
  Wochenstapel als eigener Stapel, Teilen nicht verfügbar).

### Kosten

Ein Wochenstapel ist eine KI-Anfrage über den vorhandenen Karteikarten-Weg (`_flashcards_complete` im Dienst mit
Kontingent und Credits, `AIPrompts.flashcards` im Kern): 20 Karten verlangt (`WEEK_CARDS`), Deckel 30 je Satz
(`FLASHCARDS_MAX`, auch beim Übernehmen), Eingabe höchstens 10 Dateien × 3.500 Zeichen (rund 9.000–12.000 Tokens),
Ausgabe höchstens 3.000 Tokens. Erwartet je Satz mit dem empfohlenen Modell `gpt-6-luna` (0,10 $/0,50 $ je Mio.
Tokens): **rund 0,2–0,3 ct, also 1 Credit**; mit `gpt-5.4-mini` höchstens rund 2,3 ct. Je Modul und Woche entstehen
höchstens 2 Arten × 3 Varianten = 6 Sätze, egal wie viele Studierende das Modul haben (mit `gpt-6-luna` unter 2 ct je
Modul und Woche, rund 0,25 € je Modul und Semester mit 14 Wochen); alle weiteren übernehmen für 0 Credits.

## KI-Karteikarten auf Auftrag (Pro AI, nur Dienst und PC; Cloud-Sitzung 04.11.2026, ans Stapel-Modell angepasst)

„Analysis I, Lernwoche 5, 30 Karten“: `POST /api/ai/flashcards` mit `module_id` statt `file_id` (`app/server.py`
`_ai_flashcards_order`, Hilfen in `app/flashcard_order.py`). Rumpf `{module_id, week (auch lecture_week; null = ganzes
Modul), count (5–50, Vorgabe 20), topic?, request_id?, material?: [{title, text}], again?}`, Antwort `{cards, count,
module_id, module_name, week, sources, duplicates_removed, existing, credits}`. Material genau dieser Woche: zuerst die
mit „Vorlesung bis hier“ markierten Seiten der Woche, dann Vorlesungen/Skripte, dann Übungen der Woche (höchstens 24.000
Zeichen); ganzes Modul: Vorlesungen aller Wochen gleichmäßig. Vorhandene Fragen der Stapel des Moduls (Fach = Modulname,
Stapel der Woche zuerst) stehen im Prompt („nicht wiederholen“) und werden danach noch einmal ausgefiltert (gleiche
oder fast gleiche Frage, Wortüberschneidung ≥ 0,85). Nur ein Vorschlag: die Oberfläche legt den Stapel „KI · Woche n“
(Art `eigene`, Woche des Auftrags) an bzw. nimmt einen gleichnamigen des Moduls und speichert mit `POST /api/flashcards`
(`stack_id`). Wochenauswahl: `GET /api/ai/flashcards/weeks?module_id=` (Wochen mit Unterlagen, aktuelle Woche).
Im Dienst: `can_use_ai_generated_questions` (Pro AI), bestätigte E-Mail, Kontingent `ai_assist`, Credits und dieselbe
`request_id`-Wiederholung wie „Karteikarten aus Dokument“ (`_flashcards_complete`); ohne brauchbare oder nur doppelte
Karten 502 `ai_no_cards` und `ai_assist` zurückgebucht; ohne Material 404 `no_content`. Unterschied zu den Wochenstapeln
oben: persönlich (Anzahl, Schwerpunkt, ohne Doppel zu den eigenen Karten), nicht geteilt.
Tests: `tests/test_flashcard_order.py`, `tests/test_flashcards_hosted.py`, `tests/js/flashcard-stacks.test.mjs`,
Browser `tests/test_web_flashcard_stacks.py`; Prüfdaten `fixtures/flashcards/stacks.json` (Teil `ai_stack`).

## Ergänzungen im Dienst (Cloud-Sitzung 04.11.2026)

- **Geteilte Kopie aktualisieren:** `PUT /api/flashcard-stacks/{id}/share` ersetzt Karten und Namen der geteilten Kopie
  durch den aktuellen Stand (Kennung, Likes, Übernahmen bleiben; `update_user`; verborgen 403 `stack_hidden`).
- **Liste:** `GET /api/community/card-stacks` liefert zusätzlich `weeks` (Zahl der Stapel je Woche, `"0"` = Allgemein).
- **Grenzen:** neue geteilte Stapel `deck_user` 10 je Konto und Tag; gebannte Autoren teilen nicht (403 `author_banned`).
- **Moderation:** `GET /api/community/moderation` → `card_stacks`; `POST /api/community/card-stacks/{id}/moderate
  {action: restore}`. Bann und Konto löschen ziehen geteilte Stapel sofort zurück; Datenexport
  `community/meine-karteikarten.json`.
- **Geräte-Abgleich:** neue `flashcards` und `flashcard_stacks` (ohne `id`) nur mit `can_use_flashcards`, sonst
  `plan_required` (`required_plan: plus`); bestehende gleichen weiter ab.
- **Web:** Reiter „Karteikarten“ im Community-Kanal (`community-decks-ui.js`), „KI-Karteikarten“ und „Geteilte Kopie
  aktualisieren“ auf der Seite „Karteikarten“. Tests: `tests/test_community_decks.py`.
- **Offen fürs iPad:** KI-Karteikarten auf Auftrag und fertige Wochenfragen gibt es nur über den Dienst (iPad: „in
  Vorbereitung“); Ersetzen und Moderation geteilter Stapel nur im Dienst (CloudKit: Zurückziehen und neu teilen).
