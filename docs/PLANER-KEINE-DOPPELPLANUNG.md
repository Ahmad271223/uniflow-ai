# Lernplaner: zwei Geräte planen dieselbe Woche nicht mehr doppelt (15.11.2026)

Zweig `planer/keine-doppelplanung` (von 6ed2cc39, Kandidat für Build 43). Nichts gepusht, nichts ausgerollt.

## Der Fehler

Echtes iPhone, 14.11.2026 (Kopie der Geräte-Datenbank, nur Tabellen und Abgleich-Spalten angesehen): in der Woche
09.–15.11. liegen an denselben Tagen zu viele automatische Lernpakete, ein Teil hier erzeugt, ein Teil über den
Geräte-Abgleich gekommen (`sync_device = '~dienst'`). 6 Dateien stehen in zwei offenen Aufgaben, ein Paket hat gar
keine Aufgabe. Die 10 Pakete des iPhones sind mit 15 Nummern des Dienstes verknüpft – drei lokale Pakete mit zwei bis
drei Nummern (dieselbe Zeile wurde von beiden Geräten angelegt und hier als eine erkannt).

## Ursache

1. **Jedes Gerät plant selbst.** Die App plant nach dem eigenen Abgleich mit der Hochschule und beim Öffnen
   (`StudyAutoPlan.afterSync` → `StudyPlan.insertNewFiles`): beim ersten Lauf die laufende Woche, danach jedes neue
   Dokument einzeln. Welche Dokumente „neu“ sind, merkt sich jedes Gerät für sich (`study_plan_seen_files`). Am PC plant
   `study.auto_plan_week` nach jedem Abgleich mit neuen Dateien die Woche neu.
2. **Der Geräte-Abgleich läuft daneben.** Beim Öffnen starten das Einordnen und der Abgleich mit dem Konto
   gleichzeitig; die Planung des anderen Geräts ist beim Einordnen noch nicht da.
3. **Der Abgleich erkennt nur Tag + Fach + Titel als dasselbe Paket** (`natural_key` in `app/sync_client.py`,
   `DeviceSyncCore.naturalKey`). Legt das zweite Gerät dieselbe Datei auf einen anderen Tag (es plant ab „morgen“ und
   mit dem, was es gerade kennt), sind es zwei Pakete: Der Dienst vergibt für jede gesendete neue Zeile eine neue
   Nummer, und jedes Gerät fügt die Zeile des anderen neben seine eigene.
4. **Danach zählt jedes Limit nur noch halb.** Die Planung prüft Stunden und Fächer je Tag gegen die Pakete, die das
   Gerät gerade kennt; nach dem Abgleich liegen beide Planungen am selben Tag. `repairSlots` legt Blöcke, die
   übereinander liegen, nur in andere freie Fenster – die Menge bleibt.

Nachgestellt mit zwei simulierten Geräten: `StudyPlanMergeTests.testCauseBothDevicesPlanAndTheSyncPutsBothPlansSideBySide`
(Schein-Dienst), `DeviceSyncLiveTests.testTwoDevicesPlanningTheSameFileEndWithOnePackage` (echter Dienst,
`tools/g2-testdienst.py`), `tests/test_plan_merge.py::test_cause_two_devices_plan_the_same_file_on_different_days`
(Windows-App und iPad gegen den Dienst).

## Lösung

**Schlüssel ohne neue Spalte.** Eine automatische Aufgabe ist durch ihre Unterlage bestimmt: Datei (die ID kommt von
der Hochschule und ist auf jedem Gerät gleich) + Ausschnitt (Seiten, „Teil k/n“). Wochentest und Wiederholung: Fach +
Lehrwoche + Art. Es braucht keine neue Spalte und kein neues Feld im Abgleich; darum verstehen auch ältere Apps und der
jetzige Dienst alles, was die neue App sendet.

**Zusammenführen** (`app/plan_merge.py::merge_duplicates`, `StudyPlanMerge.mergeDuplicates`, auf jedem Gerät und im
Dienst dieselbe Regel). Stehen zwei Aufgaben für dieselbe Unterlage im Plan, bleibt genau eine:

1. eine angefasste immer – erledigt, begonnen, von Hand verschoben, mit abgehaktem Lernschritt, mit Lernzeit, mit
   Eintrag im Verlauf, in einem eigenen, gesperrten oder begonnenen Paket;
