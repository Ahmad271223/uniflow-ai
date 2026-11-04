# Gemeinsame Wochentests

Stand 04.11.2026 (Varianten-Regel; Schlüssel seit 25.10.2026). Vorgabe des Inhabers: Wer dieselbe Vorlesung und
dieselbe Übung hat, teilt sich den Wochentest. **Für ein Modul und eine Woche gibt es höchstens drei Tests, egal wie
viele Studierende das Modul haben**: bei 100 Studierenden werden drei Tests erzeugt und etwa 34/33/33 bekommen je einen
davon, bei 200 Studierenden 66/66/68. Tests werden also **übernommen, nicht je Person erzeugt**. Die KI ist für Fragen,
Karteikarten und die PDF-Analyse da, nicht für einen Test je Studierendem.

## Regel

### Schlüssel

Ein Wochentest wird durch einen **gemeinsamen Schlüssel** beschrieben (`app/testshare.py`, `TestShare.swift`; Version
`wt2` seit 29.10.2026: 15 Aufgaben 4/6/5, Altklausur im Schlüssel):

| Teil des Schlüssels | Warum |
| --- | --- |
| Hochschule | Unis werden nie gemischt |
| Testdauer, gerundet auf 15/30/45/60/90/120 Minuten | 40 und 45 Minuten teilen denselben Test |
| SHA-256 des Inhalts jeder verwendeten Datei (sortiert, ohne Doppelte) | gleiche Folie und gleiches Übungsblatt ergeben denselben Abdruck, egal ob über Stud.IP, Learnweb mit oder ohne Schlüssel |

**Nicht** im Schlüssel: Nutzer, Gerät, Modulname, Lehrwochen-Nummer. Diese sind pro Nutzer verschieden einstellbar.
Wer eine **andere Übungsgruppe mit anderem Blatt** hat, bekommt dadurch automatisch einen eigenen Test. Fehlt bei einer
Datei der Inhalt, wird nicht geteilt (lieber ein eigener Test als ein falscher).

Ändert sich der Aufbau eines Tests (Prompt, Format), wird `VERSION` erhöht. Dann entstehen neue Tests, alte werden nicht
mit neuen vermischt.

### Varianten (höchstens drei je Schlüssel)

Reine Funktionen, in Python und Swift gleich (Erwartungswerte in `packages/shared-contracts/fixtures/testshare/cases.json`,
Abschnitte `variants` und `pick_cases`):

- `MAX_VARIANTS = 3` (`TestShare.maxVariants`).
- `variant(user_id, key)` = SHA-256 über `"<user_id>|<key>"`, die ersten 4 Byte als Zahl (big-endian), **modulo 3**.
  Deterministisch und gleichmäßig verteilt (10.000 Nutzer: jede Variante 30–36 %). Nutzerkennung: im Dienst das Konto,
  auf dem iPad die CloudKit-Nutzerkennung, am Einzelplatz eine einmal erzeugte Installationskennung
  (`settings.share_user_id`); sie verlässt das Gerät nie, der Dienst sieht nur die Variante.
- `pick(ready, assigned, pending)` entscheidet:
  1. Eigene Variante fertig → **übernehmen** (keine KI).
  2. Eigene Variante in Arbeit (ein anderer erzeugt sie gerade) → kurz **warten** (Dienst 90 s, iPad 120 s, Abfrage
     alle 5 s), dann übernehmen.
  3. Weniger als drei Plätze belegt (fertig oder in Arbeit) → Platz **belegen**, mit KI erzeugen, als Variante
     veröffentlichen; die eigene Variante, bei einem Wettlauf die nächste freie.
  4. Drei Plätze belegt → **nie erzeugen**: die nächste fertige Variante übernehmen; sind alle drei nur belegt und keine
     fertig (verwaist), ein eigener Test ohne Veröffentlichung.
- Scheitert das Erzeugen, wird der belegte Platz wieder frei. Eine Belegung ohne Inhalt gilt nach 10 Minuten als
  verwaist (`PENDING_STALE_S`); im Dienst wird sie gelöscht, bei CloudKit kann nur der Ersteller sie löschen, darum
  zählt sie als belegt und wird nicht abgewartet.
