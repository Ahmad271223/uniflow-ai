# Studienverlauf (Auftrag des Inhabers 04.11.2026)

Ziel: Kennt die App den Studiengang (QIS-Notenspiegel, Spalte `abschluss`, z. B. „Technische Informatik (PO-Version
2017)“), holt sie den offiziellen Modulkatalog und Studienverlaufsplan der Hochschule, zeigt einen persönlichen
Studienverlaufsplan (was wann dran ist, was bestanden ist, was nachzuholen ist) und erklärt jedes Modul (Inhalt, LP,
Prüfungs- und Studienleistung, Turnus, Voraussetzungen). Der Katalog eines Studiengangs wird **einmal** gebaut und
geteilt („Bibliothek“); für jede weitere Person wird nur ihr eigener Stand berechnet.

Verbindlich bleibt immer die Prüfungsordnung der Hochschule – das steht in jeder Ansicht.

## Quellen (Stand 04.11.2026)

LUH, Fakultät für Elektrotechnik und Informatik: Modulkataloge als PDF aus einer Datenbank, gleich aufgebaut,
öffentlich ohne Anmeldung, je Studiengang, Prüfungsordnung und Semester:
`https://modkat.fei.uni-hannover.de/material/modkat-full-<KÜRZEL>-<WS_JJJJ_JJ|SS_JJJJ>.pdf` (ältere Dateien ohne
`full-` dort als Spiegel; `modkat.dbs.uni-hannover.de` antwortet nicht mehr), Übersicht `https://modkat.fei.uni-hannover.de/`.
Kürzel z. B. `TIBSc25` (Technische Informatik B.Sc., neueste PO, WS 2026/27), `TIBSc22` (ältere PO, WS 2025/26),
`INFBSc22` (Informatik B.Sc.). Studienverlaufspläne der Fakultät (eine PDF-Seite je Studiengang) verlinkt auf
`https://www.fei.uni-hannover.de/studium/studienangebot/technische-informatik` bzw. `…/informatik`.
Prüfungsordnungen: `https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_techinf_bpo26.pdf` u. a.

Register der Quellen: `packages/shared-contracts/study-sources.json` (Hochschule → Studiengang → Kürzel je PO,
URL-Muster, Studienverlaufsplan-Quelle). Andere Hochschulen kommen nach und nach dazu; ohne Eintrag zeigt die App
„Für deinen Studiengang gibt es noch keinen Katalog“ mit der Möglichkeit, einen Link zum Modulhandbuch einzufügen.

Hinweis: QIS nennt beim Inhaber „PO-Version 2017“, die aktuellen Kataloge heißen „…22“. Die App schlägt die
passende Ordnung vor und lässt sie bestätigen oder ändern (Einstellung je Konto).

## Urheberrecht und Datenschutz

- Der Katalog ist öffentlich. Das Gerät lädt die PDF wie ein Browser, einmal je Studiengang und Katalogsemester.
- Lokal auf dem Gerät: der volle Modultext (Inhalte, Lernziele) zum eigenen Lesen.
- Geteilt in der Bibliothek (CloudKit `StudyCatalog`, öffentlich lesbar, keine Personendaten): nur die Fakten je
  Modul (Titel, Kürzel, LP, empfohlenes Semester, Turnus, Art, Bereich, Prüfungsform, Studienleistung,
  Voraussetzungen, Sprache, Arbeitsaufwand) und Quell-URL mit Seitenzahl – **kein** langer Beschreibungstext.
- Persönlicher Stand (bestanden, Versuche, Noten) verlässt das Gerät nie.

## Datenformat Katalog (`packages/shared-contracts/study-catalog.schema.json`)

