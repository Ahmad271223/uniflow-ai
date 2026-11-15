# Studiengänge der Universität Hildesheim: Register, Modulkataloge, Grundstock (05.11.2026)

Auftrag: Studienverlauf für Hildesheim auf dem Stand der LUH (`docs/STUDIENVERLAUF-2026-11-04.md`,
`docs/STUDIENGAENGE-LUH-2026-11-04.md`), danach (Vorgabe des Inhabers, 05.11.2026) eine eigene, möglichst vollständige
Bibliothek. Ergebnis: Register `packages/shared-contracts/study-sources-hildesheim.json` (Abholer
`tools/hildesheim-programs.py`), Leser `app/catalog_formats/hildesheim.py` (drei Formate) und
`app/study_catalog_hildesheim_layout.py` (zwei Tabellen-Formate, seit 15.11.2026, gleich im Swift-Kern), Grundstock
`apps/apple/UniFlow/Resources/StudyCatalogSeed/hildesheim.json.gz` + `hildesheim-index.json`
(`tools/build-hildesheim-seed.py`), Wahlbereiche aus den Prüfungsordnungen in
`packages/shared-contracts/study-area-rules-hildesheim.json`. Prüfungsanmeldung (Zeiträume) steht getrennt in
`packages/shared-contracts/exam-registration-hildesheim.json`. Verbindlich bleibt immer die Prüfungsordnung bzw.
Studienordnung im Verkündungsblatt.

## Ergebnis in Zahlen

- **116 Registereinträge**: 57 Studiengänge (48 im Studienangebot, 9 nur noch im Verkündungsblatt: auslaufend oder
  Weiterbildung), 6 Studienvarianten/Tracks (Wirtschaft Plus, Umweltsicherung, Sport, Gesundheit und Leistung, English
  Applied Linguistics, Data Analytics Advanced Track/Cognitive Systems) und **53 Fächer** im Lehramt: 27 im
  Polyvalenten Zwei-Fächer-Bachelor (B.A./B.Sc.), 26 in den Mastern Lehramt an Grundschulen bzw. Haupt- und
  Realschulen (M.Ed.). Promotionen und die Lehramt-Infoseite sind nicht im Register.
- **Prüfungsordnung gefunden: 112 von 116** Einträgen (50 verschiedene PO-Dokumente, 47 geltende geladen und für die
  Wahlbereiche gelesen).
- **Modulkatalog im Grundstock: 105 von 116** Einträgen, **2 050 Module** aus 84 verschiedenen PDFs: 82 Einträge
  `hildesheim-modulbeschreibung` (66 Studienordnungen), 11 `hildesheim-modultabelle` (11 Studienordnungen der FB 2/3
  und der Erziehungswissenschaft), 12 `hildesheim-it-modulhandbuch` (7 FB-4-Handbücher). Die 11 Einträge ohne
  Katalog stehen mit Grund im Abschnitt „Grundstock“.
- **Wahlbereiche mit LP aus der PO** (`study-area-rules-hildesheim.json`): 21 Kataloge – alle IT-Studiengänge
  (Angewandte Informatik, IMIT, Umweltinformatik je B.Sc./M.Sc., Wirtschaftsinformatik B.Sc./M.Sc., Software
  Engineering, Data Analytics in drei Varianten), Zwei-Fächer-Bachelor (Professionalisierungsbereich 57 LP), Master
  Lehramt GS/HRS (Wahlpflichtfach 4 LP, Optionalbereich 5 LP), IIM-IW und IIM-SWIKK (Nebenfach 30 LP), IKÜ
  (Nebenfach 15/30 LP), Biologie (Regeln je Studienvariante); seit 15.11.2026 Informatik im Zwei-Fächer-Bachelor 2026
  (Wahlpflicht 27 LP, Regeln je Studienvariante). Barrierefreie Kommunikation braucht keine Handangabe mehr: das
  Profilmodul (10 LP, PO § 22) ist das Pflichtmodul BK 10.
- **Anfragen: 199** (alle 200), davon 143 PDFs (≈ 88 MB): 152 im ersten Lauf (Studienangebot, 52 Studiengangsseiten
  des Verkündungsblatts, 94 Studienordnungen/Modulhandbücher), 47 im zweiten (geltende Prüfungsordnungen);
  nacheinander, Abstand nie unter 2,5 s. `build`/`check` arbeiten nur aus dem Zwischenspeicher (**0 Anfragen**, das
  Skript bricht sonst ab). Obergrenze 1 500.

## Quellen

1. **Studienangebot** (`https://www.uni-hildesheim.de/studium/studienangebot/`, leitet auf den Studienfinder um): die
   Seite trägt alle 53 Angebote als JSON im Attribut `courses` (Titel mit Abschluss, Abschlussart, Kategorie, Link,
   Regelstudienzeit). Daraus Name, Abschluss, `regular_semesters` (`regular_semesters_source: "studienangebot"`).
2. **Elektronisches Verkündungsblatt** (uniQuIS, `qm/processmanagement/regulations.php?showPage=study`): je
   Studiengang eine Liste aller Ordnungen mit Jahrgang, Heft, Datum, Seite, Bezeichnung, Art (Prüfungsordnung,
   Studienordnung, Modulhandbuch, ...), zugeordneten Studiengängen und Download (`download.php?fileID=<ID>`); grün
   markiert = geltende Lesefassung (`current`). 52 Studiengangsseiten, 790 Dokumente. Geladen wurden die geltenden
   Studienordnungen mit Modulbeschreibungen, die Modulhandbücher und die geltenden Prüfungsordnungen (je Studiengang
   höchstens zwei).