- Die Lehrwochen-Nummer im Titel bleibt die eigene (wie bisher).

### Spalten und JSON

`tests.share_key` (wie bisher), neu `tests.share_variant` (0..2) und `tests.adopted_from` (`local` = anderer eigener
Test mit demselben Schlüssel, `service` = Pool des Dienstes, `cloudkit` = iPad ohne Server, NULL = selbst erzeugt).
Migration in `app/db.py` und `Store/Migrations.swift` direkt hinter `share_key`, Fixtures `schema/schema.json`,
`schema/legacy.json`, `local-backend/weekly.json`.

`GET /api/tests` und `GET /api/tests/{id}` (PC und iPad) liefern zusätzlich:

```json
"shared": {"variant": 2, "of": 3, "adopted": true}
```

`variant` ist **1-basiert** für die Anzeige („Gemeinsamer Test · Variante 2 von 3“), `of` = 3, `adopted` = übernommen
statt selbst erzeugt; `null` bei einem nicht geteilten Test (`shared_info`, `TestShare.sharedInfo`). Während „Wochentests
erstellen“ läuft, meldet das iPad unter `GET /api/bg` zusätzlich `phase`: `shared_lookup` (Suche gemeinsamen Test …),
`shared_wait` (ein anderer erzeugt gerade), `generate` (eigene KI), `shared_adopted`; nach dem Auftrag fehlt das Feld
wie am PC.

## Stand der Umsetzung

- **PC-App / Einzelplatz:** Schlüssel und eigene Variante werden gespeichert; ein zweites Modul mit denselben Dateien
  nimmt den eigenen Test (`adopted_from = local`). Ohne Dienst wird nichts geteilt. Tests: `tests/test_testshare.py`.
- **iPad V1 ohne Server (CloudKit, fertig):** `apps/apple/UniFlow/Services/WeeklyTestCloudKit.swift` setzt
  `WeeklyTestShareProvider` (Kern, `LocalBackend/Weekly/WeeklyTestShare.swift`) mit der öffentlichen CloudKit-Datenbank um;
  der Wochentest-Endpunkt (`WeekTests.create`) ruft `WeeklyTestShare.obtain` auf, bevor die KI des Nutzers erzeugt.
  Geteilt wird nur mit iCloud-Konto; ohne Konto, ohne Container oder ohne Netz entsteht wie bisher ein eigener Test.
  Datensatz `WeeklyTest` (docs/CLOUDKIT-SCHEMA-PRODUCTION-2026-11-03.md): Name `<Schlüssel>#<Variante>` (atomar,
  eindeutig), `shareKey`, `variant`, `status` (`pending` | `ready`), `payload`, `createdAt`, `ownerRecordName`. Keine
  Namen, keine Antworten. **Inhalt verschlüsselt** (`WeeklyTestCrypto`): Schlüssel per HKDF-SHA256 aus den sortierten
  Inhalts-Hashes der Dateien (Salz je Datensatz), AES-256-GCM, Zusatzdaten binden das Chiffrat an Schlüssel und
  Variante. Die Hashes liegen nie bei CloudKit: lesen kann nur, wer dieselben Dateien hat. Tests:
  `TestShareVariantsTests` (Kern), `WeeklyTestCloudKitTests` (App, Nachbau von CloudKit).
- **V2-Dienst (Python, fertig):** Pool `shared_tests` in `library.db` (`app/test_library.py`, `shared_*`): je Schlüssel
  höchstens drei Plätze, Besitzer nur als Kurzwert. `planner.create_test` läuft im Dienst für Windows und Web über
  `testshare.obtain`. Für Geräte, die selbst erzeugen (iPad mit Dienst): `GET /api/v2/shared-tests/{key}` (eigene
  Variante, `action` = `adopt` mit Test | `wait` | `generate`), `POST …/{key}/claim`, `POST …/{key}/{variant}`
  (nur in der Form 15 Aufgaben 4/6/5, bereinigt), `DELETE …/{key}/{variant}`. Der Dienst gibt keine Liste von
  Schlüsseln heraus; wer fragt, kennt die Dateien schon.