```json
{
  "v": 1,                            // bleibt 1: study_plan und plan_slots sind optional
  "university": "luh",
  "program": "Technische Informatik",
  "degree": "B.Sc.",
  "po": "2022",
  "catalog_term": "WS 2025/26",
  "code": "TIBSc22",
  "regular_semesters": 6,
  "total_lp": 180,
  "source": {"url": "https://…pdf", "fetched_at": "…", "sha256": "…"},
  "areas": [{"id": "grundlagen-informatik", "name": "Grundlagen der Informatik", "lp_required": 50, "kind": "pflicht"}],
  "modules": [{
    "id": "programmieren-1",
    "title": "Programmieren I",
    "code": null,
    "area": "grundlagen-informatik",
    "kind": "pflicht",              // pflicht | wahlpflicht | wahl | abschluss
    "lp": 5,
    "semester": 1,                   // empfohlenes Fachsemester laut Verlaufsplan, null = frei
    "turnus": "WS",                  // WS | SS | WS+SS | unbekannt
    "exam": "Klausur 90 min",       // Prüfungsleistung
    "coursework": "Übungsaufgaben",  // Studienleistung, null wenn keine
    "prerequisites": [],             // Modul-ids
    "language": "deutsch",
    "workload_h": 150,
    "source_page": 12
  }],
  "study_plan": {"url": "https://www.fei.uni-hannover.de/…/Studienverlaufsplan_…_WS2026-27.pdf", "fetched_at": "…", "sha256": "…"},
  "plan_slots": [{"semester": 5, "title": "Wahlpflichtmodul (Vertiefung der Informatik oder Informationstechnik)",
                  "areas": ["vertiefung-der-informatik", "vertiefung-der-informationstechnik"], "lp": 5, "lp_max": null}]
}
```

Lokale Ergänzung (nicht geteilt): `module_texts` je Modul-id `{content, goals, literature}`.
Bibliotheksschlüssel: `sha256("luh|TIBSc22|WS 2025/26")`, CloudKit-Datensatz `StudyCatalog` (`catalogKey`
Queryable, `payload` JSON, `version`, `createdAt`, `ownerRecordName`).

## Persönlicher Plan

Eingaben: Katalog, QIS-Leistungen (`grades`: text, semester, status, credits, versuch, datum, note), Studienbeginn
(aus dem frühesten QIS-Semester oder Einstellung), aktuelles Semester, gewählte Wahlpflichtmodule.

Regeln:
- Zuordnung QIS-Zeile → Modul über normalisierten Titel (gleiche Regeln wie die Fach-Zuordnung der Kurse) und
  Prüfungsnummer, wenn vorhanden.
- Status je Modul: `bestanden` (abgehakt, LP gezählt), `angemeldet` (aktuelles Semester), `nicht_bestanden`
  (Versuch n), `offen`, `geplant`.
- Nicht bestanden: das Modul wandert in das nächste Semester mit passendem Turnus (WS/SS) ab dem nächsten Semester;
  Module, die es als Voraussetzung haben, wandern mit, wenn nötig. Je Semester Richtwert 30 LP; liegt ein Semester
  über 36 LP, wandert das am wenigsten dringende Wahlmodul ein Semester weiter. Beim dritten Versuch Warnung
  „Letzter Versuch – sprich mit der Studienberatung“.
- Semesterlage: WS = Fachsemester mit gleicher Parität wie der Start im WS usw.; das Fachsemester zählt ab dem
  Studienbeginn.
- Ergebnis: Semesterliste mit Name („WiSe 26/27“), Fachsemester, Modulen (Status, verschoben von, Grund), LP-Summe,
  LP bisher / gesamt, Hinweise.

- Wahlmodule ohne Fachsemester: hat der Katalog `plan_slots`, belegen gewählte Wahl(pflicht)module der Reihe nach den
  ersten freien Platz ihres Bereichs (leere Bereichsliste = jeder), Module mit QIS-Zeilen zuerst; sonst füllen sie das
  erste passende Semester bis 30 LP.

## Endpunkte (lokales Backend im Kern und Python gleich)

- `GET /api/study-plan` → `{program, po, catalog_term, available, semesters:[{term, fachsemester, lp, modules:[…]}],
  lp_done, lp_total, notes:[…], disclaimer}`; `available=false` mit `reason` ohne Katalog.
- `GET /api/study-plan/module/{id}` → Fakten, lokaler Text (falls vorhanden), eigener Stand, Kurse/Dateien in
  StudiNow, die zu diesem Modul gehören (Modul-Zuordnung der App), Quelle mit Seite.
- `GET /api/study-plan/settings`, `POST /api/study-plan/settings` `{po, start_term, electives:[ids]}`.
- `GET /api/study-catalog/status` → Stand der Katalogsuche (gefunden, geladen, aus Bibliothek, Fehler).

## Modulkatalog: Umsetzung (Katalog-Pipeline, 04.11.2026)

