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

## Web und Windows (05.11.2026)

Seite `#/studyplan` (Seitenleiste „Studienverlauf“ nach „Meine Module“, Knopf „Im Studienverlauf“ im Modul): `app/static/study-plan.js`
(Ansicht) und `study-plan-logic.js` (Regeln und HTML, `tests/js/study-plan.test.mjs`) nach dem Vorbild von `StudyPlanPage.swift`: Kopf mit
Ring, PO bestätigen, Hinweise, Karte „Nachholen im nächsten passenden Semester“ (nicht bestandene und liegengebliebene Module mit
Ziel-Semester), Filter, Semester-Spalten (schmal untereinander), Moduldetail, Einstellungen, Katalogsuche mit Fortschritt, Link zum
Modulhandbuch und **Studiengang wählen** (Register mit allen Studiengängen, ein Kürzel als `settings.po`, auch ohne QIS).
Backend (nur Python, `app/study_catalog.py`): `GET /api/study-catalog/status` stößt die Suche im Hintergrund an (Regel wie im Kern: nie
gesucht, Wiederholung fällig, `inputs` geändert), `POST /api/study-catalog/sync`, `GET /api/study-catalog/programs`; Modultexte werden am
eigenen PC nachgeladen (`texts_loading`), im Dienst nie. Grundstock und Register liegen jetzt auch im Windows-Paket
(`uniflow-backend.spec`) und im Docker-Image (`deploy/Dockerfile`, `.dockerignore`).
Offen: Der Grundstock enthält in Prüfungs-/Studienleistung und Bereichsnamen bei etwa 35 Katalogen Literaturlisten und
Beschreibungstexte (`tests/test_study_web.py`, xfail); die Oberfläche kürzt solche Felder auf 180 Zeichen.

## Wahlbereiche (05.11.2026)

Auftrag des Inhabers: Vertiefungsfächer, Seminare und Studium generale fehlten im Semesterplan; der Modulkatalog weiß,
was man wählen kann oder muss.

**Daten.** Optionale Bereichsfelder im Katalog (`study-catalog.schema.json`, `v` bleibt 1, ältere Datensätze gültig):
`areas[].modules` (alle in dem Bereich wählbaren Module, auch wenn `module.area` ein anderer Bereich ist), `rule`
(Regeltext, ≤ 500 Zeichen), `modules_required`, `group` (Bereiche einer Gruppe sind Alternativen: eins wählen),
`type`, `semester` (empfohlenes Fachsemester für offene Plätze). Woher:
- modkat (FEI, neuere Form): `modkat_area_extras` in `app/study_catalog.py` liest je Kompetenzbereich die Regel unter
  „Information zum Kompetenzbereich“ („Der Studienschwerpunkt ist absolviert, wenn mindestens vier Module …“ →
  `modules_required` 4) und alle Module der Bereichstabelle, auch zweistufige Tabellen „Modul Modul LP SWS“ (bisher
  verloren: MechBSc25 hatte keinem Modul einen Bereich gegeben, ETBSc25 alle Schwerpunkt-Module im Bereich
  Schlüsselkompetenzen). Nur im Grundstock (`tools/build-luh-seed.py`); der Leser selbst und sein Swift-Gegenstück
  bleiben gleich, ein vom Gerät selbst geladener Katalog hat diese Felder nicht (Typ und Gruppen leitet der Kern dann aus
  den Namen ab).
- „Schwerpunkt …“-Bereiche bilden die Gruppe `schwerpunkt`; „Allgemeine …“ mit derselben Spanne („0 - 25 LP“) gehört als
  Wahl ohne Schwerpunkt dazu (ET, Mechatronik). „Nebenfach …“/„Anwendungsfach …“ → Gruppe `nebenfach`.
- Formate A/B (`formats_a_common.build_catalog`): dasselbe Modul in mehreren Bereichen (z. B. je Vertiefungsrichtung im
  Maschinenbau) steht weiter einmal im Katalog, die weiteren Bereiche jetzt in `areas[].modules`.
- Von Hand aus Prüfungsordnung (Anlage 1) und Modulkatalog: `packages/shared-contracts/study-area-rules-luh.json`
  (Maschinenbau B.Sc. PO 2026: drei Vertiefungsrichtungen als Gruppe, je 5 LP Pflicht + mindestens 5 LP Wahlpflicht,
  Berufsqualifizierung; Mathematik B.Sc.: 40 LP / mindestens 4 Wahlpflichtmodule, Schlüsselkompetenzen 5 LP,
  Anwendungsfach 18 LP, Fachsemester der Pflichtmodule; Wirtschaftswissenschaft B.Sc.: je 20 LP Wahlmodule BWL/VWL im
  5./6. Semester, Schlüsselkompetenzen/Studium Generale 5–8 LP). Die drei POs liegen in `~/Studora-Builds/luh-po/`
  (3 Abrufe, ≥ 3 s Abstand).