3. Zuordnung Studienfinder → Verkündungsblatt von Hand (`PROGRAMS` im Skript), Fächer automatisch aus den Titeln
   „Studienordnung für das Fach X …“ der Zwei-Fächer- und M.Ed.-Studiengänge. Umbenannte Studiengänge (z. B.
   „Kreatives Schreiben und Kulturjournalismus“) stehen als zusätzliche Namen beim neuen Studiengang.

**Kennung und robots.txt.** Erster Lauf (152 Anfragen): `StudiNow-Katalogpruefung/1.0 (support@studinow.app)`; ab dem
zweiten Lauf ehrlich als `Claude-User (StudiNow-Katalogpruefung/1.0; support@studinow.app)` – Abruf durch Claude im
Auftrag des Inhabers. Die robots.txt (vor der ersten Anfrage gelesen) sperrt für `*` nur einzelne Pfade (`/intranet/`,
`/personal/`, `/wiki/` …), die nie angefragt wurden; der Crawler `ClaudeBot` ist ganz gesperrt, dieser Abholer ist
kein Crawler und meldet sich nicht als `ClaudeBot`. **Nie angefragt**: Learnweb, LSF (`lsf.uni-hildesheim.de`), CAS
(`/sso`), die Anmeldung des Verkündungsblatts (`qm/login.php`) – das Skript verwirft solche Links, bevor es etwas holt.

## Formate und Leser

| Format | Einträge | PDFs | Inhalt |
|---|---:|---:|---|
| `hildesheim-modulbeschreibung` | 82 | 66 | Studienordnung mit Anlage „Modulhandbuch“: Titelzeile, Modulnummer, ModulleiterIn, Pflicht- oder Wahlpflichtmodul, Anzahl der Leistungspunkte, Workload, Häufigkeit des Angebots, Empfohlenes Studiensemester, Prüfungs- und Studienleistungen |
| `hildesheim-modultabelle` | 11 | 11 | FB 2 (Kulturwissenschaften, Szenische Künste, Literarisches Schreiben, KGKT, KKT, PKM), FB 3 (IKÜ, Barrierefreie Kommunikation, Medientext, SuT, DaZ/DaF) und Erziehungswissenschaft: zweispaltige Tabellen, gelesen im Layout-Modus |
| `hildesheim-it-modulhandbuch` | 12 | 7 | FB 4 (Angewandte Informatik, IMIT, Umweltinformatik, Data Analytics, Software Engineering; auch englisch) |
| `hildesheim-kuerzel-modultabelle` | 2 | 2 | Fach Informatik im Lehramt ab 2026 (Heft 214): Titelzeile „INF-B1: „Titel““, Kopf „Studiensemester \| Dauer \| Häufigkeit \| Status“, LP in der letzten Spalte von „Lehr-/Lernformen; Arbeitsaufwand“ (seit 15.11.2026) |
| `hildesheim-kennnummer-tabelle` | 1 | 1 | Barrierefreie Kommunikation M.A.: Titelzeile „BK 1 Titel“, Kopf „Kennnummer \| Workload \| Credits \| Studiensemester \| Häufigkeit \| Dauer“, nummerierte Zeilen 1–11 (seit 15.11.2026) |
| `none` | 11 | – | siehe „geht nicht, weil …“ im Abschnitt „Grundstock“ (Stand der Zahlen dieser Tabelle: 05.11.; aktuell im Abschnitt „Grundstock“) |

**`hildesheim-modulbeschreibung`**: Feldnamen brechen über bis zu drei Zeilen um („Pflicht- oder / Wahlpflichtmodul:“)
und variieren je Fach (ModulleiterIn/Modulleitung/Modulverantwortlich, „Bezeichnung“, „Prüfungsart/-form“);
verglichen wird in einer Kurzform ohne Leerraum, Bindestriche und Umlaute. Modulgrenze: Titel, Modulnummer oder
Modulleitung, die im laufenden Modul schon vorkamen. Ein auf der Folgeseite wiederholter Tabellenkopf ergänzt dasselbe
Modul. Bereich aus dem Titel (Basis-/Aufbau-/Vertiefungsmodule …) oder aus Überschriften. Fehlen Leistungspunkte,
gilt Workload / 30 h.

**`hildesheim-modultabelle`**: pypdf im Layout-Modus hält die Spalten; je Seite wird die Wertspalte aus den Zeilen
bestimmt, die mit einem Feldnamen beginnen, umbrochene Feldnamen („Studienleistun- / gen“, „Präsenz des Mo- / duls im
Studien- / angebot“) werden zusammengesetzt und als „Feldname: Wert“ dem ersten Leser übergeben. Titel „Modul 2.1b“ +
Folgezeile; Modulübersichten vor der Überschrift „Modulhandbuch“/„Modulbeschreibung“ zählen nicht, Zeilen ohne
jede Angabe (Übersichtstabellen) ebenso nicht. FB 3: Kopfzeile „Studiensemester | Dauer des Moduls | Häufigkeit des
Angebots | Status Modul“ mit Werten darunter (Spalten aus der Kopfzeile) und die Zeile „Modul Gesamt … 150h 360h 10 17“
(Kontaktzeit, Selbststudium, SWS, LP). Fettdruck als vierfach wiederholte Zeichen wird zusammengezogen.

