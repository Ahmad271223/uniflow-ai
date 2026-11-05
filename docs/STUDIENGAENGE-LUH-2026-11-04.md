# Studiengänge der LUH: Register und Abdeckung (04.11.2026)

Auftrag des Inhabers: „Hol direkt alles für jeden Studiengang, den es an der Uni gibt.“ Ergebnis:
`packages/shared-contracts/study-sources-luh.json` (Register), `tools/luh-programs.py` (Abholer, erneut lauffähig),
`tests/test_study_sources_luh.py` (Prüfung). Zugehörige Planung: `docs/STUDIENVERLAUF-2026-11-04.md`.
Verbindlich bleibt immer die Prüfungsordnung der Hochschule.

## Ergebnis in Zahlen

- **204 Studiengänge/Fächer** im offiziellen Studienangebot A–Z, dazu **19 auslaufende** Studiengänge, die nur noch
  eine Ordnungen-Seite haben (z. B. Produktion und Logistik, Optische Technologien B.Sc., Meteorologie B.Sc.,
  Geschichte M.A.) → **223 Studiengänge**, **234 Einträge** (je Studiengang und Prüfungsordnung; 11 Studiengänge haben
  zwei geltende POs, z. B. Maschinenbau B.Sc. PO 2017/2026, Elektrotechnik B.Sc. PO 2017/2025).
- Darunter 105 Fächer der Lehramts- und Zwei-Fächer-Studiengänge (Fächerübergreifender Bachelor, Technical Education,
  Sonderpädagogik, M.Ed. Gymnasien/berufsbildende Schulen/LBS-Sprint/Sonderpädagogik) und 13 Vertiefungsrichtungen.
- **Prüfungsordnung gefunden: 229 von 234** Einträgen (PDF unter `www.uni-hannover.de/fileadmin/luh/studium/ordnungen/…`
  bzw. `…/pruefungsamt/formulare/…`). Ohne PO: Medizintechnik B.Sc. (Seite leer), Energy Technology, International
  Mechatronics, Power-Engineering-Track, ein Altfall Mechatronik und Robotik PO 2017.
- **Modulhandbuch gefunden: 152 von 234** Einträgen, **121 verschiedene PDFs**, alle geladen und eingeordnet.
  Studienverlaufsplan/Musterstudienplan getrennt gefunden: 52 Einträge.
- **Anfragen: 448 von 600** (431 × 200, 15 × 404, 2 Netzfehler), 25 Hosts, 25 × robots.txt, ≈ 346 MB, 21:40–22:36 Uhr,
  Abstand nie unter 2,5 s, nacheinander. Zweiter Lauf (`all`) aus dem Zwischenspeicher: 0 neue Anfragen.

## Abdeckung nach Format

| Format | Einträge | verschiedene PDFs | Module (Schätzung) | Parser |
|---|---:|---:|---:|---|
| `modkat-FEI` | 22 (+2 als Zusatzkatalog) | 23 | 1 931 | vorhanden (FEI-Parser) |
| `mb-modulkatalog` | 18 | 18 | 1 698 | neu, Datenbank-Ausgabe, sehr regelmäßig |
| `luh-modulbeschreibung` | 41 | 37 | 1 325 | neu, gemeinsame LUH-Vorlage über 6 Fakultäten |
| `wiwi-modulhandbuch` | 5 | 5 | 446 | neu, Datenbank-Ausgabe |
| `fbg-modulhandbuch` | 5 | 4 | 316 | neu, Datenbank-Ausgabe |
| `phil-kv-tabelle` | 20 | 11 | 232 | neu, zweispaltige Tabelle |
| `maphy-katalog` | 17 | 5 | 191 | neu, Blockformat |
| `scanned` (ohne Textebene) | 23 | 17 | ≈ 450 (≈ 1 090 Seiten) | OCR nötig |
| `overview-only` | 1 | 1 | – | nur Curriculum (WATENV) |
| `none` | 82 | – | – | kein öffentliches Modulhandbuch gefunden |

Modulzahlen zählen Modulbeschreibungen je PDF; Module, die in mehreren Katalogen stehen (z. B. ET-Module in ETBSc17
und ETBSc25), sind mehrfach gezählt.

**Direkt mit dem FEI-Parser lesbar: 22 Einträge** (alle FEI-Studiengänge, Mechatronik B.Sc., die Informatik- und
Elektrotechnik-Fächer im Lehramt) plus der FEI-Anteil von Digital Business und Wirtschaftsingenieurwesen B.Sc.
**Gemeinsame Vorlagen außerhalb der FEI: 106 Einträge** in sechs Formaten (davon 41 in der fakultätsübergreifenden
LUH-Vorlage). **Ohne Textebene: 23**, **ohne Handbuch: 82**, **nur Übersicht: 1**.

### Nach Fakultät

| Fakultät | Einträge | modkat | MB | LUH-Vorlage | MaPhy | FBG | WiWi | Phil-Tabelle | ohne Text | Übersicht | keins |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Philosophische Fakultät | 91 | | | 9 | | | | 20 | 9 | | 53 |
| Naturwissenschaftliche Fakultät | 39 | | | 18 | | | | | 14 | | 7 |
| Elektrotechnik und Informatik | 23 | 22 | | | | | | | | | 1 |
| Maschinenbau | 22 | | 18 | | | | | | | | 4 |
| Mathematik und Physik | 20 | | | 1 | 17 | | | | | | 2 |
| Bauingenieurwesen und Geodäsie | 17 | | | 4 | | 5 | | | | 1 | 7 |
| Architektur und Landschaft | 11 | | | 7 | | | | | | | 4 |
| Wirtschaftswissenschaften | 5 | | | | | | 5 | | | | |
| Juristische Fakultät | 4 | | | | | | | | | | 4 |
| LNQE (Nanotechnologie, fakultätsübergreifend) | 2 | | | 2 | | | | | | | |

Fächer im Lehramt sind der Fakultät des Fachs zugeordnet (Biologie → Naturwissenschaften, Informatik → FEI usw.),
alle übrigen der Philosophischen Fakultät.

## Die Formate im Einzelnen

Feldnamen wörtlich aus den PDFs, Inhalte anonymisiert.

**`modkat-FEI`** – Datenbank der FEI, bekannt. Je Modul: Titel, englischer Titel, „Zuständigkeit“, „Einordnung und
Belegungsmöglichkeit in Studiengänge“, „Angebot im WS 2026/27: …“, „Gewählte Prüfungsform“, „Studienleistung“,
„Studentische Arbeitsleistung“, „SWS“, „LP (ECTS)“, „Modulverantwortung“, „Qualifikationsziele“. Vorne eine
Übersicht je Kompetenzbereich („Modul | LP | SWS | PL | SL | Frequenz“). Modulgrenze: „Modulverantwortung“.