2. sonst die, die schon im Konto steht: das Gerät übernimmt die Planung des Kontos statt seiner eigenen, noch nicht
   gesendeten (die geht dann gar nicht erst ins Konto – keine zweite Zeile, keine Löschmarke);
3. sonst die früher geplante (`created_at` des Pakets, unveränderlich und abgeglichen);
4. sonst die mit der kleineren Nummer im Dienst.

Entfernt wird nur eine unberührte automatische Aufgabe, und nur, wenn eine andere dieselbe Unterlage abdeckt. Ein Paket
verschwindet erst, wenn es dadurch leer ist; sonst passen danach seine Minuten und sein Block wieder. Blöcke des
Stundenplaners bleiben als Lernzeit stehen. Ein automatisches Paket ganz ohne Aufgaben belegt keine Uhrzeit mehr.

Was als dieselbe Unterlage gilt: gleiche Seiten bzw. gleicher Teil; die ganze Datei gegen Abschnitte aus der Gliederung
(ältere App ohne Gliederung neben der neuen, dieselbe Lehrwoche); verschieden geteilt („Teil 1/2“ gegen „Teil 1/3“).
Nicht: verschiedene Seiten (auch der Skriptrest einer späteren Woche) und verschiedene Teile derselben Teilung. Freie
Aufgaben ohne Datei werden nie angefasst.

**Kein Hin und Her mit Löschmarken.** Die Reihenfolge 2–4 hängt nur an abgeglichenen, unveränderlichen Werten. Zwei
Geräte, die dieselben zwei Zeilen sehen, entfernen dieselbe; die zweite Löschung trifft im Dienst eine Zeile, die schon
weg ist. Ein zweiter Lauf ändert nichts mehr (in jedem Fall der Abgleichsdatei geprüft).

**Erst holen, dann planen.** Die App gleicht vor dem Einordnen neuer Dokumente einmal mit dem Konto ab
(`StudyAutoPlan.pullAccountFirst` → `StudoraAccountLink.pullBeforePlanning`, höchstens 20 Sekunden; ohne Konto und ohne
Netz wird wie bisher geplant). Die Windows-App ebenso vor `auto_plan_week` (`study.pull_account_first`).

**Tageslimit über alle Geräte** (`balance_days`, `StudyPlanMerge.balanceDays`, nur nach dem Abruf vom Konto). Liegen an
einem künftigen Tag Pakete aus dem Konto neben eigenen und ist der Tag damit über dem Limit (Lernzeit je Tag schon
aufgebraucht, mehr Fächer als eingestellt) oder liegen zwei Blöcke übereinander, weicht das zuletzt geplante unberührte
automatische Paket: in ein anderes freies Fenster bzw. auf den nächsten Lerntag mit Platz (Lernzeit, Stunden, Fächer).
Von Hand Angelegtes, Begonnenes, Gesperrtes und Blöcke des Stundenplaners bleiben liegen; heute und die Vergangenheit
bleiben, wie sie sind. Ein Tag, an dem alles aus dem Konto kam (neues oder neu installiertes Gerät), bleibt, wie ihn
das andere Gerät gelegt hat.

**Wo es läuft.** Im Geräte-Abgleich nach dem Abruf und vor dem Senden (`DeviceSync.run`, `sync_client.run`); dazu mit
jedem Lernkalender und jeder Planung (`StudyCalendar.calendar`, `study.calendar`, `generate_packages`) – damit auch im
Dienst, wenn jemand den Lernkalender im Browser öffnet.

## Vorhandene Doppel

Beim ersten Abgleich bzw. beim ersten Öffnen des Lernkalenders nach dem Update. Die iPhone-Kopie (Python und Swift,
gleiches Ergebnis; `STUDY_PLAN_MERGE_COPY=<Kopie> swift test --filter StudyPlanMergeTests/testRealCopyIfGiven`):

| Tag | Pakete vorher | nachher |
|---|---|---|
| 11.11. | 2 (eines übersprungen) | 2 (unverändert) |
| 12.11. | 3 | 2 + ein leeres ohne Uhrzeit |
| 13.11. | 3 | 2 |
| 14.11. | 2 | 1 |