**Kern** (`compute` in `app/study_plan.py`, gleich in `StudyPlanEngine.swift`, Fixture-Fälle `wahlbereiche_offen`,
`schwerpunkt_gewaehlt`, `schwerpunkt_aus_qis`, `wahlbereich_ohne_lp*`, `selbst_verschoben`): je Bereich Typ (aus dem Namen:
studium_generale, schluessel, seminar, labor, projekt, praktikum, schwerpunkt, nebenfach, vertiefung; sonst die Art),
Art aus den Modulen (Pflicht / Wahlpflicht / Wahl), Ziel-LP (`lp_required`, bei gewähltem Schwerpunkt `lp_max`), Stand
(bestanden, geplant, offen; jedes Modul zählt einmal, im eigenen Bereich, sonst im ersten aktiven mit Platz). Gruppe:
Einstellung `tracks`, sonst der Bereich mit den meisten LP bestandener/angemeldeter Module (`auto`); Pflichtmodule eines
nicht gewählten Schwerpunkts fehlen im Plan. Plätze je Semester (`semesters[].slots`, `lp_slots`): freie Plätze des
Studienverlaufsplans (erst Bereiche mit offenen LP, dann Spannen bis zur Obergrenze); Bereiche ohne Plan-Platz aus den
offenen LP (Median-LP der Module je Platz; Module unter 3 LP: ein Platz), aus der Zahl der Module, oder – ohne Angabe –
ein Platz, solange nichts gewählt ist (höchstens vier je Plan); Semester: `areas[].semester`, sonst Median der
empfohlenen Semester der Module, sonst (Studium generale, Schlüsselkompetenzen, Seminar) die Mitte, sonst das vorletzte
Fachsemester, jeweils das mit der geringsten Last ab jetzt; Gruppe ohne Wahl: ein Platz „Schwerpunkt wählen“.
Eigene Einträge (`custom`: Titel, LP, Bereich, Fachsemester, ids `eigen-<n>`) zählen im Bereich; eine nicht
zugeordnete QIS-Zeile mit gleichem Namen liefert Stand und Note. Neue Felder im Plan: `areas`, `groups`, `excluded`,
`placements`, je Modul `placed`, `hints`, `custom`, je Wahlmodul `areas`, `turnus`, `excluded`.

**iPad** (`StudyPlanEditing.swift`, `StudyPlanPage.swift`, `StudyPlanSheets.swift`): gestrichelte Platz-Karten in den
Semesterspalten („Seminare (5 LP)“, „Studium Generale (4 LP)“, „Schwerpunkt wählen (25 LP)“ mit „1 von 3 Modulen
gewählt“ / „noch 10 von 15 LP offen“, Etikett Pflicht/Wahlpflicht/Wahl und Typ); Tippen öffnet die Auswahl mit den
erlaubten Modulen (LP, Art, Turnus, empfohlenes Semester, Bereich; aufgeklappt Prüfung und Kurztext aus dem Detail,
Turnus-Warnung, „In WiSe 27/28 wählen“) und dem eigenen Eintrag. Kasten „Bereiche und Wahl“: Gruppe (gewählt / aus QIS /
noch nicht gewählt) und je Bereich Fortschritt LP bestanden/geplant/Ziel, Zahl der Module; „Nicht belegt“ mit „Zurück
in den Plan“. Einstellungen: Abschnitte „Schwerpunkt“ und „Eigene Einträge“.

