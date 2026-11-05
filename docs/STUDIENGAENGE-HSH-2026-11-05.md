# Studiengänge und Modulkataloge der Hochschule Hannover (Auftrag des Inhabers 05.11.2026)

Ziel: „die gleiche Bibliothek“ wie für die LUH – alle HsH-Studiengänge (auch dual, Master, auslaufende POs) mit
Modulhandbuch, Semesterlage, Wahlbereichen und Anmeldezeiträumen, als Grundstock der App (lokal → Grundstock →
Bibliothek → Download, wie bei der LUH). Verbindlich bleibt immer die Prüfungsordnung der Hochschule.

## Quellen und Höflichkeit

- **Nur öffentliche Seiten der HsH-Webseite**: `www.hs-hannover.de` und `f1`…`f5.hs-hannover.de` (Sitemaps,
  Studiengangsseiten, Ordnungs-, Prüfungs- und Terminseiten der Fakultäten, PDFs in `/fileadmin/`).
- **robots.txt beachtet** (RFC 9309, längste Regel gewinnt): die HsH erlaubt in `/fileadmin/` ausschließlich PDFs
  und sperrt Archivordner (`/Archiv/`, `/Alte_Versionen/`) und `cHash`-Adressen (daher keine Seiten 2–4 des
  Studienangebots A–Z; die Sitemaps sind ausdrücklich erlaubt). 7 Handbücher und 32 Termin-PDFs liegen in
  Archivordnern und wurden nicht geholt.
- **HISinOne (campusmanagement.hs-hannover.de) wurde nie angefragt**: seine robots.txt lautet
  `User-agent: * / Disallow: /` (gelesen 05.11.2026, eine Anfrage). Die öffentlichen Seiten „Modulbeschreibungen
  anzeigen“, „In Modulhandbüchern suchen“, „Studiengangspläne anzeigen“ und das Vorlesungsverzeichnis sind damit für
  Crawler gesperrt, auch ohne Anmeldung. Möglicher Weg später (nicht gebaut): das Gerät liest beim angemeldeten
  Nutzer seine eigenen Modulbeschreibungen/Studiengangspläne wie ein Browser (HsH-Adapter), nicht als Sammlung.
- Höchstens eine Anfrage je 2,5 s, nacheinander, User-Agent `StudiNow-Katalogpruefung/1.0 (support@studinow.app)`;
  alles im Zwischenspeicher `~/Studora-Builds/hsh-catalog/` (Seiten, PDFs, `text/<sha256>.json`), was der
  Register-Lauf schon hatte, aus `~/Studora-Builds/hsh/crawl/` (0 Anfragen). Ein zweiter Lauf arbeitet nur aus dem
  Zwischenspeicher (0 Anfragen).
- **Anfragen**: 566 (Katalog-Lauf: 564 × 200, 2 × 404) + 103 (Register-Lauf) + 1 (robots.txt HISinOne) = **670**
  von höchstens 1500.

## Register (`tools/hsh-programs.py` → `packages/shared-contracts/study-sources-hsh.json`)

Studiengänge aus dem Studienangebot A–Z (Seite 1) und den Sitemaps aller fünf Fakultäten, je Studiengangsseite und
Unterseite die PDFs; Handbücher von Ordnungsseiten der Fakultäten über das Kürzel im Dateinamen (auch `BSKE` für
SKE) oder den Studiengangsnamen. Doppelte Einträge (A–Z ohne Kürzel + Sitemap mit Kürzel; Mediendesigninformatik bei
Fakultät III und IV) sind zusammengeführt.

- **75 Studiengänge** (F I 9, F II 25, F III 19, F IV 10, F V 12; 20 B.A., 21 B.Eng., 9 B.Sc., 7 M.A., 11 M.Eng.,
  5 M.Sc., 1 MBA, 1 Master; 10 dual, mehrere berufsbegleitend).
- **121 Registereinträge**: einer je Studiengang, PO-Version und Vertiefung (z. B. EIT mit ADT/EAE/SKI/SEL,
  Maschinenbau AM/PS, VEU ET/VU, WMM BO/PE). PO-Version aus Dateiname, Linktext oder erster Seite (`PO Version 19 WS`
  → 2019, `MAB-AM-WS2016` → 2016, `ab_WiSe_22_23` → 2022). Die neueste PO eines Studiengangs ist `aktuell`, ältere
  `auslaufend` (40 Einträge). Weitere Felder: Abschluss, Fakultät, Regelstudienzeit, Studienbeginn, Studienform,
  Vertiefungen, PO-Dokumente, Studienverlaufspläne, ältere Handbuchfassungen (nur Link), QIS-Namen.