- **Vorlesungs-Seitenmarker (`app/weekly.py`, `wt_defs`)** haben ihren eigenen Weg (Stoff bis zum Marker, ein Test je
  Stoffumfang) und sind von der Varianten-Regel nicht berührt.

## Ablauf im V2-Dienst

1. Das Gerät berechnet den Schlüssel aus seinen Dateien und fragt `GET /api/v2/shared-tests/{key}`.
2. `adopt`: der Test liegt bei. Keine KI-Kosten. `wait`: ein anderes Konto erzeugt genau diese Variante; später erneut
   fragen. `generate`: Platz mit `POST …/claim` belegen (atomar, höchstens drei je Schlüssel), mit der eigenen KI
   erzeugen, `POST …/{key}/{variant}` veröffentlichen; scheitert das Erzeugen, `DELETE` gibt den Platz frei.
3. Antworten, Punkte und Rückmeldungen bleiben **pro Nutzer** und werden nie geteilt.
4. Einen Test bekommt nur, wer den Schlüssel berechnen kann, also die Dateien des Kurses selbst besitzt.
5. Meldet ein Nutzer einen Fehler im Test, wird die Variante für alle mit diesem Schlüssel neu erzeugt oder korrigiert
   (offen, siehe unten).

Dasselbe Prinzip gilt für die **Dateianalyse**: einmal je Inhalts-Hash statt einmal je Nutzer.

## Kostenwirkung (10.000 Nutzer, Annahmen)

Annahmen: 70 % Free, 20 % Plus, 10 % Pro; jeder nutzt sein Kontingent voll (59.000 Tests im Monat); je Kurs und Übungsblatt
teilen sich im Schnitt **30 Nutzer** einen Schlüssel (5 Module je Nutzer, 4 Wochen). Mit drei Varianten je Schlüssel
entstehen höchstens dreimal so viele Tests wie mit einer, bei kleinen Kursen (unter drei Nutzern je Schlüssel) genauso
viele wie ohne Teilen.

| Posten | ohne Teilen | eine Variante | drei Varianten |
| --- | --- | --- | --- |
| Tests erzeugen (Sonnet 5.5, 0,07 $ je Test) | ca. 4.130 $ | ca. 470 $ (rund 6.700 Tests) | ca. 1.400 $ (rund 20.000 Tests) |
| Dateianalyse (Haiku 5.5, Batch) | ca. 400 $ | ca. 10 $ (je Datei einmal) | ca. 10 $ |
| Antworten bewerten, pro Nutzer (Sonnet 5.5, ca. 0,038 $) | ca. 2.240 $ | ca. 2.240 $ | ca. 2.240 $ |
| Antworten bewerten mit Haiku 5.5 (ca. 0,002 $) | ca. 120 $ | ca. 120 $ | ca. 120 $ |
| **Summe mit Sonnet-Bewertung** | **ca. 6.770 $** | ca. 2.720 $ | **ca. 3.650 $** |
| **Summe mit Haiku-Bewertung** | ca. 4.650 $ | ca. 600 $ | **ca. 1.530 $** |

Nach dem Teilen ist die **Bewertung der Antworten** der größte Posten. Hebel: Multiple-Choice- und Zahlenaufgaben ohne
KI auf dem Gerät bewerten, nur Freitext mit KI, und dafür Haiku 5.5 testen.

## Offene Entscheidungen des Inhabers

- Zählt ein übernommener (also kostenloser) Test gegen das Monatskontingent (1/6/40)? Technisch nötig ist es nicht; die
  V2-Endpunkte verlangen bisher nur die Anmeldung, kein Kontingent.
- Fehler in einer Variante melden: Variante für alle neu erzeugen (nur der Ersteller kann seinen CloudKit-Datensatz
  ändern; im Dienst ein Admin) – noch nicht umgesetzt.
- Verwaiste CloudKit-Belegungen (Gerät mitten im Erzeugen weg) blockieren einen Platz, bis der Ersteller sie löscht
  oder der Inhaber sie im Dashboard entfernt.