**Abdeckung im Grundstock (152 Kataloge):** Wahlbereiche erkannt in 106, offene Plätze im Plan in 102 (324 Plätze),
Schwerpunkt-/Nebenfach-/Vertiefungsgruppen in 11 (ET, Mechatronik, Informatik B.Sc./M.Sc., Maschinenbau …), Vertiefung/
Schwerpunkt/Nebenfach als Bereich in 30, Studium generale/Schlüsselkompetenzen in 28, Seminar/Labor/Projekt/Praktikum in
18, Ziel-LP für Wahlbereiche in 21, Regeltext in 18, Mehrfach-Zugehörigkeit in 28, Zahl der Module in 4, Plätze aus dem
Studienverlaufsplan in 2 (TI, Informatik). Beispiele: Informatik B.Sc. 9 Plätze (Proseminar, Vertiefung, Wahl(pflicht)
SG/Inf/PI/M/N) und „Nebenfach wählen“ (10 Nebenfächer); ET B.Sc. 6 Plätze, Gruppe Schwerpunkt mit 6 Optionen inkl.
Allgemeine ET. Grenzen: viele Kataloge außerhalb der FEI nennen keine LP je Wahlbereich (dann ein Platz „N Module zur
Wahl“); Anwendungsfächer (Mathematik) stehen in fremden Katalogen (eigener Eintrag); die Regel „Allgemeine ET höchstens
5 LP bei gewähltem Schwerpunkt“ steht nur als Text da. Web/Windows zeigen Plätze, Bereiche und Verschieben seit
05.11.2026 (Abschnitt „Web: selbst gestalten“).

## Eigene Lage: verschieben, vorziehen, nicht belegen (05.11.2026)

Auftrag: „kann man im studienverlaufsplan auch module selber anwählen und verschieben und in ein anderes semester packen
… dann weiß man okay man hat 3 vorgezogen und hat im dritten zeit für andere“.

**Einstellungen** (`settings.study_plan`, gleich in Python und Swift, teilweise speicherbar, nur nicht leer gespeichert):
`placements: {Modul-id: "WiSe 27/28"}`, `excluded: [ids]` („Nicht belegen“), `tracks: {Gruppe: Bereich}`, `custom: [...]`.
400 bei falschem Typ oder unlesbarem Semester. Regeln im Kern: die eigene Lage gilt für Pflicht-, Wahlpflicht- und
gewählte Wahlmodule, ohne Verschieben nach Turnus, Voraussetzung oder 36-LP-Ausgleich (der Ausgleich verschiebt nur
nicht selbst gelegte Wahlmodule); Bestandenes bleibt im Semester aus QIS; ein nicht bestandenes Modul folgt der eigenen
Lage, wenn sie frühestens beim nächsten möglichen Versuch liegt (sonst wie bisher nächstes passendes Semester); eine Lage
in der Vergangenheit wird „Noch nicht abgelegt – nachholen“. Hinweise je Modul (`hints`): „Laut Katalog nur im
Wintersemester angeboten“, „Voraussetzung … liegt nicht davor“ / „… ist nicht im Plan“. Die Prüfungsanmeldung
(`ExamRegistration`, gleicher `compute`) schlägt Module im Semester ihrer eigenen Lage vor.

**iPad:** Board quer: Karten ziehen und auf einer Semesterspalte ablegen (`StudyPlanDropHub`); überall (Liste hochkant,
große Schrift, VoiceOver-Aktionen der Karte, Kontextmenü, Moduldetail): „Verschieben nach …“ mit allen Semestern ab
jetzt bis vier nach dem letzten im Plan (auch nach der Regelstudienzeit; je Zeile LP danach und Turnus-Warnung), „Ins
empfohlene Semester“, „Nicht belegen“; „Modul hinzufügen“ (beliebiges Katalogmodul in ein gewähltes Semester, auch
vorziehen), „Plan zurücksetzen“ mit Rückfrage (eigene Lage und „Nicht belegen“ weg). Karte: „Selbst eingeplant“,
Hinweise; Spaltenkopf mit LP-Summe, Warnung über 36 LP, „+ n LP offen“. Rückmeldung nach jeder Änderung (auch
vorgelesen), z. B. „3 Module vorgezogen – im 3. Semester sind jetzt 12 LP frei“.

Tests: `tests/test_study_plan_choices.py`, `StudyPlanEngineTests.testPlacementsLockingHintsAndSlots` und die
Fixture-Fälle (Kern, exakt gegen Python), `StudyPlanChoiceAppTests` (Plätze, Auswahl, Schwerpunkt, eigener Eintrag,
Verschieben über Menü/VoiceOver und durch Ablegen auf dem Board, Nicht belegen / Zurück / Zurücksetzen, Detail,
Breitenprüfung 1180 × 820 und 820 × 1180 auch mit großer Schrift).

## Wählen, tauschen, Gesamtansicht (05.11.2026)