**`mb-modulkatalog`** – Maschinenbau (auch Medizintechnik, Nachhaltige Ingenieurwissenschaft, Produktion und
Logistik, Optische Technologien, Biomedizintechnik, Mechatronik und Robotik, AI-driven, Mechanical Engineering).
Jede Seite beginnt mit „Stand: … <Studiengang> PO <Jahr>“, „Modul: <Titel>“, „Module: <englisch>“; Felder
„Modultyp | Kompetenzbereich“, „Angebot im | Dauer | Sprache | ECTS | Empfohlen ab“ (Werte in der Zeile darunter,
z. B. „WiSe | 1 Semester | Deutsch | 6 | Zulassung WiSe: 1. Semester“), „Prüfungsleistungen (PL) / Studienleistung
(SL)“ mit „Art | ECTS | Dauer / Umfang | Notenskala“, „Workload“, „Präsenzstudienzeit“, „Selbststudienzeit“,
„Modulverantwortliche-r“, „Aufbau des Moduls“, „Voraussetzungen für die Teilnahme“, „Qualifikationsziele“,
„Verwendbarkeit in anderen Studiengängen“. Vorne Studienverlaufsgrafik und Wahlpflichtlisten je Vertiefung.
Modulgrenze: Wechsel des Titels nach „Modul:“. Ein Katalog je PO und Semester, gleiches Namensmuster
(`Modulkatalog_<KÜRZEL>_<BSC|MSc>_PO_<JJ>.pdf`), Archiv bis 2017 auf derselben Seite.

**`luh-modulbeschreibung`** – gemeinsame LUH-Vorlage in Naturwissenschaften, Architektur und Landschaft, Geodäsie,
Quantum Engineering, Nanotechnologie und einigen Instituten der Philosophischen Fakultät (Atlantic Studies,
Bildungswissenschaften, Philosophie, Werte und Normen, Sozialwissenschaften, Geschichte M.A., Sport-Master).
Kopfblock als Tabelle: „Modultitel“, „Kennnummer / Prüfcode“, „Studiengang“, „Modultyp“, „Leistungspunkte“,
„Häufigkeit des Angebots“, „Sprache“, „Kompetenzbereich“, „Empfohlenes Fachsemester“, „Moduldauer“, „Studentische
Arbeitsbelastung“ (Präsenz/Selbststudium), „Weitere Verwendung des Moduls“; danach nummeriert „1 Qualifikationsziele“,
„2 Inhalte des Moduls“, „3 Lehrformen und Lehrveranstaltungen“, „4a Teilnahmevoraussetzungen“, „4b Empfehlungen“,
„5 Voraussetzungen für die Vergabe von Leistungspunkten“ (Studienleistungen / Prüfungsleistungen), „6 Literatur“,
„7 Weitere Angaben“, „8 Organisationseinheit“, „9 Modulverantwortliche/r“. Englische Fassung: „Module Title“,
„Credit Points“, „Frequency of Occurrence“, „Recommended Semester of Study“. Modulgrenze: „Häufigkeit des Angebots“.
Kleine Abweichungen (Geodäsie ohne Nummern, Biologie mit „Kenn-Nr.“ je Lehrveranstaltung).

**`maphy-katalog`** – Mathematik, Physik, Umweltmeteorologie, Lehramt Mathe/Physik. Je Modul: Titel (englisch in
Klammern), „Semesterlage Wintersemester, jährlich“, „Verantwortlich“, „Art der Lehrveranstaltung(en)“,
„Lehrveranstaltungen (SWS) … (4+2) SWS“, „Leistungsnachweise Studienleistung: … Prüfungsleistung: …“,
„Notenzusammensetzung“, „Leistungspunkte (ECTS)“, „…h Präsenzstudium / …h Selbststudium“, „Kompetenzziel:“,
„Inhalte:“, „Vorkenntnisse:“, „Modulverwendbarkeit:“. Kein empfohlenes Fachsemester im Modul – das steht in der PO.
Modulgrenze: „Semesterlage“.

**`fbg-modulhandbuch`** – Bauingenieurwesen (B.Sc. Bau- und Umweltingenieurwesen, M.Sc. Bauingenieurwesen,
Umweltingenieurwesen, Computational Methods in Engineering). Je Modul: Titel deutsch/englisch, „Mögl.
Prüfungsleistungen: K/KA/MP/HA/…“, „Studienleistungen: …“, „SWS / Art 2V / 2Ü“, „Sprache D“, „LP 5“, „Semester WS“,
„P-Form VbP: … P-Form PZ I: … P-Form PZ II: …“, „Ziel des Moduls“, „Inhalt des Moduls“, „Workload“. Englisch
(CME): „Possible forms of examination“, „Course achievements“, „CP“. Prüfungsformen als Kürzel (Legende vorn).
Modulgrenze: „Mögl. Prüfungsleistungen“. Dazu je Vertiefung eine „Modulübersicht“ (als Verlaufsplan eingetragen).

**`wiwi-modulhandbuch`** – Wirtschaftswissenschaften, **je Semester** (neuestes: SS 2026; WS 2026/27 war am
04.11.2026 noch nicht verlinkt). Je Modul: Titel deutsch/englisch, Tabelle „Verwendbarkeit | Art | Semester von – bis“
(z. B. „Bachelor … – Kompetenzbereich … | Pflichtmodul | 1 – 1“), „Leistungspunkte (ECTS)“, „Workload in h
180 / 42 / 138“, „Modulverantwortung“, „Qualifikationsziele“, „Prüfungsleistung im Sommersemester 2026“,
„Prüfungsnummer“, „Prüfungsform (und -dauer)“, danach Lehrveranstaltungen („Belegnr., Titel, SWS und Art | Termin und
Raum | Dozent(in) | Sprache“). Digital Business als semesterunabhängige Fassung. Modulgrenze: „Workload in h“.

**`phil-kv-tabelle`** – Institute der Philosophischen Fakultät (Politikwissenschaft alle Fächer, Sonderpädagogik B.A./
M.A., Geschichte Lehramt, Sport Lehramt; optisch auch Englisch). Zweispaltig: „Anbieter“, „Modulverantwortliche/r“,
„Häufigkeit des Angebots“, „Dauer des Moduls“, „Semesterlage“, „Verwendbarkeit“, „Eingangsvoraussetzungen“, „Art der
LV/SWS“, „ECTS-LP/Workload“ (z. B. „12 LP (3+3+3+3)/360 Stunden“), „Notenskala“, „Prüfungsleistungen“,
„Studienleistungen“, „Lehrinhalte“, „Kompetenzziele“. Modulgrenze: „Anbieter“.

**`scanned`** – keine Textebene: Word-Exporte, in denen jedes Wort als eigenes Bild gezeichnet ist (pypdf und PDFKit
liefern keinen Text; gerendert sehen die Seiten normal aus). Stichproben gerendert: Chemie B.Sc., Life Science und
Soziologie zeigen die **LUH-Vorlage**, Englisch die **Phil-Tabelle** – nach OCR (z. B. Vision auf dem Gerät) also mit
denselben Regeln lesbar. Betroffen (17 PDFs): Chemie B.Sc. PO 2024, Chemie M.Sc. PO 2024, Chemie FüBa, Chemie M.Ed.
Gymnasium, Chemie Technical Education/LBS, Biochemie B.Sc. Pflicht, Life Science B.Sc. (Pflicht, Wahlpflicht) und
M.Sc. (PO 2022, PO 2024), Wirtschaftsgeographie M.Sc. (WIN) und M.A., Soziologie M.A., Hochschule-Wissenschaft-
Gesellschaft M.A., Religion in the Public Sphere, Religionswissenschaft/Werte und Normen FüBa, Englisch (alle Lehrämter).

## Ohne öffentliches Modulhandbuch (82 Einträge)

- **Sammel-Einträge der Lehramts-Studiengänge** (Fächerübergreifender Bachelor, Technical Education, M.Ed. Gymnasien,
  berufsbildende Schulen, LBS-Sprint, Sonderpädagogik, drei Zertifikate): die Module stehen bei den **Fächern**; die
  Einträge tragen die gemeinsame PO.