**`hildesheim-it-modulhandbuch`**: Ein Handbuch gilt für Bachelor und Master. Der Katalog eines Eintrags nimmt die
Einträge des Verzeichnisses (Seitenzahl im Handbuch → Modul) seines Abschlusses; bei Widerspruch gilt das empfohlene
Semester („MSc 1-3“). **Wirtschaftsinformatik** (B.Sc./M.Sc.) hat kein eigenes Handbuch: ihre Kataloge entstehen aus
der „Verwendung“ aller Module der drei FB-4-Handbücher.

**`hildesheim-kuerzel-modultabelle`** und **`hildesheim-kennnummer-tabelle`** (`app/study_catalog_hildesheim_layout.py`,
Swift `StudyCatalogHildesheimLayoutParser`, gemeinsame Fixture `fixtures/study-catalog-hildesheim-layout` aus erfundenem
Mustertext): gelesen im Layout-Modus; je Zeile die Zellen mit ihrer Spalte (eine Zelle endet an zwei Leerzeichen).
Informatik im Lehramt: die Feldnamen stehen links, Werte ab der Spalte, die der Tabellenkopf „Studiensemester | Dauer …“
nennt; LP = Summe der letzten Spalte je Teilmodul bzw. die Zeile mit den LP des ganzen Moduls („s. RStO …   13“);
Prüfungsform nur aus der Spalte „Prüfungsformen“; der Titel steht auf jeder Folgeseite noch einmal und zählt dort nicht.
Pflicht oder Wahlpflicht steht in „Status Modul“; verweist die Zeile auf Anlage 1, gilt deren Liste „Pflichtmodule: …“ je
Studienvariante: Pflicht ist ein Modul nur, wenn es in jeder Variante Pflicht ist, sonst Wahlpflicht (die Regeln je Variante
stehen als Handangabe am Bereich). Barrierefreie Kommunikation: Werte der Kopfzeile aus der Zeile darunter (umbrochene
Häufigkeit über die Spalte), Abschnitte über die nummerierten Zeilen; Prüfungs- und Studienleistung aus Zeile 6, sonst 7.

## Wahlbereiche und Studienverlaufspläne

Aus den geltenden Prüfungsordnungen von Hand übernommen (Fundstelle je Katalog in `source`): Leistungspunkte,
Mindestzahlen und Regeln je Bereich. Die FB-4-Kataloge haben einen Bereich je Gebiet; die Regeln der PO („Wahl-Module
aus Gebieten der Informatik mindestens 36 LP, mindestens zwei Gebiete …“) gelten für alle Gebiete eines Abschnitts
und werden deshalb über `area_patterns` (Regex auf den Bereichsnamen) gesetzt. Bereiche ohne Module im Katalog
(Nebenfach, Professionalisierungsbereich, Optionalbereich) kommen als `add_areas` hinzu.

Studienverlaufspläne: Das empfohlene Semester je Modul steht in Hildesheim in der Modulbeschreibung selbst
(„Empfohlenes Studiensemester“, FB 4 „empfohlenes Semester BSc 1“) und ist übernommen (Anteil im Abschnitt
„Grundstock“). **Geht nicht** bisher: eigene `plan_slots` aus den Modellstudienplänen (Anlage 3 der
Fach-Studienordnungen, z. B. Biologie, und Modellstudienpläne IIM/IKÜ): sie sind als mehrspaltige Tabellen je
Studienvariante gesetzt, deren Zellen pypdf zeilenweise vermischt; ein Leser dafür fehlt noch.

## Lehramt und Zwei-Fächer-Bachelor

Wie bei der LUH je Fach ein Eintrag (`kind: "fach"`, `parent_program`): „Biologie im Polyvalenten Zwei-Fächer-Bachelor“
(B.A./B.Sc., die Studienordnungen gelten für beide), „Biologie im Master Lehramt an Haupt- und Realschulen“ (M.Ed.).
`po` ist bei Fächern das Jahr der Studienordnung; die PO-Dokumente sind die des Gesamtstudiengangs. Gelten zwei
Fassungen (Mathematik 2014/2025, Sport 2014/2022, Geographie und Physik M.Ed. 2017/2026), gibt es zwei Einträge. Der
Gesamtstudiengang (Zwei-Fächer-Bachelor B.A./B.Sc., M.Ed. GS/HRS) trägt die Rahmenstudienordnung
(Professionalisierungsbereich bzw. Praxisphasen) als Katalog und die Bereiche der PO.

## QIS-/LSF-Bezeichnung

Der Hildesheimer LSF-Notenspiegel trägt vor jeder Tabelle die Zeile
`Abschluss: [82] Bachelor Studiengang: [052] B.A. <Name> PO-Version: <Jahr>` (`app/qis.py`, `GradeRows.swift`).
`parse_abschluss` (Python) und `StudySources.parseAbschluss` (Swift) lesen daraus Name, PO-Version und Abschlussart;
die LUH-Formen bleiben unverändert. `qis_labels` im Register sind **geraten** (`qis_labels_source: "geraten"`); erst
mit echten LSF-Zeilen prüfen. Die Texte des Studienverlaufs am iPad nennen an der Uni Hildesheim „LSF“ statt „QIS“
(`StudyPlanText.gradeSource`).