Inhaber: „wahlpflichtmodule wenn es sowas gibt auch erkennen dann kann man klicken und sich was davon auswählen dann wird
das eingefügt und mach dass man alles auf einmal sehen kann“. Wahlpflichtbereiche werden wie oben erkannt (Art aus den
Modulen, Spanne, Name); ein Platz öffnet die Auswahl, „In WiSe 27/28 wählen“ fügt das Modul in genau dieses Semester ein
(`electives` + `placements`), der Platz zählt mit („1 von 3 Modulen gewählt“, „noch 5 von 15 LP offen“) und verschwindet,
wenn der Bereich voll ist. Ändern: „Anderes Modul wählen“ (Menü, VoiceOver, Detail; nur nicht bestandene, nicht
angemeldete Wahlmodule) zeigt die Module derselben Bereiche und tauscht im selben Semester; Entfernen: „Nicht belegen“.
**Gesamtansicht** (Umschalter „Semester | Gesamtansicht“ über dem Board, gemerkt in `@AppStorage("studyplan.overview")`):
alle Semester als Spalten ohne Rollen (quer eine Reihe, hochkant ab fünf Semestern zwei), je Modul ein Chip mit Kurzname
(`StudyPlanText.abbreviation`), LP, Statusfarbe und Warnzeichen bei Hinweisen; Chip-Höhe 14–30 pt je nach Platz;
Tippen → Detail, Ziehen auf eine Spalte, Menü und VoiceOver-Aktionen wie auf dem Board; Plätze als gestrichelte Chips.
Test: `StudyPlanChoiceAppTests.testOverviewShowsEverythingAtOnceAndKeepsMoving` (alle Chips im Fenster bei 1180 × 820
und 820 × 1180), `testReplaceChosenElectiveWithAnotherOfItsArea`.

## Für Web und iPhone

Alles kommt fertig aus dem Kern; Web/Windows (Python-Dienst, `app/study_plan.py`) und iPad/iPhone (lokales Backend,
`StudyPlanEngine.swift`) liefern exakt dasselbe JSON (Fixture `fixtures/study-plan-engine/`). Eine Oberfläche rechnet
nichts selbst, sie zeigt an und schickt Änderungen.

**`GET /api/study-plan`** (zusätzlich zu den Feldern oben):
- `semesters[]`: `term`, `fachsemester`, `current`, `lp` (Module inkl. eigener Einträge), `modules[]`, `slots[]`,
  `lp_slots`. Modul: `id, title, code, kind (pflicht|wahlpflicht|wahl|abschluss), area, lp, semester (empfohlen),
  turnus, status (bestanden|angemeldet|nicht_bestanden|offen|geplant), attempt, grade, moved_from, reason,
  last_attempt, placed (selbst gelegt), hints [Texte], custom (eigener Eintrag, id "eigen-<n>")`.
  Platz: `id ("platz-<n>"), kind (slot = Verlaufsplan | area = aus offenen LP | track = Gruppe wählen), title, area,
  areas [erlaubte Bereiche], group, type, area_kind, lp, lp_max, fachsemester`.
- `areas[]`: `id, name, type, kind, group, active, choice, lp_required, lp_max, target, modules_required, lp_done,
  lp_planned, lp_open, count, count_done, options, chosen [ids], slots, rule`.
- `groups[]`: `id, label, options [Bereichs-ids], chosen, auto (aus QIS geschlossen)`.
- `electives[]` (alle Wahl(pflicht)module): `id, title, kind, area, areas, lp, semester, turnus, chosen, included,
  status, excluded` – die Auswahl eines Platzes sind `electives` mit `!included` und einem Bereich aus `slot.areas`
  (leer = alle Wahlbereiche), dazu `excluded[]` (`id, title, kind, lp, semester`).
- `placements`: `{Modul-id: "WiSe 27/28"}` (nur wirksame).
**`GET /api/study-plan/module/{id}`**: Fakten, Texte (`texts.content` für den Kurztext), eigener Stand.
**`POST /api/study-plan/settings`** speichert nur die genannten Schlüssel (400 bei falschem Typ):
- Verschieben/Vorziehen: `{"placements": {…alle bisherigen…, "<id>": "SoSe 27"}}`; zurück ins empfohlene Semester: den
  Schlüssel weglassen. Bestandenes bleibt im QIS-Semester (Lage wird ignoriert).
- Wählen in einen Platz: `{"electives": [...bisher..., "<id>"], "placements": {..., "<id>": "<Semester des Platzes>"}}`;
  Pflichtmodul zurückholen: `{"excluded": [...ohne id...]}`.