Dateien: `packages/shared-contracts/study-catalog.schema.json` (Format), `packages/shared-contracts/study-sources.json`
(Register), `packages/shared-contracts/fixtures/study-catalog/` (erfundene modkat-PDF, Zeilen, erwartetes JSON,
Validator-, Register- und Textfälle; Erzeuger `tools/gen-study-catalog-fixture.py [--check]`), `app/study_catalog.py`
(Python), `UniFlowCore/StudyCatalog/*` (Kern: Text, Register, Parser, Validator, Tabellen, Ablauf, PDFKit,
Endpunkt), `UniFlow/Services/StudyCatalogSync.swift` und `StudyCatalogCloudKit.swift` (iPad).

**Format.** Wie oben, dazu `areas[].lp_max` (Obergrenze bei Spannen „10 - 15 LP“, sonst `null`; `lp_required` ist
dann die Untergrenze). `lp` darf `null` sein (Katalog nennt keine LP). Verboten in den geteilten Fakten:
`module_texts` und `content`/`goals`/`literature` je Modul, Texte über 500 Zeichen. Validator in Python und Swift mit
derselben Fehlerliste („pfad: code“).

**Register.** `study-sources.json`: Hochschule → Quellen (`luh-fei-modkat`: URL-Muster
`https://modkat.fei.uni-hannover.de/material/modkat-full-{code}-{term}.pdf`, Spiegel
`https://modkat.fei.uni-hannover.de/material/modkat-{code}-{term}.pdf`) → Studiengänge mit `qis_names` und POs (`po`,
`code`, `catalog_terms`, `study_plan`). Eingetragen: Technische Informatik B.Sc. (PO 2025, `TIBSc25`, WS 2026/27, mit
Verlaufsplan; PO 2022, `TIBSc22`, WS 2025/26) und Informatik B.Sc. (PO 2022, `INFBSc22`, WS 2024/25 und WS 2026/27,
mit Verlaufsplan); weitere FEI-Kürzel stehen in `study-sources-luh.json` (Stand 04.11.2026 überholt: modkat.dbs).
Die Felder (`program`, `degree`, `regular_semesters`, `total_lp`, `qis_names`, Kürzel je PO) passen zu
`study-sources-luh.json` (breite Erhebung, anderer Auftrag): Einträge mit `catalog.format = "modkat-FEI"` lassen sich
später als `programs[].pos[]` übernehmen. Zuordnung: QIS `abschluss` ohne „(PO-Version …)“, normalisiert;
„Bachelor/B.Sc.“ bzw. „Master/M.Sc.“ filtern; PO aus QIS, wenn im Register, sonst neueste PO mit
`needs_confirmation=true`. Katalogsemester: neuestes bekanntes; ist das laufende Semester neuer, wird es einmal
angefragt (404 wird 30 Tage gemerkt).

**Parser (LUH modkat).** Zeilen: NFKC, Zeilenumbrüche vereinheitlicht, Leerraum zusammengefasst; Kopf
„Modulkatalog … (Wintersemester …) Stand: …“ und Fuß „5 / 106“ weg. Inhaltsverzeichnis (Punktführer) → Bereiche
„1.x.“ und Module mit Seite; je Modul die Felder unter ihren Überschriften (ältere Form „Frequenz der
Lehrveranstaltung“, neuere mit „Modultyp“, „Empfohlenes Fachsemester“, Titel+„Sprache“ in einer Zeile).
Turnus aus Frequenz (Winter/Sommer/jedes Semester), bei „jährlich“ aus „Angebot im WS …“ (Lehrveranstaltung → WS,
nur Prüfung → SS). Art aus „Modultyp“, sonst aus dem Bereich (Spanne oder mehr Module als LP → wahlpflicht; nennen
andere Module ausdrücklich Wahl-Pflicht, ist der Rest Pflicht; Bachelorarbeit → abschluss). Empfohlenes Semester aus
„Empfohlenes Fachsemester“ oder „Empfohlen für das n. …“. Voraussetzungen: in „Teilnahmevoraussetzungen und
-empfehlungen“ genannte Modultitel (notwendige und empfohlene). Prüfung „Klausur (K) , 90 min“ → „Klausur 90 min“,
Studienleistung „1, WiSe“ → „1 Studienleistung (WiSe)“.