- **Fächer ohne gefundenen Katalog**: Deutsch (7), Evangelische/Katholische Religion und Theologie (14), Musik (4),
  Spanisch (4), Kunst (2), Darstellendes Spiel (2), Sachunterricht (2), Angewandte Sprachwissenschaft, Pflege, sowie die
  technischen Fächer im berufsbildenden Lehramt Bautechnik, Holztechnik, Metalltechnik, Farbtechnik und Raumgestaltung
  (je 3). Die Institutsseiten dieser Fächer (Germanistik, Romanistik, Theologie, Musik, Kunst, Berufspädagogik) wurden
  im Anfragebudget nicht mehr besucht.
- **Studiengänge**: Rechtswissenschaften (nur Studienordnung, als Verlaufsplan eingetragen), IT-Recht LL.B./LL.M.,
  European Legal Practice (nur Studienverlaufsseiten), Biochemie M.Sc. (gemeinsam mit der MHH), Meteorologie M.Sc.,
  Neuere Deutsche Literaturwissenschaft, North American Studies, Arbeitswissenschaft, Wasser und Umwelt (nur
  HTML-Modulangebot), sowie die auslaufenden Gartenbau, International Horticulture, Molekulare und Angewandte
  Pflanzenwissenschaften, Food Research, Territorial Development, Deutsche und Englische Linguistik, Energy Technology,
  International Mechatronics, Kautschuktechnologie und zwei Weiterbildungszertifikate.
- Ersatzquelle für alle: die Prüfungsordnung im Register (`po_documents`); laut Architektur-Seite enthalten die POs eine
  „Modulübersicht“ in der Anlage.

## Quellen und Vorgehen

1. Startseite → Studium → Studienangebot → **Gesamtübersicht A–Z** (`/studium/studienangebot/gesamt`, eine Seite mit
   allen 204 Einträgen, Art „Fach im 2-Fächer Studiengang“/„Vertiefungsrichtung“, Studienbeginn).
2. **Ordnungen**: die 106 Seiten `/studium/im-studium/pruefungsinfos-fachberatung/<studiengang>/ordnungen` stehen in der
   Sitemap von www.uni-hannover.de (2 Anfragen statt 200 Umwege über die Prüfungsinfo-Seiten). Geltende POs: Titel mit
   Datum, ohne „Auslaufende“, Übersetzungen, Praktikums-/Zwischenprüfungsordnungen. `po` im Register = Jahr des
   Katalogs (z. B. MB „PO 17“) oder, ohne Katalogangabe, das erste Datum im PO-Titel (Fassung); Altfassungen ohne Titel
   werden über das Jahr im Dateinamen zugeordnet.
3. **Fakultäts- und Institutsseiten** (175 Seiten, im Skript als `DISCOVERY_PAGES`), je Fakultät eine Sammelseite, wo
   es sie gibt (Maschinenbau, Mathematik/Physik), sonst Studiengangsseiten.
4. **modkat**: Übersicht `https://modkat.fei.uni-hannover.de/` listet 23 Kürzel, alle neuestes Semester **WS 2026/27**:
   DiBu, ETBSc17, ETBSc25, ETMSc17, EntBsc24, EntMsc24, INFBSc22, INFMSc25, L_BSc_EINF, L_BSc_ZINF, L_BSc_ET,
   L_BSc_INF, L_MEd_EINF, L_MEd_ZINF, L_MEd_ET, L_MEd_INF, L_MEd_Sp_ET, L_MEd_Sp-INF, MechBSc17, MechBSc25, TIBSc25,
   TIMSc25, WiIngBSc22 (Liste mit Bezeichnung in `modkat_codes`).

### Hinweise für den Katalog-Bau (andere Arbeitspakete)

- **Dateimuster weicht von der Spezifikation ab**: tatsächlich
  `https://modkat.fei.uni-hannover.de/material/modkat-full-<KÜRZEL>-<WS_JJJJ_JJ|SS_JJJJ>.pdf` (daneben
  `semesterangebot-…` und `jahresliste-…`). `modkat.dbs.uni-hannover.de` antwortete am 04.11.2026 nicht
  (Zeitüberschreitung bei robots.txt und `/modkat/lvk/`), nicht erneut versucht.
- **Technische Informatik heißt jetzt `TIBSc25`/`TIMSc25`** (nicht mehr TIBSc22); Informatik B.Sc. weiter `INFBSc22`,
  Informatik M.Sc. `INFMSc25`. Die PO von TI/Informatik ist weiterhin die „vom 23.03.2017“ (QIS „PO-Version 2017“).
- `qis_labels` sind geraten: „<Studiengang> (PO-Version <Jahr>)“, „<Studiengang> (PO <Jahr>)“, „Bachelor/Master
  <Studiengang>“, der Name allein; bei Fächern zusätzlich der Gesamtstudiengang („Fächerübergreifender Bachelor
  (PO-Version 2016)“). Erst mit echten QIS-Zeilen prüfen.
- `regular_semesters`: aus der Studiengangsseite, wo sie im Zwischenspeicher liegt (`regular_semesters_source:
  "steckbrief"`, 19 Einträge), sonst Regelwert (Bachelor 6, Master 4, Staatsexamen 10; `"regel"`). `total_lp` 30 je
  Semester; bei Fächern `null` (Anteil hängt von Erst-/Zweitfach ab).

## robots.txt

Alle TYPO3-Seiten der LUH (www, Fakultäten, Institute) haben dieselbe robots.txt: `Disallow` für
`/typo3conf/system`, `*naw_securedl*`, `*type=1513087837*` (Mobilmenü), `*tx_securedownloads*`,
`*tx_t3luhunisearch_search*`, `*footercontent*`, `*content-for-each-page*`; keine Regel betrifft Studien- oder
PDF-Seiten. Geprüft vor dem ersten Abruf je Host (25 Hosts), Ergebnis im Zwischenspeicher. `modkat.fei` hat keine
robots.txt (404 = erlaubt). Die Sitemaps der Fakultäten (`/sitemap.xml`) liefern 404, daher die Suche über die
Studienseiten. Nie angefragt: Stud.IP, QIS/LSF (Links darauf werden verworfen), Anmeldeseiten.

## Erneut ausführen

```
.venv/bin/python tools/luh-programs.py all      # alles; aus dem Zwischenspeicher ohne neue Anfrage
.venv/bin/python tools/luh-programs.py check    # Modulhandbuch-Links auf den Suchseiten, die nicht im Register stehen
.venv/bin/python tools/luh-programs.py build     # nur JSON neu schreiben
.venv/bin/python -m pytest -q tests/test_study_sources_luh.py
```

Zwischenspeicher und PDFs: `~/Studora-Builds/luh-crawl/` (`index.json` mit Anfragezähler und Protokoll, `cache/`,
`ordnungen.json`, `formats.json` mit Feldzählungen je PDF). Eine URL wird nie zweimal geholt, auch nicht nach einem
Fehler; für ein neues Semester den betroffenen Eintrag in `index.json` löschen oder die neue Datei-URL im Skript
eintragen (`check` zeigt neue Links). Obergrenze 600 Anfragen über alle Läufe.

<!-- grundstock:start (tools/build-luh-seed.py) -->
## Grundstock (Modulkataloge in der App)