- Tauschen: `electives` ohne alte, mit neuer id; `placements` alte weg, neue ins Semester der alten.
- Nicht belegen: Wahlmodul aus `electives` nehmen, sonst `{"excluded": [...,"<id>"]}`; seine Lage aus `placements`.
- Schwerpunkt/Nebenfach: `{"tracks": {"<group>": "<area-id>"}}`.
- Eigener Eintrag: `{"custom": [...bisherige {id,title,lp,area,semester}..., {"title", "lp", "area", "semester"}]}`.
- Plan zurücksetzen: `{"placements": null, "excluded": null}`.
Rückmeldung nach dem Verschieben wie am iPad: „<Titel> vorgezogen nach <Semester> – im <n>. Semester sind jetzt <x> LP
frei“ (bei mehreren vorgezogenen Modulen „<n> Module vorgezogen – …“), frei = 30 − LP des Ausgangssemesters.
Gesamtansicht: Spalten aus `semesters`, Chips aus `modules` + `slots`; Statusfarben wie `StudyPlanStatus.tone`
(bestanden grün, angemeldet blau, nicht bestanden rot, verschoben gelb, sonst Farbe des Bereichs).

## Web: selbst gestalten (05.11.2026)

`app/static/study-plan.js` (Seite) und `study-plan-logic.js` (Texte, HTML, Rümpfe; `tests/js/study-plan-edit.test.mjs`) setzen
„Für Web und iPhone“ um, ohne selbst zu rechnen: Plätze als gestrichelte Karten in den Spalten (Auswahl mit LP, Art, Turnus,
Semester, Bereich, aufgeklappt Prüfung, Kurztext aus `GET /api/study-plan/module/{id}` und Turnus-Warnung, „In … wählen“,
eigener Eintrag), Richtung wählen, Kasten „Bereiche und Wahl“ (Gruppe, Fortschritt je Bereich, „Nicht belegt“ mit „Zurück in
den Plan“), Menü „Aktionen“ je Karte (Knopf „…“, Rechtsklick, Umschalt+F10; Pfeiltasten, Escape): Details, „Verschieben
nach …“ (Semester ab jetzt bis vier nach dem letzten, LP danach, Warnung über 36 LP, Turnus), „Ins empfohlene Semester“,
„Anderes Modul wählen“, „Nicht belegen“, „Eigenen Eintrag entfernen“; dieselben Aktionen unten im Moduldetail. Ziehen: Maus
mit HTML5 Drag and Drop, Finger und Stift mit langem Drücken (350 ms, Pointer Events, Bild der Karte folgt dem Finger).
Bestandenes und eigene Einträge lassen sich nicht ziehen. Rückmeldung als Hinweis und vorgelesen (`role=status`), Fokus
kehrt auf die Karte zurück. „Plan zurücksetzen“ mit Rückfrage. Einstellungen zusätzlich mit „Schwerpunkt“ und „Eigene Einträge“.
**Gesamtansicht** (Umschalter „Semester | Gesamtansicht“, `localStorage` `studyplan.overview`): `overviewLayout` rechnet aus
Breite und freier Höhe (abzüglich Leiste unten am Telefon) breit Spalten in einer Reihe (hoch/zu schmal zwei) mit Chip-Höhe
14–30 px, schmal (< 600 px) Semester untereinander mit umbrechenden Chips und der größten Schrift (12,5–9,5 px), bei der alles
passt; Kurznamen wie `StudyPlanText.abbreviation`. Geprüft mit erfundenen Daten (Informatik B.Sc. PO 2022 aus dem Grundstock,
ohne Netz) bei 1440 × 900 und 390 × 844, hell und dunkel: alle 33 Chips ohne Rollen sichtbar
(`~/Studora-Builds/web-studienverlauf/`). **Abo:** am iPad ist der Studienverlauf Free; in Web/Windows gilt die Konto- und
Abo-Pflicht (Probe oder Plus/Pro AI). Ohne Abo (`gateState` = `locked`) nur lesen: Hinweis mit „Abo wählen“, keine
Knöpfe zum Ändern, nichts zum Ziehen (der Server lehnt Schreiben ohnehin ab). Prüfungsanmeldung gibt es im Web nicht
(keine Python-Route). Fund: Ein Platz aus dem Studienverlaufsplan (`kind: slot`, z. B. „Proseminar“ in INFBSc22) bleibt
stehen, auch wenn sein Bereich mit einem gewählten Modul voll ist („noch 0 von 5 LP offen“); das liefert der Kern so, auch
am iPad.