- Lesbares Modulhandbuch: **108 Einträge / 62 Studiengänge**. Ohne: 8 Studiengänge ohne Handbuch auf ihren Seiten
  (MAT, BBI, Dual Studieren E-Technik, EEE, Green Engineering Master, TPE, MMU, MTA) und 5 mit Handbuch in nicht
  gelesener Bauart (MSW PO 2027, BAH, InPro, MPD, BFO: Bauart ohne erkennbare Modulanfänge bzw. Kürzel über zwei
  Zeilen) – dort zeigt die App den Link zum Handbuch.

## Leseprogramm (`app/catalog_formats/hsh.py`)

Feldleser „Feldname links, Wert rechts“ (Word-Tabellen und Datenbank-Satz) mit Modulanfang je Bauart; die Bauart
wählt der Leser selbst (die mit den meisten gelesenen Modulen mit LP):

| Bauart | Modulanfang | wo |
|---|---|---|
| `hsh-modul-code` | „Modul BIN-100 Mathematik 1“ / „Teilmodul …“, Abschnitte aus dem Inhaltsverzeichnis | F IV Informatik/WI, F I, F II BV (2010) |
| `hsh-modul-nummer` | „Modul 15 – Modulbeschreibung: …“, Modultabelle „Kürzel Titel PF/WP … CP“ | F V (BRS, BSW) |
| `hsh-modultitel` | Feld „Modultitel“/„Modulbezeichnung“, Lehrveranstaltungen als Teile | F II Maschinenbau (Curricula-Datenbank), F III IK, F V Pflege |
| `hsh-code-kopf` | Kopfzeile „BIM-112 Titel“; Spaltentabellen (Semester/Häufigkeit/Dauer/Art/ECTS) | F III IK und DM, F IV BWL |
| `hsh-wpf-tabelle` | „Mod. Nr: 283“, Werte vor den Feldnamen | F II Bioverfahrenstechnik, duale Maschinenbau-Handbücher 2025 |

Gelesen werden Titel, Kürzel, LP, Fachsemester (auch aus „Zuordnung zu Curricula (Sem.) MAB (2/So/Wi)“ und aus
Studienverlaufszeilen im Handbuch), Turnus, Pflicht/Wahlpflicht, Prüfungs- und Studienleistung, Voraussetzungen
(als Modul-ids), Sprache, Arbeitsaufwand, Bereich; Inhalt, Lernziele und Literatur nur als lokale Texte.
Nachbearbeitung im Grundstock: Turnus aus Semesterlage (nur Pflichtmodule mit Fachsemester in Studiengängen, die nur
im Winter beginnen: ungerade = WS, gerade = SS), Wahlbereiche nie Pflicht, Handangaben aus
`packages/shared-contracts/study-area-rules-hsh.json` (bisher 4 Kataloge: LMV/BML/TNR 30 Credits Wahlpflicht im
5. Semester, Pflege 25 Cr in einem Schwerpunkt).

**Semesterlage**: aus dem Handbuch (Studiensemester/Semester/Curricula/Verlaufszeilen). Keine eigene Lesung der 27
Studienverlaufsplan-PDFs (Raster ohne verlässliche Textreihenfolge); sie stehen je Eintrag in `study_plans`.
Studiengangspläne aus HISinOne: gesperrt (siehe oben).

## Prüfungsanmeldung (`tools/hsh-exam-registration.py` → `exam-registration-hsh.json`)

Angemeldet wird im Campusmanagement („Prüfungen anmelden“); jede Abteilung legt ihren Zeitraum fest. Gefunden
(WiSe 2026/27): F IV Informatik 07.–14.09.2026 (Zeitraum A) und 30.11.–13.12.2026 (B); F IV
Wirtschaftsinformatik 02.–29.11.2026; F IV BWL 02.–22.11.2026; F II Maschinenbau 14.–28.10.2026; F III IK jährlich
15.–30.11. bzw. 15.–31.05. Abmelderegeln: F II eine Woche vor dem Termin; WI bis 29.11.2026. Ohne Zeitraum (nur
Link): F I (Prüfungsplan nur in einer eigenen Web-App), F II BV, F III DM, F V. 37 von 75 Studiengängen haben einen
Zeitraum. Eingebunden in `app/exam_registration.py`/Swift ist die Datei noch nicht (`DATA_PATHS` und
Abschluss-Kürzel `beng`/`meng` fehlen dort).