## Einbindung

- Gemischtes Register `study-sources-all.json` (und `StudySourcesData.swift`): study-sources.json + LUH + Hildesheim
  (+ HsH) über `merge_wide_registries`, Hochschule `hildesheim` mit der Quelle `hildesheim-grundstock`.
- App: `StudyCatalogSeed.bundled(bundle, university:)`, `StudyCatalogSeed.bundledAll` (`StudyCatalogSeeds`);
  `StudyCatalogSync.bundledSeed` nutzt `bundledAll`, der Ablauf fragt mit `settings.university`.
- PC/Web: `load_seed` liest die Grundstöcke aller Hochschulen; Abgleich und `GET /api/study-catalog/programs` nehmen
  `settings.university`, sonst die Hochschule der laufenden App.

## Erneut ausführen

```
.venv/bin/python tools/hildesheim-programs.py all      # holen, was fehlt (Obergrenze 1 500 Anfragen), Register schreiben
.venv/bin/python tools/hildesheim-programs.py build    # nur aus dem Zwischenspeicher (0 Anfragen)
.venv/bin/python tools/hildesheim-programs.py check    # Register frisch bauen und vergleichen (Exit 1 bei Abweichung)
.venv/bin/python tools/build-hildesheim-seed.py --check
.venv/bin/python tools/gen-study-catalog-fixture.py --check
.venv/bin/python -m pytest -q tests/test_hildesheim_catalog.py
```

Zwischenspeicher: `~/Studora-Builds/hildesheim/crawl/` (`index.json` mit Anfragezähler, Protokoll und robots.txt,
`cache/`). Eine URL wird nie zweimal geholt; für eine neue Fassung den Eintrag in `index.json` löschen.

<!-- grundstock:start (tools/build-hildesheim-seed.py) -->
## Grundstock (Modulkataloge in der App)

Erzeugt von `tools/build-hildesheim-seed.py` aus dem Zwischenspeicher `~/Studora-Builds/hildesheim/crawl/`
(Leser in `app/catalog_formats/hildesheim.py` und `app/study_catalog_hildesheim_layout.py`). Ressource
`apps/apple/UniFlow/Resources/StudyCatalogSeed/hildesheim.json.gz`
(gzip, nur geteilte Fakten), Verzeichnis `hildesheim-index.json`. Die App nimmt den Grundstock der Hochschule des
Containers (`settings.university`).

| Fachbereich | Kataloge | Einträge | Module | Formate |
|---|---:|---:|---:|---|
| Fachbereich 1 – Erziehungs- und Sozialwissenschaften | 34 | 34 | 254 | hildesheim-modulbeschreibung 32, hildesheim-modultabelle 2 |
| Fachbereich 2 – Kulturwissenschaften und Ästhetische Kommunikation | 16 | 16 | 320 | hildesheim-modulbeschreibung 10, hildesheim-modultabelle 6 |
| Fachbereich 3 – Sprach- und Informationswissenschaften | 19 | 19 | 227 | hildesheim-kennnummer-tabelle 2, hildesheim-modulbeschreibung 16, hildesheim-modultabelle 1 |
| Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik | 38 | 38 | 1386 | hildesheim-it-modulhandbuch 13, hildesheim-kuerzel-modultabelle 2, hildesheim-modulbeschreibung 22, hildesheim-modultabelle 1 |
| fachbereichsübergreifend (Lehrerbildung) | 4 | 4 | 44 | hildesheim-modulbeschreibung 4 |
| **zusammen** | **111** | **111** | **2231** | |

Nach Format: `hildesheim-it-modulhandbuch` 13 Kataloge / 1137 Module; `hildesheim-kennnummer-tabelle` 2 Kataloge / 22 Module; `hildesheim-kuerzel-modultabelle` 2 Kataloge / 20 Module; `hildesheim-modulbeschreibung` 84 Kataloge / 820 Module; `hildesheim-modultabelle` 10 Kataloge / 232 Module.
Registereinträge: 121, davon im Grundstock: 111.

Vollständigkeit der Felder (Anteil der Module mit Wert; Turnus nur WS/SS/WS+SS, Voraussetzungen = verweist auf andere Module):

| Format | Kataloge | Module | LP | Semester | Turnus | Prüfung | Studienl. | Vorauss. | Sprache | Aufwand |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `hildesheim-it-modulhandbuch` | 13 | 1137 | 100 % | 98 % | 71 % | 100 % | 0 % | 23 % | 26 % | 100 % |
| `hildesheim-kennnummer-tabelle` | 2 | 22 | 100 % | 100 % | 91 % | 95 % | 45 % | 0 % | 0 % | 100 % |
| `hildesheim-kuerzel-modultabelle` | 2 | 20 | 100 % | 100 % | 100 % | 100 % | 25 % | 0 % | 0 % | 90 % |
| `hildesheim-modulbeschreibung` | 84 | 820 | 95 % | 76 % | 83 % | 95 % | 86 % | 1 % | 9 % | 68 % |
| `hildesheim-modultabelle` | 10 | 232 | 99 % | 86 % | 49 % | 91 % | 97 % | 2 % | 0 % | 90 % |
| **zusammen** | **111** | **2231** | 98 % | 89 % | 74 % | 97 % | 43 % | 12 % | 17 % | 87 % |