Erzeugt von `tools/build-luh-seed.py` aus den Fakten in `~/Studora-Builds/luh-seed/{fei,a,b}/` (FEI: modkat-Leser
aus `app/study_catalog.py` mit eingemischtem Studienverlaufsplan; a/ und b/: Leser in `app/catalog_formats/`).
Ressource `apps/apple/UniFlow/Resources/StudyCatalogSeed/` (gzip, nur geteilte Fakten ohne Modultexte), Verzeichnis
`luh-index.json`. Die App sucht dort zuerst (Stand `seed`, „Aus dem StudiNow-Grundstock“), dann in der
Bibliothek, erst dann lädt sie die PDF; Modultexte lädt sie erst, wenn jemand ein Modul öffnet (einmal je Katalog).

| Fakultät | Kataloge | Einträge | Module | Formate |
|---|---:|---:|---:|---|
| Fakultät für Architektur und Landschaft | 7 | 7 | 288 | luh-modulbeschreibung 7 |
| Fakultät für Bauingenieurwesen und Geodäsie | 9 | 9 | 649 | fbg-modulhandbuch 5, luh-modulbeschreibung 4 |
| Fakultät für Elektrotechnik und Informatik | 21 | 24 | 1919 | modkat-FEI 21 |
| Fakultät für Maschinenbau | 18 | 18 | 1753 | mb-modulkatalog 18 |
| Fakultät für Mathematik und Physik | 18 | 18 | 267 | luh-modulbeschreibung 1, maphy-katalog 17 |
| Naturwissenschaftliche Fakultät | 32 | 32 | 1176 | luh-modulbeschreibung 18, scanned 14 |
| Philosophische Fakultät | 38 | 38 | 581 | luh-modulbeschreibung 9, phil-kv-tabelle 20, scanned 9 |
| Wirtschaftswissenschaftliche Fakultät | 7 | 7 | 342 | modkat-FEI 2, wiwi-modulhandbuch 5 |
| fakultätsübergreifend (Laboratorium für Nano- und Quantenengineering, LNQE) | 2 | 2 | 252 | luh-modulbeschreibung 2 |
| **zusammen** | **152** | **151** | **7227** | |

Nach Format: `fbg-modulhandbuch` 5 Kataloge / 424 Module; `luh-modulbeschreibung` 41 Kataloge / 1693 Module; `maphy-katalog` 17 Kataloge / 225 Module; `mb-modulkatalog` 18 Kataloge / 1753 Module; `modkat-FEI` 23 Kataloge / 1934 Module; `phil-kv-tabelle` 20 Kataloge / 267 Module; `scanned` 23 Kataloge / 604 Module; `wiwi-modulhandbuch` 5 Kataloge / 327 Module.
Mit Studienverlaufsplan: 2. Registereinträge der Erhebung: 234, davon im Grundstock: 151.
Datei `luh.json.gz`: 305 KB gzip, 2816 KB JSON, 152 Kataloge.
Nachbearbeitung: 35 Module in Wahlbereichen von `pflicht` auf `wahlpflicht`/`wahl`, 0 doppelte Kataloge, 0 doppelte Module, 0 ungültige, 0 nicht zugeordnete verworfen.

Neu bauen: `.venv/bin/python tools/build-luh-seed.py` (prüfen: `--check`, Vorschau: `--diff`).
<!-- grundstock:end -->

## Leseprogramme Formate A

Leseprogramme für vier Formate außerhalb der FEI (`app/catalog_formats/`: `luh_modulbeschreibung.py`, `mb_modulkatalog.py`, `wiwi_modulhandbuch.py`, `fbg_modulhandbuch.py`, gemeinsame Bausteine in `formats_a_common.py`, Register `FORMATS` in `__init__.py`). Gelesen wird einmal auf dem Mac aus dem Zwischenspeicher (kein Netz), Textgewinnung und Normalisierung wie `app/study_catalog.py`; geprüft mit dem gemeinsamen Validator. Ausgabe nur Fakten nach `~/Studora-Builds/luh-seed/a/<registry-key>.json` (außerhalb des Repos); Inhalte, Lernziele und Literatur liefern die Parser getrennt (nur lokal, nicht geschrieben). Erneut: `.venv/bin/python tools/luh-catalogs-a.py --docs`. Tests mit erfundenen Texten: `tests/test_catalog_formats_a.py` (Fixture `packages/shared-contracts/fixtures/catalog-formats-a/`, Erzeuger `tools/gen-catalog-formats-a-fixture.py [--check]`).

Hinweise: `code` ist bei diesen Formaten der Registerschlüssel ohne `luh|` (kein Kürzel wie bei modkat). Katalogsemester aus dem Register, sonst aus dem Handbuch („Wintersemester 2026/2027“, „Stand: TT.MM.JJJJ“), sonst WS 2026/27. Ein zweites Handbuch desselben Formats (`more_catalogs`, z. B. Wahlpflicht) wird angehängt. Gleiche Module in mehreren Bereichen/Vertiefungen stehen einmal im Katalog (erster Bereich). Die WiWi-Semesterfassungen nennen keinen Turnus; er kommt nur aus der semesterunabhängigen Fassung (Digital Business), wenn der Titel gleich ist. FBG: Prüfung = gewählte Form je Prüfungszeitraum („P-Form“), sonst „möglich: K/KA/…“. Schätzungen aus dem Register zählen Modulbeschreibungen mit Wiederholungen (gleiches Modul je Vertiefung) mit.

| Format | Einträge | Module gelesen | Schätzung | Titel | LP | Prüfung | Studienl. | Turnus | Semester | Sprache | Aufwand | Bereich | Fehler |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `luh-modulbeschreibung` | 41 | 1693 | 1713 | 100 | 99 | 88 | 74 | 86 | 86 | 99 | 100 | 76 | 0 |
| `mb-modulkatalog` | 18 | 1753 | 1698 | 100 | 100 | 93 | 34 | 100 | 99 | 100 | 100 | 100 | 0 |
| `wiwi-modulhandbuch` | 5 | 327 | 446 | 100 | 100 | 98 | 2 | 29 | 100 | 99 | 100 | 100 | 0 |
| `fbg-modulhandbuch` | 5 | 424 | 424 | 100 | 100 | 99 | 20 | 100 | 11 | 100 | 100 | 96 | 0 |

Je Eintrag (Werte in % der gelesenen Module; Turnus zählt nur WS/SS/WS+SS, nicht „unbekannt“):