6 doppelte Aufgaben und 2 Pakete entfernt, keine Datei steht mehr zweimal im Plan, 20 → 14 Aufgaben. Das übersprungene
Paket vom 11.11. und sein offenes Gegenstück bleiben beide (Übersprungenes gilt im Planer nicht als geplant). Für die
entfernten Zeilen gehen Löschmarken an den Dienst; das iPad übernimmt sie.

## Ältere Apps (Build 42 und früher, Windows-App alt)

- Sie planen weiter selbst und senden ihre Planung. Die neue App führt beim nächsten Abgleich zusammen; die ältere App
  übernimmt die Löschmarke (unberührte Zeile) – geprüft in beiden Reihenfolgen (`testOlderAppNextToTheNewOne…`).
- Hat die ältere App ihre Aufgabe inzwischen begonnen oder erledigt, bleibt die ihre; die neue App entfernt dann ihre
  eigene unberührte. Eine Löschmarke löscht auf keinem Gerät eine Zeile, die dort seit dem letzten Abgleich geändert
  wurde (bestehende Regel des Abgleichs: sie wird neu gesendet).
- Zwei ältere Apps ohne ein neues Gerät legen weiter Doppel an, bis eines der Geräte das Update hat oder der Dienst
  aktualisiert ist und jemand den Lernkalender im Browser öffnet.
- Nichts Neues im Vertrag des Abgleichs: keine Spalte, kein Feld, kein Status.

## Server-Update

Für die Geräte **nicht nötig**: die neue App räumt gegen den jetzigen Dienst auf. **Empfohlen** für die Web-Ansicht:
Mit dem neuen `app/plan_merge.py` + `app/study.py` führt der Dienst beim Öffnen des Lernkalenders im Browser selbst
zusammen. Das trifft vor allem Zeilen, die auf den Geräten schon als eine erscheinen (gleicher Tag, gleiches Fach,
gleicher Titel – der Abgleich verknüpft sie dort mit einer lokalen Zeile), im Dienst aber zweimal stehen. Keine
Migration, keine neue Tabelle, Reihenfolge von Dienst und App beliebig; Rückweg: alten Code ausrollen.

## Tests

- Gemeinsame Abgleichsdatei `plan-merge.json` (`tools/gen-plan-merge-fixture.py [--check]`, 18 Fälle):
  `tests/test_plan_merge.py`, `StudyPlanMergeTests.testEveryCaseMatchesPython`.
- Zwei und drei Geräte: `StudyPlanMergeTests` (Schein-Dienst), `DeviceSyncLiveTests` (echter Dienst),
  `tests/test_plan_merge.py` (Windows-App + iPad, Lernkalender im Dienst).
- Erst holen, dann planen: `LernplanEinordnenTests.testPlanOfTheAccountIsPulledBeforeNewDocumentsArePlaced`,
  `AuditPaket40x45AppTests.testPlanningPullsTheAccountFirst`, `test_windows_app_pulls_the_account_before_it_plans`.
- Unverändert grün: `LernblockFreieZeitTests`, `LocalStudyPlanTests`, `tests/test_lernpaket_zeiten.py`,
  `tests/test_study_plan.py`; `study-plan.json` und `smart-planner.json` sind unverändert.

## Offen

- Zeilen, die im Dienst doppelt stehen, auf den Geräten aber als eine erscheinen, räumt erst der Dienst auf (siehe
  Server-Update). Die Geräte könnten die überzähligen Nummern selbst löschen; das ist bewusst nicht gebaut, weil an
  der überzähligen Zeile im Dienst Aufgaben hängen können, die es hier nur einmal gibt.
- Auf dem belegten iPhone liegen einzelne Aufgaben in einem Paket eines anderen Fachs. Das Zusammenführen entfernt das
  Doppel, ordnet aber nichts um; welches der beiden bleibt, entscheidet die Reihenfolge oben, nicht das Fach.
- Verschieden geschnittene Abschnitte derselben Datei (zwei Geräte mit verschiedener Lernzeit je Fach zum Zeitpunkt
  der Planung) gelten nicht als dieselbe Unterlage.
- Blöcke des Stundenplaners selbst (`dedupe_blocks`) sind unverändert; nur ihre Unterlagen werden zusammengeführt.
- Das Tageslimit greift nur für künftige Tage und nur nach einem Abruf vom Konto; im Browser gibt es dafür keinen
  eigenen Lauf. Prüfung am echten iPad und iPhone steht aus.