## In der App

- Grundstock `apps/apple/UniFlow/Resources/StudyCatalogSeed/hsh.json.gz` + `hsh-index.json` (Swift
  `StudyCatalogSeed.universities` und Python `SEED_UNIVERSITIES` kennen `hsh`; Windows-Paket enthält `hsh.json.gz`).
- Register: `study-sources-hsh.json` fließt über `merge_wide_registries` in `study-sources-all.json` und
  `StudySourcesData.swift` (Quelle `hsh-grundstock`: nur aus dem Grundstock, kein Download auf dem Gerät).
- Ablauf mit `settings.university = hsh`: QIS-/HISinOne-Name → Studiengang → Kürzel → Grundstock (Stand `seed`).

## Neu bauen

```
.venv/bin/python tools/hsh-catalogs.py crawl            # Seiten und PDFs (nur was fehlt), documents.json
.venv/bin/python tools/hsh-programs.py build            # Register aus dem Zwischenspeicher
.venv/bin/python tools/build-hsh-seed.py                # Grundstock (--check, --diff)
.venv/bin/python tools/hsh-exam-registration.py         # Anmeldezeiträume (--check)
.venv/bin/python tools/gen-study-catalog-fixture.py     # gemischtes Register (Python + Swift)
```

Tests: `tests/test_hsh_catalog.py` (Leser mit erfundenen Fixtures in
`packages/shared-contracts/fixtures/hsh-catalog/`, Crawler-Auswahl, robots, PO/Vertiefung/Gruppen, Grundstock
`--check`, Ablauf für eine HsH-Person), `HshStudyCatalogTests.swift` (Ressource, Register, Ablauf und Plan).

<!-- grundstock:start (tools/build-hsh-seed.py) -->
## Grundstock (Zahlen des letzten Laufs)

Erzeugt von `tools/build-hsh-seed.py` aus dem Register `study-sources-hsh.json` und den Handbüchern im
Zwischenspeicher. Ressource `apps/apple/UniFlow/Resources/StudyCatalogSeed/hsh.json.gz` + `hsh-index.json`.

| Fakultät | Registereinträge | lesbares Handbuch | im Grundstock | Module |
|---|---:|---:|---:|---:|
| Fakultät I – Elektro- und Informationstechnik | 14 | 11 | 11 | 473 |
| Fakultät II – Maschinenbau und Bioverfahrenstechnik | 49 | 45 | 45 | 1698 |
| Fakultät III – Medien, Information und Design | 23 | 22 | 22 | 613 |
| Fakultät IV – Wirtschaft und Informatik | 15 | 13 | 13 | 543 |
| Fakultät V – Diakonie, Gesundheit und Soziales | 20 | 17 | 17 | 290 |
| **zusammen** | **121** | **108** | **108** | **3617** |

Feldfüllung über alle Module: lp 96 %, semester 61 %, exam 93 %, coursework 2 %, turnus 46 %, language 71 %, workload_h 88 %, code 67 %, prerequisites 1 %.
Nach Bauart: `hsh-code-kopf` 19 Kataloge / 584 Module; `hsh-modul-code` 28 Kataloge / 1062 Module; `hsh-modul-nummer` 7 Kataloge / 127 Module; `hsh-modultitel` 45 Kataloge / 1442 Module; `hsh-wpf-tabelle` 9 Kataloge / 402 Module.
Datei `hsh.json.gz`: 96 KB gzip, 1185 KB JSON, 108 Kataloge.
Nachbearbeitung: Turnus bei 141 Pflichtmodulen aus Semesterlage abgeleitet, 0 Module in Wahlbereichen nicht Pflicht, Handangaben in 4 Katalogen; verworfen: 0 mit weniger als 3 Modulen, 0 ungültig, 0 nicht lesbar, 0 doppelt.

Neu bauen: `.venv/bin/python tools/build-hsh-seed.py` (prüfen: `--check`, Vorschau: `--diff`).
<!-- grundstock:end -->