Ergebnis auf dem echten TI-Katalog (WS 2025/26, 106 Seiten, nur lokal geprüft): 69 von 69 Modulen, 8 Bereiche,
Validator leer; LP 100 %, Sprache 100 %, Arbeitsaufwand 100 %, Prüfung 99 % (eine „keine“), Turnus 90 %
(Rest „unregelmäßig/unbekannt“), Studienleistung bei 22 Modulen (sonst „keine“), empfohlenes Semester nur 6/69
(der TI-Katalog hat kein Feld dafür; der Verlaufsplan steht in der PO), Voraussetzungen bei 25, Inhalt 69, Lernziele
68, Literatur 61. PDFKit und pypdf liefern auf dem TI-Katalog dieselben Fakten (Texte weichen um eine vertauschte Zeile
ab). INF-Katalog (WS 2024/25): 106/106 Module, empfohlenes Semester 33/106.

**Tabellen** (erst bei Bedarf angelegt wie `due_hits`, Schema von app/db.py unverändert, gleich in Python und Swift):
`study_catalogs(catalog_key PK, university, code, catalog_term, program, po, payload, origin, source_url, sha256,
fetched_at, stored_at)`, `study_module_texts(catalog_key, module_id, content, goals, literature)` (nur Gerät),
`study_catalog_state(key, value)` (Stand, Fehlversuche, ETag je URL, fehlende Semester, eigener Link).

**Ablauf** (`StudyCatalogPipeline`, App: `StudyCatalogSync`; Python `run_sync` ohne Bibliothek): Auslöser nach jedem
erfolgreichen QIS-Abruf (QISConnection) und über `GET /api/study-catalog/status`, wenn sich QIS-Studiengang, PO oder
eigener Link seit dem letzten Lauf geändert haben (Kern meldet das über `StudyCatalogTriggers`, die App startet im
Hintergrund). Schlüssel → lokal → Bibliothek (gültige Variante übernehmen, 0 Downloads) → PDF laden (Primär, dann
Spiegel; ohne Cookies; ETag/If-Modified-Since; höchstens einmal je Katalogsemester) → PDFKit → Parser → Validator →
speichern → Fakten teilen. Fehler: Stand `error` mit Text, neuer Versuch erst nach 24 Stunden. Eigener Link
(`settings.study_plan.catalog_url`, nur https, ≤ 500 Zeichen, gespeichert über `POST /api/study-plan/settings`):
einmal laden, LUH-Parser, sonst Stand `error` mit `reason=unknown_format` („Das Format dieses Modulhandbuchs kennt
StudiNow noch nicht.“); eigene Links gehen nicht in die Bibliothek.

Stand (`GET /api/study-catalog/status`): `{state: idle|searching|downloading|parsing|ready|seed|library|not_found|error,
message, reason?, program, degree, po, code, catalog_term, key, origin (local|seed|library|download), modules,
needs_confirmation, suggested_po, qis_label, retry_at?, error?, checked_at, inputs}`.

**CloudKit** (für den Koordinator, noch nicht in `apps/apple/Config/cloudkit-schema.ckdb`): recordName
`"<catalogKey>#<variant>"`, Anlegen atomar je Variante, nie überschreiben, höchstens drei Varianten (Wettlauf zweier
Geräte → nächste Variante).

```
    RECORD TYPE StudyCatalog (
        "___createTime"  TIMESTAMP,
        "___createdBy"   REFERENCE,
        "___etag"        STRING,
        "___modTime"     TIMESTAMP,
        "___modifiedBy"  REFERENCE,
        "___recordID"    REFERENCE QUERYABLE,
        catalogKey       STRING QUERYABLE,
        variant          INT64,
        payload          STRING,
        version          INT64,
        createdAt        STRING,
        ownerRecordName  STRING,
        GRANT WRITE TO "_creator",
        GRANT CREATE TO "_icloud",
        GRANT READ TO "_world"
    );
```

## Studienverlaufsplan (Umsetzung 04.11.2026)