Kataloge mit Regeln/LP für Bereiche: 26; mit empfohlenem Semester je Modul: 98.

Ohne Katalog im Grundstock (10) – geht nicht, weil …:

- Data Science (B.Sc.): Modulhandbuch (Stand 03.04.2026) liest der Leser noch nicht sauber: der Abschnitt 'Anwendungsgebiete (Wahl)' landet als Pflicht (alle 73 Module im Semesterplan, 4. Semester 144 LP), der Abschnitt 'Methodological Specialization' fehlt (ein Modul steht unter Abschlussprüfung), die Gebiete Medieninformatik und Systemadministration fehlen
- Deutsch-Französischer Doppel-Master Kulturvermittlung/Médiation Culturelle de l'Art (M.A.): keine geltende Studienordnung mit Modulbeschreibungen und kein Modulhandbuch im Verkündungsblatt
- Future Analytics: AI & Audio Worlds (M.Sc.): keine geltende Studienordnung mit Modulbeschreibungen und kein Modulhandbuch im Verkündungsblatt
- Lehramt an Grund-, Haupt- und Realschulen (Staatsexamen): Studienordnung (1 Seiten) ohne lesbare Modulbeschreibungen
- Lehramt an Grund- und Hauptschulen (M.Ed.): keine geltende Studienordnung mit Modulbeschreibungen und kein Modulhandbuch im Verkündungsblatt
- Lehramt an Haupt- und Realschulen (Quereinstieg für Fachbachelor) (M.Ed.): keine geltende Studienordnung mit Modulbeschreibungen und kein Modulhandbuch im Verkündungsblatt
- Lehramt an Realschulen (M.Ed.): keine geltende Studienordnung mit Modulbeschreibungen und kein Modulhandbuch im Verkündungsblatt
- Organization Studies (M.A.): Studienordnung (3 Seiten) ohne lesbare Modulbeschreibungen
- Psychologie mit Schwerpunkt Pädagogische Psychologie (B.Sc.): keine geltende Studienordnung mit Modulbeschreibungen und kein Modulhandbuch im Verkündungsblatt
- Rechtspsychologie (M.Sc.): Studienordnung (3 Seiten) ohne lesbare Modulbeschreibungen

Anfragen laut Zwischenspeicher: 209 (209 × 200), davon 153 PDFs, 96 MB, 05.11.2026 12:46–14.11.2026 14:04 UTC, kleinster Abstand -12.8 s.
Datei `hildesheim.json.gz`: 134 KB gzip, 1172 KB JSON, 111 Kataloge.
Nachbearbeitung: 6 Module in Wahlbereichen von `pflicht` auf `wahlpflicht`/`wahl`, 29 Kataloge mit Handangaben, 1 doppelte Module, 0 ungültige, 0 ohne PDF/Leser verworfen.

Neu bauen: `.venv/bin/python tools/build-hildesheim-seed.py` (prüfen: `--check`, Vorschau: `--diff`).
<!-- grundstock:end -->

## Quellenliste des Inhabers (14.11.2026)

Abgleich der Liste offizieller Quellen (28 Dokumente, davon 24 direkte PDFs) mit Register und Grundstock. Abruf: 28
anonyme GETs, 3 s Pause, nur öffentliche Seiten; die sieben eingebauten Handbücher (fünf FB 4, zwei FB 1) wurden mit
Prüfsumme in den Zwischenspeicher übernommen (keine zweite Anfrage). Keine PDFs im Repo. Bauweg: `MEDIA` und `MEDIA_ONLY` in
`tools/hildesheim-programs.py`. Prüfungsordnung, Schlüssel und Kürzel bleiben die des Verkündungsblatts; nur Quelle und
Semester des Katalogs ändern sich.

Eingebaut (Leser liest sauber, `validate` bestanden, alle Handregeln der Wahlbereiche greifen weiter):

| Eintrag | Quelle neu | Module alt → neu |
|---|---|---:|
| Angewandte Informatik B.Sc. / M.Sc. | Modulhandbuch AI, Stand 03.04.2026 | 86 → 104 / 118 → 124 |
| Informationsmanagement und Informationstechnologie B.Sc. / M.Sc. | Modulhandbuch IMIT, Stand 24.10.2024 | 90 → 87 / 129 → 117 |
| Umweltinformatik B.Sc. / M.Sc. | Modulhandbuch UINF, Stand 24.10.2024 | 83 → 84 / 105 → 98 |
| Wirtschaftsinformatik B.Sc. / M.Sc. ("Verwendung" aus AI, IMIT, UINF) | die drei Handbücher oben | 73 → 94 / 100 → 117 |
| Medieninformatik B.Sc. (Lücke geschlossen) | Modulhandbuch MINF, Stand 03.04.2026 | – → 75 |
| Erziehungswissenschaft B.A. (gleiche Fassung, Text sauber) | Modulhandbuch Bachelor FB 1, Stand 18.08.2022 | 9 → 11 |
| Erziehungswissenschaft M.A. Kindheitspädagogik/Diversität (Lücke geschlossen; fileID 4990 ist Bild) | Modulhandbuch Master FB 1, Fassung 18.08.2022 | – → 12 |

