# Studiengänge der Universität Hildesheim: Register, Modulkataloge, Grundstock (05.11.2026)

Auftrag: Studienverlauf für Hildesheim auf dem Stand der LUH (`docs/STUDIENVERLAUF-2026-11-04.md`,
`docs/STUDIENGAENGE-LUH-2026-11-04.md`), danach (Vorgabe des Inhabers, 05.11.2026) eine eigene, möglichst vollständige
Bibliothek. Ergebnis: Register `packages/shared-contracts/study-sources-hildesheim.json` (Abholer
`tools/hildesheim-programs.py`), Leser `app/catalog_formats/hildesheim.py` (drei Formate), Grundstock
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
  (Nebenfach 15/30 LP), Barrierefreie Kommunikation (Profilmodul 10 LP), Biologie (Regeln je Studienvariante).
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
| `none` | 11 | – | siehe „geht nicht, weil …“ im Abschnitt „Grundstock“ |

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
(Leser in `app/catalog_formats/hildesheim.py`). Ressource `apps/apple/UniFlow/Resources/StudyCatalogSeed/hildesheim.json.gz`
(gzip, nur geteilte Fakten), Verzeichnis `hildesheim-index.json`. Die App nimmt den Grundstock der Hochschule des
Containers (`settings.university`).

| Fachbereich | Kataloge | Einträge | Module | Formate |
|---|---:|---:|---:|---|
| Fachbereich 1 – Erziehungs- und Sozialwissenschaften | 33 | 33 | 245 | hildesheim-modulbeschreibung 31, hildesheim-modultabelle 2 |
| Fachbereich 2 – Kulturwissenschaften und Ästhetische Kommunikation | 16 | 16 | 322 | hildesheim-modulbeschreibung 10, hildesheim-modultabelle 6 |
| Fachbereich 3 – Sprach- und Informationswissenschaften | 18 | 18 | 210 | hildesheim-modulbeschreibung 15, hildesheim-modultabelle 3 |
| Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik | 34 | 34 | 1229 | hildesheim-it-modulhandbuch 12, hildesheim-modulbeschreibung 22 |
| fachbereichsübergreifend (Lehrerbildung) | 4 | 4 | 44 | hildesheim-modulbeschreibung 4 |
| **zusammen** | **105** | **105** | **2050** | |

Nach Format: `hildesheim-it-modulhandbuch` 12 Kataloge / 1019 Module; `hildesheim-modulbeschreibung` 82 Kataloge / 803 Module; `hildesheim-modultabelle` 11 Kataloge / 228 Module.
Registereinträge: 116, davon im Grundstock: 105.

Vollständigkeit der Felder (Anteil der Module mit Wert; Turnus nur WS/SS/WS+SS, Voraussetzungen = verweist auf andere Module):

| Format | Kataloge | Module | LP | Semester | Turnus | Prüfung | Studienl. | Vorauss. | Sprache | Aufwand |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `hildesheim-it-modulhandbuch` | 12 | 1019 | 100 % | 98 % | 69 % | 100 % | 0 % | 22 % | 27 % | 100 % |
| `hildesheim-modulbeschreibung` | 82 | 803 | 92 % | 72 % | 82 % | 95 % | 86 % | 1 % | 9 % | 67 % |
| `hildesheim-modultabelle` | 11 | 228 | 93 % | 85 % | 45 % | 91 % | 91 % | 0 % | 0 % | 82 % |
| **zusammen** | **105** | **2050** | 96 % | 86 % | 71 % | 97 % | 44 % | 11 % | 17 % | 85 % |

Kataloge mit Regeln/LP für Bereiche: 19; mit empfohlenem Semester je Modul: 90.

Ohne Katalog im Grundstock (11) – geht nicht, weil …:

- Deutsch-Französischer Doppel-Master Kulturvermittlung/Médiation Culturelle de l'Art (M.A.): keine geltende Studienordnung mit Modulbeschreibungen und kein Modulhandbuch im Verkündungsblatt
- Erziehungswissenschaft mit den Schwerpunkten Kindheitspädagogik/Diversität (M.A.): Studienordnung (19 Seiten) ohne lesbare Modulbeschreibungen
- Future Analytics: AI & Audio Worlds (M.Sc.): keine geltende Studienordnung mit Modulbeschreibungen und kein Modulhandbuch im Verkündungsblatt
- Lehramt an Grund-, Haupt- und Realschulen (Staatsexamen): Studienordnung (1 Seiten) ohne lesbare Modulbeschreibungen
- Lehramt an Grund- und Hauptschulen (M.Ed.): keine geltende Studienordnung mit Modulbeschreibungen und kein Modulhandbuch im Verkündungsblatt
- Lehramt an Haupt- und Realschulen (Quereinstieg für Fachbachelor) (M.Ed.): keine geltende Studienordnung mit Modulbeschreibungen und kein Modulhandbuch im Verkündungsblatt
- Lehramt an Realschulen (M.Ed.): keine geltende Studienordnung mit Modulbeschreibungen und kein Modulhandbuch im Verkündungsblatt
- Medieninformatik (B.Sc.): keine geltende Studienordnung mit Modulbeschreibungen und kein Modulhandbuch im Verkündungsblatt
- Organization Studies (M.A.): Studienordnung (3 Seiten) ohne lesbare Modulbeschreibungen
- Psychologie mit Schwerpunkt Pädagogische Psychologie (B.Sc.): keine geltende Studienordnung mit Modulbeschreibungen und kein Modulhandbuch im Verkündungsblatt
- Rechtspsychologie (M.Sc.): Studienordnung (3 Seiten) ohne lesbare Modulbeschreibungen

Anfragen laut Zwischenspeicher: 199 (199 × 200), davon 143 PDFs, 88 MB, 05.11.2026 12:46–05.11.2026 13:41 UTC, kleinster Abstand 2.5 s.
Datei `hildesheim.json.gz`: 123 KB gzip, 1093 KB JSON, 105 Kataloge.
Nachbearbeitung: 6 Module in Wahlbereichen von `pflicht` auf `wahlpflicht`/`wahl`, 21 Kataloge mit Handangaben, 0 doppelte Module, 0 ungültige, 0 ohne PDF/Leser verworfen.

Neu bauen: `.venv/bin/python tools/build-hildesheim-seed.py` (prüfen: `--check`, Vorschau: `--diff`).
<!-- grundstock:end -->