| Eintrag | Format | Module / Schätzung | LP | Prüfung | Turnus | Semester | Sprache | Bereich | Validator |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|
| ai-driven-mechatronics-and-robotics|m.sc.|2025 | mb-modulkatalog | 59 / 58 | 100 | 92 | 100 | 100 | 100 | 100 | ok |
| architektur-und-staedtebau|m.sc.|2020 | luh-modulbeschreibung | 96 / 95 | 100 | 100 | 53 | 100 | 100 | 96 | ok |
| architektur|b.sc.|2019 | luh-modulbeschreibung | 53 / 53 | 100 | 98 | 66 | 96 | 98 | 0 | ok |
| atlantic-studies-in-history-culture-and-society|m.a.|2016 | luh-modulbeschreibung | 12 / 12 | 100 | 83 | 100 | 100 | 100 | 83 | ok |
| bau-und-umweltingenieurwesen|b.sc.|2025 | fbg-modulhandbuch | 48 / 48 | 100 | 98 | 100 | 96 | 100 | 96 | ok |
| bauingenieurwesen|m.sc.|2025 | fbg-modulhandbuch | 108 / 108 | 100 | 99 | 100 | 0 | 100 | 95 | ok |
| bildungswissenschaften|m.a.|2020 | luh-modulbeschreibung | 26 / 26 | 100 | 46 | 100 | 100 | 100 | 54 | ok |
| biologie-im-faecheruebergreifenden-bachelor|b.sc.|2016 | luh-modulbeschreibung | 20 / 20 | 100 | 95 | 100 | 100 | 100 | 25 | ok |
| biologie-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016 | luh-modulbeschreibung | 12 / 12 | 100 | 100 | 100 | 100 | 100 | 75 | ok |
| biologie|b.sc.|2018 | luh-modulbeschreibung | 74 / 72 | 100 | 82 | 99 | 99 | 100 | 100 | ok |
| biomedizintechnik|m.sc.|2017 | mb-modulkatalog | 74 / 72 | 100 | 93 | 100 | 99 | 100 | 100 | ok |
| biomedizintechnik|m.sc.|2026 | mb-modulkatalog | 77 / 75 | 100 | 92 | 100 | 99 | 100 | 100 | ok |
| chemie-1|m.sc.|2017 | luh-modulbeschreibung | 63 / 63 | 100 | 97 | 100 | 100 | 100 | 100 | ok |
| chemie|b.sc.|2016 | luh-modulbeschreibung | 43 / 43 | 100 | 26 | 95 | 93 | 95 | 100 | ok |
| computational-methods-in-engineering|m.sc.|2025 | fbg-modulhandbuch | 63 / 63 | 100 | 100 | 100 | 0 | 100 | 100 | ok |
| digital-business|b.sc.|2026 | wiwi-modulhandbuch | 67 / 67 | 100 | 93 | 88 | 100 | 94 | 100 | ok |
| erdkunde-geographie-im-faecheruebergreifenden-bachelor|b.a.-b.sc.|2016 | luh-modulbeschreibung | 43 / 43 | 95 | 84 | 47 | 95 | 95 | 0 | ok |
| erdkunde-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016 | luh-modulbeschreibung | 43 / 43 | 95 | 84 | 47 | 95 | 95 | 0 | ok |
| european-master-in-landscape-architecture-emila|m.sc.|2015 | luh-modulbeschreibung | 4 / 4 | 100 | 75 | 100 | 100 | 100 | 100 | ok |
| geodaesie-und-geoinformatik-vertiefung-geomatik|m.sc.|2025 | luh-modulbeschreibung | 63 / 82 | 98 | 86 | 94 | 92 | 100 | 100 | ok |
| geodaesie-und-geoinformatik-vertiefung-navigation-und-umweltrobotik|m.sc.|2025 | luh-modulbeschreibung | 63 / 82 | 98 | 86 | 94 | 92 | 100 | 100 | ok |
| geodaesie-und-geoinformatik-vertiefung-remote-sensing-and-gis|m.sc.|2025 | luh-modulbeschreibung | 63 / 82 | 98 | 86 | 94 | 92 | 100 | 100 | ok |
| geodaesie-und-geoinformatik|b.sc.|2025 | luh-modulbeschreibung | 36 / 36 | 100 | 83 | 100 | 100 | 100 | 100 | ok |
| geographie|b.a.-b.sc.|2015 | luh-modulbeschreibung | 43 / 43 | 95 | 84 | 47 | 95 | 95 | 0 | ok |
| geowissenschaften-1|m.sc.|2020 | luh-modulbeschreibung | 36 / 60 | 100 | 97 | 100 | 100 | 97 | 100 | ok |
| geowissenschaften|b.sc.|2016 | luh-modulbeschreibung | 52 / 52 | 98 | 50 | 90 | 98 | 100 | 100 | ok |
| geschichte-ma|m.a.|2020 | luh-modulbeschreibung | 22 / 22 | 100 | 100 | 100 | 95 | 100 | 0 | ok |
| konstruktiver-ingenieurbau-fernstudium|m.sc.|2019 | fbg-modulhandbuch | 108 / 108 | 100 | 99 | 100 | 0 | 100 | 95 | ok |
| landschaftsarchitektur-und-umweltplanung|b.sc.|2024 | luh-modulbeschreibung | 39 / 39 | 100 | 100 | 90 | 100 | 100 | 100 | ok |
| landschaftsarchitektur|m.sc.|2015 | luh-modulbeschreibung | 32 / 32 | 100 | 97 | 100 | 97 | 100 | 100 | ok |
| landschaftswissenschaften|m.sc.|2019 | luh-modulbeschreibung | 41 / 24 | 100 | 80 | 93 | 95 | 93 | 83 | ok |
| landschaftswissenschaften|m.sc.|2026 | luh-modulbeschreibung | 42 / 25 | 100 | 79 | 93 | 95 | 93 | 81 | ok |
| lebensmittelwissenschaft-im-bachelorstudiengang-technical-education|b.sc.|2016 | luh-modulbeschreibung | 17 / 17 | 100 | 100 | 0 | 100 | 100 | 100 | ok |
| lebensmittelwissenschaft-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint|m.ed.|2026 | luh-modulbeschreibung | 4 / 4 | 100 | 100 | 0 | 100 | 100 | 0 | ok |
| lebensmittelwissenschaft-im-masterstudiengang-lehramt-an-berufsbildenden-schulen|m.ed.|2016 | luh-modulbeschreibung | 10 / 10 | 100 | 100 | 0 | 100 | 100 | 100 | ok |
| maschinenbau-1|m.sc.|2017 | mb-modulkatalog | 212 / 206 | 100 | 96 | 100 | 100 | 100 | 100 | ok |
| maschinenbau-1|m.sc.|2026 | mb-modulkatalog | 213 / 207 | 100 | 96 | 100 | 100 | 100 | 100 | ok |
| maschinenbau|b.sc.|2017 | mb-modulkatalog | 76 / 72 | 100 | 95 | 100 | 100 | 100 | 100 | ok |
| maschinenbau|b.sc.|2026 | mb-modulkatalog | 81 / 77 | 100 | 91 | 100 | 100 | 100 | 100 | ok |
| mechanical-engineering-mechanical-engineering-track|m.sc.|2026 | mb-modulkatalog | 49 / 48 | 100 | 94 | 100 | 100 | 100 | 100 | ok |
| mechatronik-und-robotik|m.sc.|2017 | mb-modulkatalog | 147 / 143 | 100 | 96 | 100 | 99 | 100 | 100 | ok |
| mechatronik-und-robotik|m.sc.|2025 | mb-modulkatalog | 140 / 136 | 100 | 95 | 100 | 99 | 100 | 100 | ok |
| medizintechnik|b.sc.|2026 | mb-modulkatalog | 62 / 61 | 100 | 94 | 100 | 100 | 100 | 100 | ok |
| molekulare-mikrobiologie|m.sc.|2016 | luh-modulbeschreibung | 31 / 23 | 100 | 97 | 100 | 94 | 100 | 100 | ok |
| nachhaltige-gesundheitsfoerderung-durch-sport|m.sc.|2019 | luh-modulbeschreibung | 11 / 11 | 100 | 100 | 100 | 100 | 100 | 0 | ok |
| nachhaltige-ingenieurwissenschaft-1|m.sc.|2024 | mb-modulkatalog | 125 / 121 | 100 | 95 | 99 | 98 | 99 | 100 | ok |
| nachhaltige-ingenieurwissenschaft|b.sc.|2021 | mb-modulkatalog | 109 / 106 | 99 | 95 | 99 | 99 | 99 | 99 | ok |
| nanotechnologie-1|m.sc.|2016 | luh-modulbeschreibung | 126 / 127 | 99 | 99 | 100 | 37 | 99 | 100 | ok |
| nanotechnologie|b.sc.|2016 | luh-modulbeschreibung | 126 / 127 | 99 | 99 | 100 | 37 | 99 | 100 | ok |
| optische-technologien-laser-und-photonik-bsc|b.sc.|2022 | mb-modulkatalog | 47 / 46 | 100 | 81 | 100 | 100 | 100 | 100 | ok |
| optische-technologien|m.sc.|2017 | mb-modulkatalog | 67 / 65 | 100 | 82 | 100 | 100 | 100 | 100 | ok |
| optische-technologien|m.sc.|2026 | mb-modulkatalog | 61 / 60 | 100 | 87 | 100 | 100 | 100 | 100 | ok |
| pflanzenbiotechnologie-2|b.sc.|2022 | luh-modulbeschreibung | 55 / 54 | 100 | 80 | 98 | 96 | 100 | 100 | ok |
| pflanzenbiotechnologie|m.sc.|2022 | luh-modulbeschreibung | 52 / 35 | 100 | 75 | 100 | 77 | 100 | 100 | ok |
| philosophie-im-faecheruebergreifenden-bachelor|b.a.|2016 | luh-modulbeschreibung | 18 / 18 | 100 | 100 | 100 | 100 | 100 | 0 | ok |
| philosophie-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016 | luh-modulbeschreibung | 18 / 18 | 100 | 100 | 100 | 100 | 100 | 0 | ok |
| philosophy-of-science|m.a.|2018 | luh-modulbeschreibung | 12 / 12 | 100 | 100 | 83 | 100 | 100 | 0 | ok |
| produktion-und-logistik-bsc|b.sc.|2017 | mb-modulkatalog | 54 / 50 | 100 | 94 | 100 | 100 | 100 | 100 | ok |
| produktion-und-logistik-msc|m.sc.|2017 | mb-modulkatalog | 100 / 95 | 100 | 93 | 100 | 99 | 100 | 100 | ok |
| quantum-engineering|m.sc.|2022 | luh-modulbeschreibung | 42 / 42 | 100 | 88 | 100 | 88 | 100 | 0 | ok |
| sozialwissenschaften|b.a.|2016 | luh-modulbeschreibung | 75 / 75 | 100 | 97 | 56 | 100 | 100 | 100 | ok |
| umwelt-und-regionalplanung-major-naturschutz-und-landschaftsplanung|m.sc.|2020 | luh-modulbeschreibung | 32 / 32 | 100 | 84 | 94 | 78 | 100 | 44 | ok |
| umwelt-und-regionalplanung-major-regionalplanung|m.sc.|2020 | luh-modulbeschreibung | 32 / 32 | 100 | 84 | 94 | 78 | 100 | 44 | ok |
| umweltingenieurwesen|m.sc.|2025 | fbg-modulhandbuch | 97 / 97 | 100 | 100 | 100 | 0 | 100 | 94 | ok |
| werte-und-normen-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016 | luh-modulbeschreibung | 11 / 11 | 100 | 100 | 100 | 100 | 100 | 0 | ok |
| wirtschaftsingenieurwesen-1|m.sc.|2018 | wiwi-modulhandbuch | 101 / 124 | 100 | 100 | 0 | 100 | 100 | 100 | ok |
| wirtschaftsingenieurwesen|b.sc.|2022 | wiwi-modulhandbuch | 26 / 30 | 100 | 96 | 69 | 100 | 100 | 100 | ok |
| wirtschaftswissenschaft-1|m.sc.|2018 | wiwi-modulhandbuch | 99 / 185 | 100 | 100 | 0 | 100 | 100 | 100 | ok |
| wirtschaftswissenschaft|b.sc.|2017 | wiwi-modulhandbuch | 34 / 40 | 100 | 97 | 53 | 100 | 100 | 100 | ok |