Weniger Module bei IMIT und UINF M.Sc. sind echt: die neueren PDFs haben selbst weniger Modulüberschriften („Modul: …“:
IMIT 215 → 202, UINF 204 → 196). Der Leser verliert je PDF so viele Überschriften wie beim alten Handbuch (UINF 16 → 14,
IMIT 2 → 3, AI 1 → 1; Module, die keinem der beiden Abschlüsse zugeordnet sind).

Erziehungswissenschaft (FB 1): Die Tabellenbeschriftung „Inhalte und Qualifikationsziele“ bricht um; der Leser kennt
jetzt „Inhalte und“ als Feldnamen (kein Titelanhang „Inhalte und: …“ mehr, sonst ändert sich kein Katalog). Handregeln
in `study-area-rules-hildesheim.json`: im Master sind 6a/6b Alternativen (eine Zeile mit 15 LP in der Übersicht, Bereich
„Vertiefung“), Modul 7 „Wahlpflicht“ ist ein Pflichtmodul mit Wahl im Inhalt; Bachelor-/Mastermodul ist die
Abschlussarbeit (nur hier: in den Lehramtsfächern ist das „Mastermodul“ das Fach, in dem die Arbeit geschrieben werden
kann, und bleibt Wahl). Master: 77 LP Pflicht + 15 LP Vertiefung + 28 LP Mastermodul = 120 LP.

Neu: Englisch im Polyvalenten Zwei-Fächer-Bachelor (eigener Fach-Eintrag; fileID 5259 regelt das Fach und hing bisher
nur an der Variante English Applied Linguistics). Suche (`SEARCH_ALIASES`, gleich in Python, Swift und Web; Fälle in
`fixtures/study-catalog/program-search.json`): „Lehramt studieren“ findet den Zwei-Fächer-Bachelor und die
Lehramts-Master (nicht alle Fach-Einträge: „^“ heißt, der Name beginnt damit), „Lehramt Grundschule“ und „Lehramt Haupt-
und Realschule“ auch den Zwei-Fächer-Bachelor, der alte Name „Kulturwissenschaften und Ästhetische Praxis“ den heutigen
Studiengang. IMIT, DaZ/DaF, „Philosophie, Künste, Medien“ und „Kulturvermittlung, Kulturpolitik und Transformation“
fanden schon vorher.

Neu im Register mit Katalog: Informatik im Polyvalenten Zwei-Fächer-Bachelor, Ordnung 2016 (gilt für Studienbeginn
vor dem 01.10.2026; Studienordnung auf der Seite des FB 4). Der Tabellenleser liefert 19 Einträge; bereinigt mit
Handregeln (neu: `drop_modules` in `build-hildesheim-seed.py`): Robotik 1 war in zwei Teile zerfallen, der Titel
„*2 Einführung in die Informatik“ trug die Fußnote, Geschäftsprozessmanagement ist laut Modulbeschreibung Wahlpflicht.
Ergebnis: die 18 Module INF-A11 bis INF-V27. Pflicht und Wahl hängen in dieser Ordnung von der Studienvariante ab
(Anlage 1, 13 Varianten); der Katalog nimmt die Angabe aus der Modulbeschreibung. Die Ordnung 2026 (Heft 214) ist seit
15.11.2026 eingebaut (Abschnitt „Nachzug“).

Neu im Register, ohne Katalog (wählbar mit dem Hinweis „noch kein Modulkatalog“):
- Data Science B.Sc. (PO 2023, Studienvariante der Angewandten Informatik, nicht im Studienangebot): der Leser legt den
  Abschnitt „Anwendungsgebiete (Wahl)“ als Pflicht ab (alle 73 Module im Semesterplan, 4. Semester 144 LP), der
  Abschnitt „Methodological Specialization“ fehlt (ein Modul landet unter Abschlussprüfung), die Gebiete
  Medieninformatik und Systemadministration fehlen. Sauber ginge es nur mit mehreren Handregeln und den LP-Regeln der
  PO, die in der Liste nicht stehen.

Nicht eingebaut, mit Grund:
- Informatik im Zwei-Fächer-Bachelor 2026 und Informatik im Master Lehramt HRS 2026 (Heft 214) sowie Barrierefreie
  Kommunikation M.A. 2024: am 14.11. noch „Format unbekannt“, seit 15.11.2026 eingebaut (Abschnitt „Nachzug“).
- Ältere Fassungen (IMIT/AI PO 2016, Sport GHR 2020, Szenische Künste, Kulturwissenschaften 2010, IKÜ 2009 mit
  Wahlpflichtfächern, Englisch, Technik M.Ed. 2021, Sozialpädagogik 2019): älter als das Register, nicht ersetzt.
  Sozialpädagogik 2019 (fileID 4710) ist schon als „bisherige Ordnung“ angebunden.
- Kein Modulkatalog: Modulübersicht Sport (4 Seiten), Rahmenprüfungsordnung 2026 (fileID 5302), Teilzeitordnung
  (fileID 4293).
- Bildungswissenschaften: kein lesbares Dokument in der Liste.

## Nachzug (15.11.2026)

