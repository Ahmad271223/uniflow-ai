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
| Fachbereich 1 – Erziehungs- und Sozialwissenschaften | 34 | 34 | 259 | hildesheim-modulbeschreibung 31, hildesheim-modultabelle 3 |
| Fachbereich 2 – Kulturwissenschaften und Ästhetische Kommunikation | 16 | 16 | 322 | hildesheim-modulbeschreibung 10, hildesheim-modultabelle 6 |
| Fachbereich 3 – Sprach- und Informationswissenschaften | 18 | 18 | 216 | hildesheim-modulbeschreibung 16, hildesheim-modultabelle 2 |
| Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik | 35 | 35 | 1345 | hildesheim-it-modulhandbuch 13, hildesheim-modulbeschreibung 22 |
| fachbereichsübergreifend (Lehrerbildung) | 4 | 4 | 44 | hildesheim-modulbeschreibung 4 |
| **zusammen** | **107** | **107** | **2186** | |

Nach Format: `hildesheim-it-modulhandbuch` 13 Kataloge / 1135 Module; `hildesheim-modulbeschreibung` 83 Kataloge / 812 Module; `hildesheim-modultabelle` 11 Kataloge / 239 Module.
Registereinträge: 118, davon im Grundstock: 107.

Vollständigkeit der Felder (Anteil der Module mit Wert; Turnus nur WS/SS/WS+SS, Voraussetzungen = verweist auf andere Module):

| Format | Kataloge | Module | LP | Semester | Turnus | Prüfung | Studienl. | Vorauss. | Sprache | Aufwand |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `hildesheim-it-modulhandbuch` | 13 | 1135 | 100 % | 98 % | 71 % | 100 % | 0 % | 23 % | 26 % | 100 % |
| `hildesheim-modulbeschreibung` | 83 | 812 | 92 % | 73 % | 83 % | 95 % | 86 % | 1 % | 9 % | 67 % |
| `hildesheim-modultabelle` | 11 | 239 | 95 % | 81 % | 44 % | 90 % | 91 % | 0 % | 0 % | 84 % |
| **zusammen** | **107** | **2186** | 96 % | 87 % | 72 % | 97 % | 42 % | 12 % | 17 % | 86 % |

Kataloge mit Regeln/LP für Bereiche: 20; mit empfohlenem Semester je Modul: 92.

Ohne Katalog im Grundstock (11) – geht nicht, weil …:

- Barrierefreie Kommunikation (M.A.): Modulbeschreibungen im Format „Kennnummer | Workload | Credits“ liest der Leser noch nicht; er fand nur drei Querverweise („Modul 7.2 geöffnet für …“) statt der 11 Module
- Data Science (B.Sc.): Modulhandbuch (Stand 03.04.2026) liest der Leser noch nicht sauber: der Abschnitt 'Anwendungsgebiete (Wahl)' landet als Pflicht (alle 73 Module im Semesterplan, 4. Semester 144 LP)
- Deutsch-Französischer Doppel-Master Kulturvermittlung/Médiation Culturelle de l'Art (M.A.): keine geltende Studienordnung mit Modulbeschreibungen und kein Modulhandbuch im Verkündungsblatt
- Future Analytics: AI & Audio Worlds (M.Sc.): keine geltende Studienordnung mit Modulbeschreibungen und kein Modulhandbuch im Verkündungsblatt
- Lehramt an Grund-, Haupt- und Realschulen (Staatsexamen): Studienordnung (1 Seiten) ohne lesbare Modulbeschreibungen
- Lehramt an Grund- und Hauptschulen (M.Ed.): keine geltende Studienordnung mit Modulbeschreibungen und kein Modulhandbuch im Verkündungsblatt
- Lehramt an Haupt- und Realschulen (Quereinstieg für Fachbachelor) (M.Ed.): keine geltende Studienordnung mit Modulbeschreibungen und kein Modulhandbuch im Verkündungsblatt
- Lehramt an Realschulen (M.Ed.): keine geltende Studienordnung mit Modulbeschreibungen und kein Modulhandbuch im Verkündungsblatt
- Organization Studies (M.A.): Studienordnung (3 Seiten) ohne lesbare Modulbeschreibungen
- Psychologie mit Schwerpunkt Pädagogische Psychologie (B.Sc.): keine geltende Studienordnung mit Modulbeschreibungen und kein Modulhandbuch im Verkündungsblatt
- Rechtspsychologie (M.Sc.): Studienordnung (3 Seiten) ohne lesbare Modulbeschreibungen

Anfragen laut Zwischenspeicher: 206 (206 × 200), davon 150 PDFs, 94 MB, 05.11.2026 12:46–14.11.2026 14:04 UTC, kleinster Abstand 2.5 s.
Datei `hildesheim.json.gz`: 131 KB gzip, 1154 KB JSON, 107 Kataloge.
Nachbearbeitung: 6 Module in Wahlbereichen von `pflicht` auf `wahlpflicht`/`wahl`, 22 Kataloge mit Handangaben, 0 doppelte Module, 0 ungültige, 0 ohne PDF/Leser verworfen.

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

Neu im Register, ohne Katalog (wählbar mit dem Hinweis „noch kein Modulkatalog“):
- Data Science B.Sc. (PO 2023, Studienvariante der Angewandten Informatik, nicht im Studienangebot): der Leser legt den
  Abschnitt „Anwendungsgebiete (Wahl)“ als Pflicht ab (alle 73 Module im Semesterplan, 4. Semester 144 LP).

Nicht eingebaut, mit Grund:
- Informatik im Zwei-Fächer-Bachelor, Ordnung 2016 (gilt für Beginn vor 01.10.2026): kein Registereintrag, der Leser
  liefert 21 Module mit 3 Bruchstücken.
- Informatik im Zwei-Fächer-Bachelor 2026 und Informatik im Master Lehramt HRS 2026 (Heft 214): Format unbekannt
  (Titelzeile „INF-B1: „Titel““, LP als letzte Tabellenspalte); braucht eine Leser-Erweiterung.
- Barrierefreie Kommunikation M.A. 2024: Format unbekannt („Kennnummer | Workload | Credits“), der Leser greift nur
  drei Querverweise („Modul 7.2 geöffnet für …“). Bisher standen diese drei als Module im Grundstock; jetzt
  `CATALOG_HOLD` in `tools/hildesheim-programs.py`: wählbar ohne Katalog mit Hinweis, bis der Leser das Format kennt.
- Ältere Fassungen (IMIT/AI PO 2016, Sport GHR 2020, Szenische Künste, Kulturwissenschaften 2010, IKÜ 2009 mit
  Wahlpflichtfächern, Englisch, Technik M.Ed. 2021, Sozialpädagogik 2019): älter als das Register, nicht ersetzt.
  Sozialpädagogik 2019 (fileID 4710) ist schon als „bisherige Ordnung“ angebunden.
- Kein Modulkatalog: Modulübersicht Sport (4 Seiten), Rahmenprüfungsordnung 2026 (fileID 5302), Teilzeitordnung
  (fileID 4293).
- Bildungswissenschaften: kein lesbares Dokument in der Liste.