## Leseprogramme Formate B und Scans

Leseprogramme für `phil-kv-tabelle` (`app/catalog_formats/phil_kv_tabelle.py`), `maphy-katalog`
(`maphy_katalog.py`) und die PDFs ohne Textebene (`ocr_pages.py`, Register `FORMATS` in `__init__.py`). Gelesen
einmal auf dem Mac aus `~/Studora-Builds/luh-crawl/` (kein Netz); Ausgabe nur Fakten (geprüft mit
`app.study_catalog.validate`) nach `~/Studora-Builds/luh-seed/b/<Registerschlüssel>.json`; Inhalte, Lernziele und
Literatur liefern die Parser getrennt (nur lokal, nicht geschrieben). `code` = Registerschlüssel ohne `luh|` (wie
Formate A). Erneut: `.venv/bin/python -m app.catalog_formats.ocr_pages ocr` (fehlende OCR-Seiten) und
`… ocr_pages seed` (alle Einträge lesen, prüfen, schreiben). Tests mit erfundenen Seiten:
`tests/test_catalog_formats_b.py` (Fixture `packages/shared-contracts/fixtures/catalog-formats-b/`, Erzeuger
`tools/gen-catalog-formats-b-fixture.py [--check]`).

**Textgewinnung.** Beide Formate sind Tabellen; gelesen wird pypdf im Layout-Modus (`extraction_mode="layout"`,
Spalten bleiben erhalten, Wörter ganz). Die Wertspalte ergibt sich aus der häufigsten Einrückung des zweiten
Textblocks; ohne Spaltenlage (normale pypdf-Texte) wird am bekannten Feldnamen getrennt.

**`phil-kv-tabelle`.** Modulkopf links „Pflichtmodul / Wahlpflichtmodul / Basismodul B / Modul MA 2 / Bachelorarbeit“,
rechts Titel und Kennung („Modul-Code: xxxx“ = keine, „10 100“, „9999“). Feldnamen über mehrere Zeilen
(„Semesterlage und / Häufigkeit des Angebots“, „Prüfungs- und / Studienleistungen“). Turnus aus „Häufigkeit des
Angebots“, sonst „Semesterlage“; empfohlenes Semester aus „Semesterlage“/„Studiensemester“ („empfohlen im 1.“,
„1.- 2. Semester“, „Ab dem 3.“); LP und Arbeitsaufwand aus „ECTS-LP/Workload“ (Summe Präsenz + Selbststudium, wenn
keine Gesamtzahl; unter 20 h je LP → keine Angabe). Bereich aus Abschnittsüberschriften („Pflichtbereich
(Kompetenzbereich: Diagnostik)“, „Schwerpunkt LE“, „Politik-Wirtschaft als Erstfach“), sonst aus dem Kopf
(„Pflichtmodule Politikwissenschaft“, „Wahlpflichtbereich: Englisch“, „Basismodule“). **Gemeinsame Kataloge**
(Sport für 7, Geschichte und Englisch für je 4 Einträge): je Studiengang bleiben nur Module, deren
„Verwendbarkeit“ ihn nennt (FüBa, TE, Master LG, LBS, LBS-Sprint, Bachelor/Master Sonderpädagogik;
Zertifikatsprogramme zählen nicht); Art je Studiengang aus „Pflichtmodul (FüBa) und Wahlpflichtmodul (Master LSo)“;
Titelzusätze wie „(FüBa Erstfach, Zert. LG)“ fallen weg. Keiner dieser Kataloge nennt eine Sprache.