Auftrag vom 14.11. („baue alle Studiengänge ein, die es da gibt“), offene Punkte der Quellenliste. Keine Netz-Anfrage:
die zwei Informatik-Ordnungen aus Heft 214 lagen seit dem 14.11. lokal (Quellenliste Nr. 8 und 9) und wurden mit
Prüfsumme in den Zwischenspeicher übernommen (wie die Handbücher am 14.11.; Zähler 207 → 209).

**A. Zwei neue Leser** (`app/study_catalog_hildesheim_layout.py`, Swift `StudyCatalogHildesheimLayoutParser`, Fixture aus
erfundenem Mustertext, auf beiden Seiten byte-gleich geprüft):

| Eintrag | Quelle | Module | LP | Prüfung gegen die Ordnung |
|---|---|---:|---:|---|
| Informatik im Polyvalenten Zwei-Fächer-Bachelor, Ordnung 2026 (neu) | Heft 214, 27.08.2026 (`inf2fb2026`) | 15 | 90 | INF-B1–B4, A1–A4, V1–V7. Fach = 57 LP (§ 2): 30 LP Pflicht in jeder Variante (B1, B2, B3, A1, A2) + 27 LP Wahlpflicht. Probe je Variante: Inf_Us 45 LP Pflicht + 12 LP, EAL/SGL/WP 39 LP Pflicht + 18 LP |
| Informatik im Master Lehramt an Haupt- und Realschulen, Ordnung 2026 (neu) | Heft 214, 27.08.2026 (`infmed2026`) | 5 | 59 | Fach = 10 LP (§ 2): INF-M1 7 LP + INF-M2 3 LP, beide Pflicht. Dazu wie bei den anderen M.Ed.-Fächern die Module der Rahmenstudienordnung aus derselben Anlage: Praxisphase 13 LP (Pflicht), Projektband 12 LP und Mastermodul 24 LP (Wahlpflicht) |
| Barrierefreie Kommunikation M.A. (bisher ohne Katalog) | fileID 5176, Heft 193 | 11 | 120 | BK 1–BK 11; PO § 22: 90 LP Studium (BK 1–9) + 10 LP Profilmodul (BK 10) + 20 LP Masterarbeit (BK 11) = 120 LP |

`validate` ist bei allen drei leer; sonst ändert sich kein Katalog (`build-hildesheim-seed.py --diff` zeigte nur die drei).
Pflicht/Wahl bei Informatik 2026: die Modulbeschreibungen verweisen auf Anlage 1, dort stehen zwei Studienvarianten mit
verschiedenen Pflichtmodulen. Der Katalog führt als Pflicht nur, was in beiden Pflicht ist; INF-B4, INF-A3, INF-A4 und
INF-V1 sind je nach Variante Pflicht und stehen deshalb im Wahlpflichtbereich, dessen Regel beide Varianten nennt
(`study-area-rules-hildesheim.json`). Die Bachelorarbeit (9 LP im Erstfach) hat in der Ordnung keine Modulbeschreibung und
steht nicht im Katalog.

Zwei Ordnungen für Informatik im Zwei-Fächer-Bachelor: 2016 (Studienbeginn vor dem 01.10.2026, Leistungen bis 30.09.2030)
und 2026. Angelegt wie bei der Sozialpädagogik: ein Studiengang mit zwei Ordnungen im Register, dazu ein Eintrag in
`study-orders.json` (und `StudyPlanAPI.orders`): wer die Ordnung 2026 wählt und vor dem WiSe 2026/27 begonnen hat, bekommt
die Ordnung 2016 vorgeschlagen und bestätigt selbst; ihr Katalog kommt aus dem Grundstock. Für den Master gibt es im
Register keine ältere Informatik-Ordnung, also keinen Vorschlag.

**B. LP-Lücken und die zwei Kataloge ohne Semesterlage.** Vorher 19 Kataloge mit zusammen 80 Modulen ohne LP, nachher 6
Kataloge mit 42 Modulen; jede Leser-Änderung wurde an allen 111 Katalogen verglichen (alt gegen neu, je Modul).