**Problem.** Die modkat-Kataloge nennen das empfohlene Fachsemester kaum (TIBSc22 WS 2025/26: 6 von 69 Modulen,
INFBSc22 WS 2024/25: 33 von 106, die neuere Form ab WS 2026/27 gar nicht). Der Verlaufsplan steht als eigene PDF auf der
Studiengangsseite der Fakultät (Studienverlaufsplan_Bachelor_…_WS2026-27.pdf, aus PowerPoint: eine gedrehte Seite,
Semester als Zeilen „1." + „SEMESTER", Module als Kästen mit Titel, Lehrperson, „2V+2Ü | 5 ECTS", Summen rechts,
Legende und Fußnote „*"). Die Anlage 1 der Prüfungsordnung (f_techinf_bpo26.pdf, f_inform_bpo26.pdf) hat zwar eine
Spalte „Semester", aber keinen Verlaufsplan je Semester; die PO-Links stehen weiter als `po_document_url` im Register.

**Register.** `programs[].pos[].study_plan = {url, format: "luh-fei-verlaufsplan", page_url}` (null = keiner bekannt).
Eingetragen für `TIBSc25` (WS 2026/27, neueste TI-PO; „Technische Informatik (PO-Version 2017)" schlägt sie mit
Bestätigung vor) und `INFBSc22`; `TIBSc22` bleibt als ältere PO ohne Plan.

**Lesen** (`pdf_items`/`parse_study_plan` in app/study_catalog.py, `StudyCatalogPDF.planItems`/`StudyPlanSheet.parse`
im Kern): Textstücke mit Lage in Leserichtung (x = linke Kante, y = Zeilenmitte; pypdf aus der Textmatrix, PDFKit
Zeichen für Zeichen, weil PDFKits Zeilen weit entfernte Kästen auf derselben Grundlinie verbinden). Semesterzeilen aus
den Beschriftungen (Abstand = Median, Band von −¼ bis zur nächsten Beschriftung −¼), je Band Spalten an der linken
Kante der Titelzeilen (Toleranz 4), LP/SWS/Summen sind Nebenzeilen (rechts der letzten Spalte + Spaltenbreite
ignoriert), Titel = erster Absatz (Lücke > 0,2 × Zeilenabstand trennt die Lehrperson ab), Zeilen mit Trennstrich
verbunden („Ingenieurwissen-" + „schaften"), „Titel 5 LP" in einer Zeile getrennt, Fußnote „*…" unter dem Plan.

**Mischen** (`merge_study_plan`, `StudyPlanSheet.merge`): Kastentitel → Wörter (klein, Umlaute ausgeschrieben,
römische Zahlen als Ziffern, „inkl. …" weg): gleich → Modul (`semester` = Plansemester); Name eines Bereichs → Platz
(„Studium Generale"); Anfang mehrerer Modultitel → Platz für deren Bereiche („Proseminar"), eines Modultitels → Modul
(„Programmierpraktikum" → „Programmierpraktikum [TI]"); fast gleich (≤ 2 Zeichen, ab 12 Zeichen, eindeutig, für
Tippfehler wie „Ingeniuerwissenschaften") → Modul; enthält „wahl" → Platz für die genannten Bereiche (Kastentext plus
Fußnote; alle bedeutungstragenden Wörter des Bereichsnamens, oder das erste Wort einer Gruppe allein wie „einem
Nebenfach (N)" → alle Nebenfächer); sonst „nicht zugeordnet" (im Stand). Module ohne Kasten in Wahl(pflicht)- oder
Platz-Bereichen bekommen `semester: null`, die übrigen behalten den Katalogwert. Schema: optionale Felder
`study_plan` und `plan_slots[] {semester, title, areas, lp, lp_max}`, `v` bleibt 1, ältere Bibliotheksdatensätze ohne
die Felder bleiben gültig; beide Validatoren prüfen sie gleich (Fälle `verlaufsplan_*`).

**Ablauf.** Nach dem Katalog wird der Plan einmal geladen (ohne Cookies, ETag/304, 404 → 30 Tage gemerkt, Fehler →
24 Stunden Pause, Stand `study_plan: {state: merged|missing|error, url, entries, slots, unmatched}`), gelesen, in
`study_catalog_state` (`plan:<url>`) abgelegt und vor dem Speichern und Teilen eingemischt. Lokale Kataloge ohne Plan
werden beim nächsten Lauf ergänzt; aus der Bibliothek wird die Variante mit Plan bevorzugt, eine ältere ohne Plan wird
ergänzt und als neue Variante geteilt.

**Modulkatalog neuere Form (modkat-full, ab WS 2026/27).** Inhaltsverzeichnis mit „. . . ."-Führern über mehrere
Seiten (auch eine letzte Seite mit nur einem Eintrag), Kapitel „1. Kompetenzbereiche" (Bereiche als Tabellen „Modul LP
SWS PL SL …") und „2. Details der Semesterangebote" (Module alphabetisch, Überschriften „regelhaftes Lehrangebot",
„Gewählte Prüfungsform", „SWS", „LP (ECTS)", „Inhalt und Stoffplan"). Kapitel sind keine Bereiche; der Bereich eines
Moduls kommt aus der Tabelle (Titel, dahinter die LP-Zahl), sonst über das Kürzel der Einordnung („TIBSc25 - GI - …"),
das ein anderes Modul desselben Bereichs schon zeigt (PDFKit zerreißt umbrochene Tabellenzeilen und setzt die
Nummernspalte des Inhaltsverzeichnisses als „1. 2. Kompetenzbereiche" zusammen – beides abgefangen; PDFKit und pypdf
liefern auf TIBSc25 und INFBSc22 WS 2026/27 byte-gleiche Kataloge).

**Abdeckung (nur lokal geprüft, PDFs nicht im Repo).**

| Katalog | Module | mit Semester vorher → nachher | Plätze | nicht zugeordnet |
|---|---|---|---|---|
| TIBSc25 WS 2026/27 | 85 (8 Bereiche) | 11 → 24 (alle 22 Pflicht + Einführung + BA) | 7 | – |
| INFBSc22 WS 2026/27 | 130 (18 Bereiche) | 11 → 24 | 8 | – |
| TIBSc22 WS 2025/26 | 69 | 6 → 23 | 7 | Programmierpraktikum (fehlt im Katalog) |
| INFBSc22 WS 2024/25 | 106 | 33 → 22 | 8 | Einführung in die Informatik, Statistische Methoden der Data Science (fehlen im alten Katalog) |

Alle übrigen Module ohne Semester liegen in Bereichen mit Plätzen. Offen: Im INF-Katalog gelten einige Module in
Nebenfächern als „pflicht" (Art aus dem Bereich abgeleitet), sie landen damit in jedem Plan.

## Grundstock und Register aller LUH-Studiengänge (04.11.2026)

**Grundstock.** Die geteilten Fakten aller lesbaren LUH-Kataloge liegen der App bei
(`apps/apple/UniFlow/Resources/StudyCatalogSeed/luh.json.gz` + `luh-index.json`, gebaut von `tools/build-luh-seed.py`,
Zahlen in `docs/STUDIENGAENGE-LUH-2026-11-04.md`, Abschnitt „Grundstock“). Reihenfolge der Suche je Katalogsemester:
lokal → Grundstock (Stand `seed`, „Aus dem StudiNow-Grundstock“, Herkunft `seed`, 0 Downloads, nicht geteilt) →
Bibliothek → PDF laden. Katalogsemester = Register plus Grundstock (Kataloge außerhalb von modkat kennen ihr Semester
nur aus dem Grundstock). Modultexte (nur Gerät) lädt die App erst, wenn jemand ein Modul öffnet
(`GET /api/study-plan/module/{id}` → `texts_loading: true`, `StudyCatalogPipeline.loadTexts`): einmal je Katalog die
öffentliche modkat-PDF der Quelle (ETag), nur Texte, Fakten unverändert; Fehler 24 Stunden Pause, 404 30 Tage; andere
Formate liest das Gerät nicht (Stand `unsupported`, es bleibt bei den Fakten). Python: `run_sync(..., seed=load_seed())`.

**Register.** `packages/shared-contracts/study-sources-all.json` = `study-sources.json` (gepflegt, vorn, unverändert) +
alle Einträge aus `study-sources-luh.json` (`merge_luh_registry`, erzeugt von `tools/gen-study-catalog-fixture.py`,
eingebettet als `StudySourcesData.swift`; Python und Kern nutzen dasselbe). Studiengänge vor Vertiefungen vor Fächern im
Lehramt; je Katalog eine PO: modkat → Quelle `luh-fei-modkat` (Laden möglich), sonst `luh-grundstock` (kein Download;
Kürzel = Registerschlüssel ohne „luh|“). Einträge ohne Katalog bleiben ohne PO (keine Zuordnung, wie bisher).
„Technische Informatik (PO-Version 2017)“ → TIBSc25 mit Bestätigung; „Elektrotechnik und Informationstechnik
(PO-Version 2017)“ → ETBSc17 ohne.