**`maphy-katalog`.** Modulgrenze „Semesterlage“; Titel = Zeilen darüber (englischer Titel in Klammern weg);
Bereich und Art aus den Abschnitten („4.1 Pflichtmodule Bachelor“, „3.6 Wahlpflichtbereich Meteorologie“).
LP aus der Zeile unter „Leistungspunkte (ECTS)“, Aufwand „Insgesamt: 300h“, Leistungsnachweise getrennt in
Prüfungs-/Studienleistung. Der Anhang („Regelmäßigkeit:“, „Sprache:“) sind Lehrveranstaltungen, keine Module; ihre
Sprache geht auf ein Modul über, wenn alle genannten Lehrveranstaltungen dieselbe haben (selten). Empfohlenes
Semester nur in der Umweltmeteorologie („Wintersemester, 1. Semester“), sonst steht es in der PO. Fach- und
Lehramtskataloge gelten für mehrere Einträge: Bachelor/Master über „Modulverwendbarkeit“ bzw. Abschnitt,
Lehramt wie bei der Phil-Tabelle.

**Scans (OCR).** Kein Tesseract installiert → Apple Vision (`VNRecognizeTextRequest`, `de-DE` vor `en-US`,
`.accurate`) über ein kleines Swift-Skript (`xcrun swift`, `DEVELOPER_DIR=/Applications/Xcode.app/…`, Quelle in
`ocr_pages.SWIFT_SOURCE`, abgelegt als `~/Studora-Builds/luh-ocr/ocr.swift`). Seiten mit PDFKit bei 216 dpi
gerendert; **vor der Erkennung werden lange Tabellenlinien weiß gemalt** – sonst verliert Vision den ersten
Buchstaben neben einer Rahmenlinie („tudiengang“, „oziologische Theor“). Ergebnis je Seite als JSON (Text,
Sicherheit, Rahmen) in `~/Studora-Builds/luh-ocr/<pdf>/p0001.json`, nie zweimal erkannt. 17 PDFs, 1 090 Seiten,
49 407 Zeilen in gut 2 Minuten (4 Prozesse); mittlere Sicherheit 0,994, unter 0,5: 0,2 % der Zeilen. Danach:
Zeilen aus den Rahmen, Logo rechts oben weg, kleine Lesefehler in Feldnamen berichtigt („Prutungsleistungen“,
„lodultit“), „&t“ → „&“, „Il“ → „II“, Fußnotenziffern am Feldnamen weg („Modultitel9“). Vorlage je PDF:
Phil-Tabelle (Englisch) → `phil_kv_tabelle` mit Spaltenlage aus den Rahmen; LUH-Vorlage (alle übrigen) →
`luh_modulbeschreibung` (Formate A) mit gepaarten Kopfzeilen („Leistungspunkte: 5 LP“, „Sprache: Deutsch“ aus
Feldnamenzeile + Wertzeile); Soziologie M.A. enthält beide Vorlagen (Philosophie-/Politik-Importmodule) → beide
Leser, zusammengeführt. Biochemie B.Sc. (Wahlpflicht mit Textebene) und Life Science B.Sc. (zwei Scans) als ein
Katalog je Eintrag.

Ergebnis (60 Einträge, alle gültig; Werte in % der Module, Turnus nur WS/SS/WS+SS):

| Format | Einträge (gültig) | Module | LP | Prüfung | Studienl. | Turnus | Sem. | Sprache | Aufwand | Bereich | Vorauss. |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `phil-kv-tabelle` | 20 (20) | 267 | 100 % | 100 % | 89 % | 97 % | 93 % | 0 % | 99 % | 94 % | 6 % |
| `maphy-katalog` | 17 (17) | 225 | 100 % | 84 % | 85 % | 85 % | 19 % | 2 % | 100 % | 100 % | 31 % |
| `scanned` | 23 (23) | 604 | 96 % | 67 % | 83 % | 92 % | 82 % | 90 % | 96 % | 60 % | 17 % |
| **zusammen** | 60 (60) | 1096 | 98 % | 78 % | 85 % | 92 % | 72 % | 50 % | 97 % | 77 % | 17 % |