| Ursache (Leser `app/catalog_formats/hildesheim.py`, wenn nicht anders genannt) | behoben in |
|---|---|
| Eine Zahl allein in einer Zeile galt als Seitenzahl und fiel weg – auch der Wert unter „Anzahl der Leistungspunkte:“. Jetzt nur noch am Seitenrand. Vorher kamen die LP dann geraten aus dem Workload, zum Teil falsch | Politikwissenschaft 2FB (2), IIM-IW M.A. (2), IIM-SWIKK M.A. (1), je 2 Module der fünf IIM-Bachelor-Einträge; still falsche LP berichtigt (Philosophie–Künste–Medien: fünf Module 9 → 6 LP laut Modulübersicht, Politikwissenschaft AM 2b/VM 2b 7 → 5) |
| Seitenumbruch: erst der Kopf des nächsten Moduls, dann unter wiederholtem Titel der Rest des vorigen | Mathematik 2FB 2025 (Aufbaumodul 3: 9 LP) |
| LP des Moduls nur in „Vergabe von Credits: 17 LP = Studienleistung + Modulprüfung“; „Leistungspunkte“ darunter gehören zu Teilmodulen | DaZ/DaF M.A. (LP-Summe 18 → 120) |
| LP nur im Titel „(30 LP)“; Leser-Wahl: der Leser der Modulbeschreibungen liefert jetzt genau die 10 Module mit 120 LP | Sportwissenschaft M.Sc. |
| Kopfzeilen von Übersichtstabellen („Modulbezeichnung \| Themen \| LP“, „Modul- / Teilmodulbezeichnung“) und Teilmodul-Reste als Modul | Inklusive Pädagogik, Kunst 2FB, DaZ/DaF, Künste und Gegenwartskulturen |
| Feldname über den Zeilenumbruch: „Workload Kontaktstun-/den (h) … 8 SWS / 16 LP“ | Literarisches Schreiben und Lektorieren (42 und 16 LP) |
| Gleiche Vorlage wie Barrierefreie Kommunikation („Kennnummer \| Workload \| Credits“), Titelzeile „Modul MuM 1 – Titel“, auch über zwei Zeilen: jetzt `hildesheim-kennnummer-tabelle` (Python und Swift, Fixture erweitert) | Medientext und Medienübersetzung: 10 → 11 Module (MuM 6 fehlte), 8 → 0 ohne LP, 120 LP mit einem der Wahlpflichtmodule MuM 7/8 (Handregel mit Quelle) |
| Handregel mit Quelle, weil die Ordnung die LP an anderer Stelle nennt | Wirtschaft Plus (Anlage 1 und Abschnitt „Wahlmodul Wirtschaftsinformatik“: BM06/BM07 je 6 LP, WI01–03 je 6, WI04/05 je 3 LP; BM07 stand fälschlich mit 1 LP), Physik M.Ed. 2017/2026 (gemeinsame Beschreibung der Vertiefungsmodule: U5 wie V5 3 LP, eines von beiden) |
| „(8 / LP)“ als Zeilenrest und „… die restlichen / Leistungspunkte im Rahmen …“ im Fließtext galten als Feld „LP“; Titel mit einem Absatz Fließtext vor dem ersten Feld; kein Titel über ein Feld hinweg | Umwelt, Naturschutz und Nachhaltigkeit (Modul 1 fehlte, Modul 2: 3 → 20 LP), Physik M.Ed. 2026 (Pflichtmodul B7 fehlte), Projektband Deutsch M.Ed. 2 → 12 LP, Umweltsicherung, Sachunterricht u. a. |
| „TM 1: 3. Fachsemester“: die Teilmodulnummer galt als Semester | 79 Module mit berichtigtem Semester |

Was bleibt (feste Liste in `tests/test_hildesheim_seed_quality.py` und `HildesheimSeedQualityTests.swift`):
- **Internationales Informationsmanagement B.A.** (fünf Einträge, eine Ordnung, je 8 Module): Die Ordnung rechnet in
  Teilmodulen; je Modul steht eine Spanne je Studienvariante („IIM, IKS, LIN, DISO, GIM: 0–16 LP; DRIKK: 4–8 LP“). Sieben
  Module beginnen bei 0 LP (reine Wahl), „Peer Credits“ hat keine LP-Angabe. Eine feste Zahl wäre geraten. Sauber ginge es
  nur mit einem Katalog je Studienvariante auf Ebene der Teilmodule (Anlage 1 nennt je Teilmodul LP und Pflicht/Wahl je
  Variante) – eigener Auftrag. Bis dahin sind die fünf Kataloge gleich und nennen bei Spannen die untere Grenze.
- **Internationale Kommunikation und Übersetzen B.A.** (2 Module): Modul 2 hat je Studienvariante 20 bzw. 10 LP („Modul
  Gesamt“ in zwei Zeilen), das Auslandsmodul steht nur in der Modulübersicht. Auch die übrigen LP dieses Katalogs hängen
  an der Variante (Modul 3: gelesen 3 LP, laut Übersicht 17 bzw. 10) – der Katalog braucht dieselbe Arbeit wie IIM.

**Kataloge ohne Semesterlage** (vorher 2, nachher 0):
- *Umwelt, Naturschutz und Nachhaltigkeit M.Sc.*: Es stimmte nicht. Pflichtmodul 1 (Anpassungs- und Komplementärmodul,
  9 LP) fehlte, Modul 2 hatte 3 statt 20 LP, und die vier Vertiefungsrichtungen (je 18 LP, eine davon) standen als
  Pflicht. Jetzt 20 Module; Pflicht 56 LP + eine Vertiefungsrichtung 18 LP + Praxis, Projekt, Mastermodul 46 LP = 120 LP
  wie in der Tabelle „Studienaufbau“. Semester und Vertiefungsrichtungen als Handregel aus dieser Tabelle.
- *Wirtschaftsinformatik M.Sc.*: Dass alle Fachmodule Wahlpflicht sind, stimmt (PO § 4 Abs. 1: Forschungsmethodik
  mindestens 21 LP, Spezialisierung mindestens 51 LP, Wahlbereich höchstens 18 LP). Es fehlte aber die Abschlussprüfung
  (Masterarbeit 27 LP + Kolloquium 3 LP): das Handbuch nennt Wirtschaftsinformatik in der „Verwendung“ dieses Moduls
  nicht. Der Leser nimmt die Abschlussprüfung des Abschlusses jetzt immer dazu; ebenso im Bachelor (12 + 3 LP).

Nicht gemacht: Die beiden Leser sind im Abgleich des Geräts (eigener Katalog-Link) nicht verdrahtet; die drei Kataloge
kommen aus dem Grundstock, ein eingefügter Link auf eine dieser PDFs führt über das Register dorthin.