| Eintrag (Registerschlüssel ohne `luh\|`) | Format | gelesen als | Module | Katalogsemester |
|---|---|---|---:|---|
| biochemie \| b.sc. \| 2024 | `scanned` | OCR, LUH-Vorlage; Textebene, LUH-Vorlage | 66 | WS 2025/26 |
| chemie-1 \| m.sc. \| 2024 | `scanned` | OCR, LUH-Vorlage | 102 | WS 2024/25 |
| chemie-im-bachelorstudiengang-technical-education \| b.sc. \| 2016 | `scanned` | OCR, LUH-Vorlage | 18 | SS 2026 |
| chemie-im-faecheruebergreifenden-bachelor \| b.sc. \| 2016 | `scanned` | OCR, LUH-Vorlage | 21 | SS 2026 |
| chemie-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint \| m.ed. \| 2026 | `scanned` | OCR, LUH-Vorlage | 18 | SS 2026 |
| chemie-im-masterstudiengang-lehramt-an-berufsbildenden-schulen \| m.ed. \| 2016 | `scanned` | OCR, LUH-Vorlage | 18 | SS 2026 |
| chemie-im-masterstudiengang-lehramt-an-gymnasien \| m.ed. \| 2016 | `scanned` | OCR, LUH-Vorlage | 8 | SS 2026 |
| chemie \| b.sc. \| 2024 | `scanned` | OCR, LUH-Vorlage | 39 | WS 2024/25 |
| englisch-im-bachelorstudiengang-technical-education \| b.sc. \| 2016 | `scanned` | OCR, Phil-Tabelle | 8 | WS 2025/26 |
| englisch-im-faecheruebergreifenden-bachelor \| b.a. \| 2016 | `scanned` | OCR, Phil-Tabelle | 16 | WS 2025/26 |
| englisch-im-masterstudiengang-lehramt-an-berufsbildenden-schulen \| m.ed. \| 2016 | `scanned` | OCR, Phil-Tabelle | 5 | WS 2025/26 |
| englisch-im-masterstudiengang-lehramt-an-gymnasien \| m.ed. \| 2016 | `scanned` | OCR, Phil-Tabelle | 8 | WS 2025/26 |
| geschichte-im-bachelorstudiengang-sonderpaedagogik \| b.a. \| 2016 | `phil-kv-tabelle` | Textebene | 3 | WS 2026/27 |
| geschichte-im-faecheruebergreifenden-bachelor \| b.a. \| 2016 | `phil-kv-tabelle` | Textebene | 12 | WS 2026/27 |
| geschichte-im-masterstudiengang-lehramt-an-gymnasien \| m.ed. \| 2016 | `phil-kv-tabelle` | Textebene | 8 | WS 2026/27 |
| geschichte-im-masterstudiengang-lehramt-fuer-sonderpaedagogik \| m.ed. \| 2016 | `phil-kv-tabelle` | Textebene | 9 | WS 2026/27 |
| hochschule-wissenschaft-gesellschaft \| m.a. \| 2016 | `scanned` | OCR, LUH-Vorlage | 11 | SS 2025 |
| life-science-1-1 \| m.sc. \| 2022 | `scanned` | OCR, LUH-Vorlage | 30 | SS 2023 |
| life-science-1-1 \| m.sc. \| 2024 | `scanned` | OCR, LUH-Vorlage | 64 | SS 2025 |
| life-science \| b.sc. \| 2016 | `scanned` | OCR, LUH-Vorlage | 56 | WS 2024/25 |
| mathematik-1 \| m.sc. \| 2020 | `maphy-katalog` | Textebene | 14 | WS 2026/27 |
| mathematik-im-bachelorstudiengang-sonderpaedagogik \| b.a. \| 2016 | `maphy-katalog` | Textebene | 4 | WS 2026/27 |
| mathematik-im-bachelorstudiengang-technical-education \| b.sc. \| 2016 | `maphy-katalog` | Textebene | 7 | WS 2026/27 |
| mathematik-im-faecheruebergreifenden-bachelor \| b.sc. \| 2016 | `maphy-katalog` | Textebene | 14 | WS 2026/27 |
| mathematik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint \| m.ed. \| 2026 | `maphy-katalog` | Textebene | 3 | WS 2026/27 |
| mathematik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen \| m.ed. \| 2016 | `maphy-katalog` | Textebene | 4 | WS 2026/27 |
| mathematik-im-masterstudiengang-lehramt-an-gymnasien \| m.ed. \| 2016 | `maphy-katalog` | Textebene | 11 | WS 2026/27 |
| mathematik-im-masterstudiengang-lehramt-fuer-sonderpaedagogik \| m.ed. \| 2016 | `maphy-katalog` | Textebene | 4 | WS 2026/27 |
| mathematik \| b.sc. \| 2020 | `maphy-katalog` | Textebene | 35 | WS 2026/27 |
| physik-1 \| m.sc. \| 2020 | `maphy-katalog` | Textebene | 12 | WS 2026/27 |
| physik-im-bachelorstudiengang-technical-education \| b.sc. \| 2016 | `maphy-katalog` | Textebene | 7 | WS 2026/27 |
| physik-im-faecheruebergreifenden-bachelor \| b.sc. \| 2016 | `maphy-katalog` | Textebene | 16 | WS 2026/27 |
| physik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint \| m.ed. \| 2026 | `maphy-katalog` | Textebene | 7 | WS 2026/27 |
| physik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen \| m.ed. \| 2016 | `maphy-katalog` | Textebene | 9 | WS 2026/27 |
| physik-im-masterstudiengang-lehramt-an-gymnasien \| m.ed. \| 2016 | `maphy-katalog` | Textebene | 15 | WS 2026/27 |
| physik \| b.sc. \| 2020 | `maphy-katalog` | Textebene | 16 | WS 2026/27 |
| politik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint \| m.ed. \| 2026 | `phil-kv-tabelle` | Textebene | 12 | WS 2026/27 |
| politikwissenschaft-1 \| m.a. \| 2016 | `phil-kv-tabelle` | Textebene | 19 | WS 2026/27 |
| politikwissenschaft-politik-im-bachelorstudiengang-technical-education \| b.sc. \| 2016 | `phil-kv-tabelle` | Textebene | 12 | WS 2026/27 |
| politikwissenschaft-politik-im-faecheruebergreifenden-bachelor \| b.a. \| 2016 | `phil-kv-tabelle` | Textebene | 12 | WS 2026/27 |
| politikwissenschaft-politik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen \| m.ed. \| 2016 | `phil-kv-tabelle` | Textebene | 8 | WS 2026/27 |
| politikwissenschaft-politik-wirtschaft-im-masterstudiengang-lehramt-an-gymnasien \| m.ed. \| 2016 | `phil-kv-tabelle` | Textebene | 8 | WS 2026/27 |
| politikwissenschaft \| b.a. \| 2016 | `phil-kv-tabelle` | Textebene | 59 | WS 2026/27 |
| religion-in-the-public-sphere-1 \| m.a. \| 2021 | `scanned` | OCR, LUH-Vorlage | 10 | SS 2026 |
| religion-in-the-public-sphere-double-degree-track \| m.a.-double-degree \| 2021 | `scanned` | OCR, LUH-Vorlage | 10 | SS 2026 |
| religionswissenschaft-werte-und-normen-im-faecheruebergreifenden-bachelor \| b.a. \| 2016 | `scanned` | OCR, LUH-Vorlage | 21 | WS 2026/27 |
| sonderpaedagogik-und-rehabilitationswissenschaften \| m.a. \| 2019 | `phil-kv-tabelle` | Textebene | 17 | WS 2026/27 |
| sonderpaedagogik \| b.a. \| 2016 | `phil-kv-tabelle` | Textebene | 14 | WS 2026/27 |
| soziologie \| m.a. \| 2016 | `scanned` | OCR, LUH-Vorlage + Phil-Tabelle | 20 | SS 2025 |
| sport-im-bachelorstudiengang-sonderpaedagogik \| b.a. \| 2016 | `phil-kv-tabelle` | Textebene | 8 | WS 2026/27 |
| sport-im-bachelorstudiengang-technical-education \| b.sc. \| 2016 | `phil-kv-tabelle` | Textebene | 10 | WS 2026/27 |
| sport-im-faecheruebergreifenden-bachelor \| b.a. \| 2016 | `phil-kv-tabelle` | Textebene | 17 | WS 2026/27 |
| sport-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint \| m.ed. \| 2026 | `phil-kv-tabelle` | Textebene | 10 | WS 2026/27 |
| sport-im-masterstudiengang-lehramt-an-berufsbildenden-schulen \| m.ed. \| 2016 | `phil-kv-tabelle` | Textebene | 8 | WS 2026/27 |
| sport-im-masterstudiengang-lehramt-an-gymnasien \| m.ed. \| 2016 | `phil-kv-tabelle` | Textebene | 13 | WS 2026/27 |
| sport-im-masterstudiengang-lehramt-fuer-sonderpaedagogik \| m.ed. \| 2016 | `phil-kv-tabelle` | Textebene | 8 | WS 2026/27 |
| umweltmeteorologie \| b.sc. \| 2022 | `maphy-katalog` | Textebene | 47 | SS 2026 |
| wirtschaftsgeographie-innovation-und-nachhaltigkeit-double-degree-track \| m.sc.-double-degree \| 2025 | `scanned` | OCR, LUH-Vorlage | 21 | SS 2026 |
| wirtschaftsgeographie-innovation-und-nachhaltigkeit \| m.sc. \| 2025 | `scanned` | OCR, LUH-Vorlage | 21 | SS 2026 |
| wirtschaftsgeographie-ma \| m.a. \| 2022 | `scanned` | OCR, LUH-Vorlage | 13 | SS 2025 |

Bekannte Grenzen: In den Scans der LUH-Vorlage fehlt oft die Prüfungsleistung, weil viele Chemie-/Life-Science-Module
nur Studienleistungen haben oder Prüfungs- und Studienleistung in einer Zelle stehen; Bereich nur, wo Überschriften
„Pflicht-/Wahlpflichtmodule“ vorkommen (60 %). Einzelne OCR-Titel bleiben unsauber („Tissue Engineering 1 |“,
„Modultitel3o …“). Die Chemie-Kataloge für TE/LBS/LBS-Sprint (eine PDF) werden nicht je Studiengang gefiltert (der
LUH-Leser kennt keinen Studiengangsfilter). Phil-Tabelle: Studienleistung oft als längerer Satz (auf 300 Zeichen
gekürzt), Voraussetzungen selten als Modultitel genannt.
