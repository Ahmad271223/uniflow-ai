"""Erzeugt packages/shared-contracts/fixtures/local-backend/plan-merge.json: doppelt geplante Lernpakete zweier Geraete
zusammenfuehren und das Tageslimit ueber alle Geraete (app/plan_merge.py, Swift: StudyPlanMerge). Fehler vom echten
iPhone vom 14.11.2026: jedes Geraet plante dieselbe Woche selbst, der Abgleich legte beide Planungen nebeneinander.

Je Fall eine frische Datenbank eines Geraets (init_db + Tabellen des Geraete-Abgleichs), `setup` + `seed` als SQL, dann
`plan_merge.after_pull(conn, hosted, today)`; gespeichert werden das Ergebnis, die Tabellen study_packages und
study_tasks danach, die Loeschmarken und das Ergebnis eines zweiten Aufrufs (aendert nichts mehr). Der Swift-Kern
(StudyPlanMergeTests) legt dieselben Zeilen an und vergleicht alles exakt. Alle Werte erfunden.

Aufruf im Projektordner: python tools/gen-plan-merge-fixture.py [--check]
"""
from __future__ import annotations

import json
import sys
from datetime import date

from schema_source import ROOT, SchemaSource, berlin_time, dump_tables, write_or_check

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "local-backend" / "plan-merge.json"
TODAY = "2026-11-16"                      # Montag
STAMP = "2026-11-16T08:00:00.000Z"
DIENST = "~dienst"

SETUP = [f"INSERT INTO settings(key, value) VALUES ('{k}', '{v}') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
         for k, v in (("learn_start", "08:00"), ("learn_end", "21:00"), ("hours_per_day", "4"), ("break_minutes", "15"),
                      ("subjects_per_day", "2"), ("free_days", "[6]"), ("travel_minutes", "0"), ("blocked_times", "[]"))]
SETUP += [f"INSERT INTO modules(id, name, semester, sort, active) VALUES ({i}, 'Fach {n}', 'WiSe 2026/27', {i}, 1)"
          for i, n in ((1, "A"), (2, "B"), (3, "C"))]


def q(v) -> str:
    if v is None:
        return "NULL"
    return str(v) if isinstance(v, int) else "'" + str(v).replace("'", "''") + "'"


def pkg(id_: int, day: str, module: int | None, created: str, minutes: int, *, start=None, end=None, status="geplant", generated=1,
        manual=0, locked=0, source=None, device=None, week: int | None = 5, title="Woche 5 · 16.11. – 22.11.") -> str:
    """Lernpaket; `device` = "~dienst": aus dem Konto uebernommen und hier nicht geaendert"""
    vals = [id_, day, module, f"Fach {'ABC'[module - 1]}" if module else "Eigenes", title, week, minutes, status, 0, generated,
            f"2026-11-{created}", start, end, source, locked, manual, 1, STAMP, device]
    return ("INSERT INTO study_packages(id, date, module_id, subject, title, week_no, planned_minutes, status, sort, generated, created_at, "
            "start_time, end_time, source, locked, manual, sync_version, sync_updated_at, sync_device) VALUES (" + ", ".join(q(v) for v in vals) + ")")


def task(id_: int, package: int, kind: str, file: str | None, title: str, est: int, *, sort=0, status="geplant", start=None, end=None,
         pages: tuple[int, int] | None = None, moved=None, done=None, actual=None, steps_done=None, device=None) -> str:
    vals = [id_, package, kind, file, title, sort, est, actual, status, done, moved, "2026-11-14T10:00:00", start, end,
            pages[0] if pages else None, pages[1] if pages else None, steps_done, 1, STAMP, device]
    return ("INSERT INTO study_tasks(id, package_id, type, file_id, title, sort, est_minutes, actual_minutes, status, done_at, moved_from, created_at, "
            "start_time, end_time, page_from, page_to, steps_done, sync_version, sync_updated_at, sync_device) VALUES (" + ", ".join(q(v) for v in vals) + ")")


def link(entity: str, remote: int, local: int) -> str:
    """Zeile steht im Konto: Nummer im Dienst -> Nummer hier"""
    return f"INSERT INTO sync_link_map(entity, remote_id, local_id, remote_version, local_version) VALUES ('{entity}', '{remote}', '{local}', 1, 1)"


def P(remote: int, local: int) -> str:
    return link("study_packages", remote, local)


def T(remote: int, local: int) -> str:
    return link("study_tasks", remote, local)


WED, THU, FRI = "2026-11-18", "2026-11-19", "2026-11-20"
A, B = "14T16:25:40", "15T15:30:30"        # zwei Planungen: frueher, spaeter

CASES: list[dict] = [
    {"name": "anderer_tag", "about": "Das Konto hat Blatt und Folien am Mittwoch, dieses Geraet hat dieselben Dateien selbst auf "
     "Donnerstag gelegt (noch nicht gesendet, sogar frueher geplant): die Planung des Kontos bleibt, die eigene verschwindet.",
     "seed": [pkg(1, WED, 1, B, 105, start="08:00", end="10:00", device=DIENST), P(101, 1),
              task(1, 1, "vorlesung", "datei-vl", "Folien 05.pdf", 45, start="08:00", end="08:45", device=DIENST), T(201, 1),
              task(2, 1, "uebung", "datei-ue", "Blatt 05.pdf", 60, sort=1, start="09:00", end="10:00", device=DIENST), T(202, 2),
              pkg(2, THU, 1, A, 105, start="08:00", end="10:00"),
              task(3, 2, "vorlesung", "datei-vl", "Folien 05.pdf", 45, start="08:00", end="08:45"),
              task(4, 2, "uebung", "datei-ue", "Blatt 05.pdf", 60, sort=1, start="09:00", end="10:00")]},
    {"name": "beide_im_konto", "about": "Beide Planungen stehen schon im Konto: die frueher geplante bleibt (auch wenn sie hier die "
     "groessere Nummer hat), fuer die andere gehen Loeschmarken an den Dienst.",
     "seed": [pkg(1, THU, 1, B, 60, start="08:00", end="09:00", device=DIENST), P(102, 1),
              task(1, 1, "uebung", "datei-ue", "Blatt 05.pdf", 60, start="08:00", end="09:00", device=DIENST), T(202, 1),
              pkg(2, WED, 1, A, 60, start="10:00", end="11:00"), P(101, 2),
              task(2, 2, "uebung", "datei-ue", "Blatt 05.pdf", 60, start="10:00", end="11:00"), T(201, 2)]},
    {"name": "gleiche_sekunde", "about": "In derselben Sekunde geplant, beide im Konto: die kleinere Nummer im Dienst bleibt, "
     "auf jedem Geraet dieselbe (hier hat sie die groessere lokale Nummer).",
     "seed": [pkg(1, WED, 1, A, 60, device=DIENST), P(108, 1), task(1, 1, "uebung", "datei-ue", "Blatt 05.pdf", 60, device=DIENST), T(208, 1),
              pkg(2, THU, 1, A, 60, device=DIENST), P(107, 2), task(2, 2, "uebung", "datei-ue", "Blatt 05.pdf", 60, device=DIENST), T(207, 2)]},
    {"name": "angefasst_bleibt", "about": "Erledigt, begonnen, verschoben, mit Lernschritt, mit Verlauf, gesperrt oder von Hand angelegt: "
     "bleibt immer. Das unberuehrte Doppel daneben verschwindet; sind beide angefasst, bleiben beide.",
     "seed": [
         # erledigt (spaeter geplant) gegen unberuehrt (frueher)
         pkg(1, WED, 1, A, 60, device=DIENST), P(101, 1), task(1, 1, "uebung", "f-erledigt", "Blatt 1.pdf", 60, device=DIENST), T(201, 1),
         pkg(2, "2026-11-13", 1, B, 60, status="erledigt"), P(102, 2),
         task(2, 2, "uebung", "f-erledigt", "Blatt 1.pdf", 60, status="erledigt", done="2026-11-13T18:00:00", actual=50), T(202, 2),
         # begonnen
         pkg(3, WED, 2, A, 45, device=DIENST), P(103, 3), task(3, 3, "vorlesung", "f-begonnen", "Folien 2.pdf", 45, device=DIENST), T(203, 3),
         pkg(4, THU, 2, B, 45, status="in_bearbeitung"), P(104, 4), task(4, 4, "vorlesung", "f-begonnen", "Folien 2.pdf", 45, status="in_bearbeitung"), T(204, 4),
         # von Hand auf einen anderen Tag gelegt
         pkg(5, WED, 3, A, 45, device=DIENST), P(105, 5), task(5, 5, "vorlesung", "f-verschoben", "Folien 3.pdf", 45, device=DIENST), T(205, 5),
         pkg(6, FRI, 3, B, 45), P(106, 6), task(6, 6, "vorlesung", "f-verschoben", "Folien 3.pdf", 45, moved="2026-11-17"), T(206, 6),
         # eigenes Paket (generated=0) mit derselben Datei: das automatische Doppel weicht
         pkg(7, THU, 1, A, 30, device=DIENST), P(107, 7), task(7, 7, "uebung", "f-eigenes", "Blatt 4.pdf", 30, device=DIENST), T(207, 7),
         pkg(8, FRI, 1, B, 30, generated=0, title="Eigenes Lernpaket"), P(108, 8), task(8, 8, "uebung", "f-eigenes", "Blatt 4.pdf", 30), T(208, 8),
         # beide angefasst: beide bleiben
         pkg(9, WED, 2, A, 30, status="in_bearbeitung"), P(109, 9), task(9, 9, "uebung", "f-beide", "Blatt 5.pdf", 30, status="in_bearbeitung"), T(209, 9),
         pkg(10, THU, 2, B, 30, locked=1), P(110, 10), task(10, 10, "uebung", "f-beide", "Blatt 5.pdf", 30), T(210, 10),
         # ein Lernschritt abgehakt / Eintrag im Verlauf: bleibt, das fruehere unberuehrte weicht
         pkg(11, WED, 3, A, 30, device=DIENST), P(111, 11), task(11, 11, "uebung", "f-schritt", "Blatt 6.pdf", 30, device=DIENST), T(211, 11),
         pkg(12, THU, 3, B, 30), P(112, 12), task(12, 12, "uebung", "f-schritt", "Blatt 6.pdf", 30, steps_done="[0]"), T(212, 12),
         pkg(13, WED, 1, A, 30, device=DIENST), P(113, 13), task(13, 13, "uebung", "f-verlauf", "Blatt 7.pdf", 30, device=DIENST), T(213, 13),
         pkg(14, THU, 1, B, 30), P(114, 14), task(14, 14, "uebung", "f-verlauf", "Blatt 7.pdf", 30), T(214, 14),
         "INSERT INTO task_history(task_id, package_id, old_status, new_status, old_date, new_date, note, at) "
         "VALUES (14, 14, 'erledigt', 'geplant', '2026-11-19', '2026-11-19', '', '2026-11-15T12:00:00')"]},
    {"name": "teilmenge", "about": "Das eigene Paket hat eine Datei mehr als das Konto: nur die doppelte Aufgabe geht, das Paket bleibt "
     "mit der anderen, seine Minuten und sein Block passen wieder. Nichts geht verloren.",
     "seed": [pkg(1, WED, 1, A, 105, start="08:00", end="10:00", device=DIENST), P(101, 1),
              task(1, 1, "vorlesung", "datei-vl", "Folien 05.pdf", 45, start="08:00", end="08:45", device=DIENST), T(201, 1),
              task(2, 1, "uebung", "datei-ue", "Blatt 05.pdf", 60, sort=1, start="09:00", end="10:00", device=DIENST), T(202, 2),
              pkg(2, THU, 1, B, 150, start="08:00", end="11:00"),
              task(3, 2, "vorlesung", "datei-vl", "Folien 05.pdf", 45, start="08:00", end="08:45"),
              task(4, 2, "uebung", "datei-ue", "Blatt 05.pdf", 60, sort=1, start="09:00", end="10:00"),
              task(5, 2, "uebung", "datei-neu", "Zusatzblatt.pdf", 45, sort=2, start="10:15", end="11:00")]},
    {"name": "gliederung", "about": "Aeltere App ohne Gliederung (ganze Datei) neben der neuen (Abschnitte mit Seiten), dieselbe "
     "Lehrwoche: die fruehere Planung bleibt ganz, die spaetere geht ganz. Verschiedene Abschnitte einer Planung bleiben.",
     "seed": [pkg(1, WED, 1, A, 90, device=DIENST), P(101, 1), task(1, 1, "vorlesung", "skript-1", "Skript.pdf", 90, device=DIENST), T(201, 1),
              pkg(2, THU, 1, B, 90), P(102, 2),
              task(2, 2, "vorlesung", "skript-1", "1 Signale · S. 4–9", 40, pages=(4, 9)), T(202, 2),
              task(3, 2, "vorlesung", "skript-1", "2.1 Definition bis 2.3 · S. 10–20", 50, sort=1, pages=(10, 20)), T(203, 3),
              pkg(3, WED, 2, A, 90, device=DIENST), P(103, 3),
              task(4, 3, "vorlesung", "skript-2", "1 Grundlagen · S. 4–9", 40, pages=(4, 9), device=DIENST), T(204, 4),
              task(5, 3, "vorlesung", "skript-2", "2 Methoden · S. 9–20", 50, sort=1, pages=(9, 20), device=DIENST), T(205, 5),
              pkg(4, FRI, 2, B, 90), P(104, 4), task(6, 4, "vorlesung", "skript-2", "Skript B.pdf", 90), T(206, 6)]},
    {"name": "teile", "about": "Lange Datei in Teilen: Teil 1/2 und Teil 2/2 einer Planung bleiben, dieselben Teile der zweiten Planung "
     "gehen; anders geteilt (Teil 1/3 gegen Teil 1/2) ist dieselbe Unterlage.",
     "seed": [pkg(1, WED, 1, A, 60, device=DIENST), P(101, 1), task(1, 1, "vorlesung", "lang-1", "Folien lang.pdf (Teil 1/2)", 60, device=DIENST), T(201, 1),
              pkg(2, THU, 1, A, 60, device=DIENST), P(102, 2), task(2, 2, "vorlesung", "lang-1", "Folien lang.pdf (Teil 2/2)", 60, device=DIENST), T(202, 2),
              pkg(3, FRI, 1, B, 120), P(103, 3),
              task(3, 3, "vorlesung", "lang-1", "Folien lang.pdf (Teil 1/2)", 60), T(203, 3),
              task(4, 3, "vorlesung", "lang-1", "Folien lang.pdf (Teil 2/2)", 60, sort=1), T(204, 4),
              pkg(4, WED, 2, A, 60, device=DIENST), P(104, 4), task(5, 4, "vorlesung", "lang-2", "Kapitel 7.pdf (Teil 1/2)", 60, device=DIENST), T(205, 5),
              pkg(5, THU, 2, B, 40), P(105, 5), task(6, 5, "vorlesung", "lang-2", "Kapitel 7.pdf (Teil 1/3)", 40), T(206, 6)]},
    {"name": "wochentest", "about": "Wochentest und Wiederholung gibt es je Fach und Lehrwoche einmal; eine andere Lehrwoche und freie "
     "Aufgaben ohne Datei bleiben immer.",
     "seed": [pkg(1, WED, 1, A, 60, device=DIENST), P(101, 1),
              task(1, 1, "test", None, "Gemeinsamer Wochentest Lehrwoche 5 – Reihen", 45, device=DIENST), T(201, 1),
              task(2, 1, "wiederholung", None, "Wiederholung Lehrwoche 5 (Karteikarten, Fehler aus dem Test)", 15, sort=1, device=DIENST), T(202, 2),
              pkg(2, THU, 1, B, 105), P(102, 2),
              task(3, 2, "test", None, "Gemeinsamer Wochentest Lehrwoche 5", 45), T(203, 3),
              task(4, 2, "wiederholung", None, "Wiederholung Lehrwoche 5 (Karteikarten, Fehler aus dem Test)", 15, sort=1), T(204, 4),
              task(5, 2, "frei", None, "Formelsammlung schreiben", 45, sort=2), T(205, 5),
              pkg(3, FRI, 1, B, 45, week=6, title="Woche 6 · 23.11. – 29.11."), P(103, 3),
              task(6, 3, "test", None, "Gemeinsamer Wochentest Lehrwoche 6", 45), T(206, 6),
              pkg(4, FRI, 2, B, 45), P(104, 4), task(7, 4, "frei", None, "Formelsammlung schreiben", 45), T(207, 7)]},
    {"name": "andere_lehrwoche", "about": "Die Lehrwoche einer Datei zaehlt je Geraet manchmal anders: dieselbe ganze Datei in Woche 4 und "
     "Woche 6 ist dieselbe Unterlage. Der Skriptrest einer spaeteren Woche (andere Seiten) bleibt.",
     "seed": [pkg(1, WED, 1, A, 45, week=4, title="Woche 4 · 09.11. – 15.11.", device=DIENST), P(101, 1),
              task(1, 1, "vorlesung", "f-woche", "10_12112026.pdf", 45, device=DIENST), T(201, 1),
              pkg(2, THU, 1, B, 45, week=6, title="Woche 6 · 09.11. – 15.11."), P(102, 2), task(2, 2, "vorlesung", "f-woche", "10_12112026.pdf", 45), T(202, 2),
              pkg(3, WED, 2, A, 60, week=4, title="Woche 4 · 09.11. – 15.11.", device=DIENST), P(103, 3),
              task(3, 3, "vorlesung", "f-skript", "Skript.pdf", 60, device=DIENST), T(203, 3),
              pkg(4, THU, 2, B, 40), P(104, 4), task(4, 4, "vorlesung", "f-skript", "Skript.pdf · S. 30–60", 40), T(204, 4),
              pkg(5, FRI, 2, B, 40, week=6, title="Woche 6 · 23.11. – 29.11."), P(105, 5), task(5, 5, "vorlesung", "f-skript", "Skript.pdf · S. 30–60", 40), T(205, 5)]},
    {"name": "leeres_paket", "about": "Automatisches Paket ohne jede Aufgabe, das so aus dem Konto kam (seine Aufgaben stehen in der "
     "Planung des anderen Geraets): belegt keine Uhrzeit mehr. Ein eigenes oder hier angelegtes leeres Paket bleibt, wie es ist.",
     "seed": [pkg(1, WED, 1, A, 60, start="19:15", end="20:15", device=DIENST), P(101, 1),
              pkg(4, THU, 1, A, 60, start="19:15", end="20:15"), P(104, 4),
              pkg(2, WED, 2, A, 30, start="10:00", end="10:30", generated=0, title="Eigenes Kapitel"), P(102, 2),
              pkg(3, WED, 3, A, 120, start="14:00", end="16:00", source="smart", title="Selbststudium", week=None), P(103, 3)]},
    {"name": "stundenplaner", "about": "Bloecke des Stundenplaners bleiben als Lernzeit stehen, auch wenn ihre doppelte Unterlage geht.",
     "seed": [pkg(1, WED, 1, A, 90, start="08:00", end="09:30", source="smart", title="Selbststudium", week=None, device=DIENST), P(101, 1),
              task(1, 1, "vorlesung", "datei-vl", "Folien 05.pdf", 45, device=DIENST), T(201, 1),
              pkg(2, THU, 1, B, 90, start="08:00", end="09:30", source="smart", title="Selbststudium", week=None), P(102, 2),
              task(2, 2, "vorlesung", "datei-vl", "Folien 05.pdf", 45), T(202, 2)]},
    {"name": "nichts_zu_tun", "about": "Ein normaler Plan eines Geraets: keine Zeile wird angefasst.",
     "seed": [pkg(1, WED, 1, A, 105, start="08:00", end="10:00"), P(101, 1),
              task(1, 1, "vorlesung", "datei-vl", "Folien 05.pdf", 45, start="08:00", end="08:45"), T(201, 1),
              task(2, 1, "uebung", "datei-ue", "Blatt 05.pdf", 60, sort=1, start="09:00", end="10:00"), T(202, 2),
              pkg(2, WED, 2, A, 60, start="10:15", end="11:15"), P(102, 2), task(3, 2, "uebung", "datei-b", "Blatt B.pdf", 60, start="10:15", end="11:15"), T(203, 3),
              pkg(3, THU, 3, A, 60, start="08:00", end="09:00"), task(4, 3, "uebung", "datei-c", "Blatt C.pdf", 60, start="08:00", end="09:00")]},
    # ------------------------------------------------------------ Tageslimit ueber alle Geraete
    {"name": "limit_stunden", "about": "4 Stunden je Tag: Das Konto hat den Mittwoch schon gefuellt, dieses Geraet hat ein eigenes Paket "
     "dazugelegt. Das zuletzt geplante weicht auf den naechsten Lerntag mit Platz.",
     "seed": [pkg(1, WED, 1, A, 120, start="08:00", end="10:00", device=DIENST), P(101, 1), task(1, 1, "vorlesung", "a-1", "Folien A.pdf", 120, start="08:00", end="10:00", device=DIENST), T(201, 1),
              pkg(2, WED, 2, A, 120, start="10:15", end="12:15", device=DIENST), P(102, 2), task(2, 2, "vorlesung", "b-1", "Folien B.pdf", 120, start="10:15", end="12:15", device=DIENST), T(202, 2),
              pkg(3, WED, 2, B, 60, start="12:30", end="13:30"), task(3, 3, "uebung", "b-2", "Blatt B.pdf", 60, start="12:30", end="13:30")]},
    {"name": "limit_zuerst_geplant", "about": "Das eigene, noch nicht gesendete Paket war zuerst geplant: es bleibt, das spaeter geplante "
     "aus dem Konto weicht. Das andere Geraet sieht dieselben Anlagezeiten und verlegt dasselbe Paket (nicht jedes sein eigenes).",
     "seed": [pkg(1, WED, 1, B, 120, start="08:00", end="10:00", device=DIENST), P(101, 1), task(1, 1, "vorlesung", "a-1", "Folien A.pdf", 120, start="08:00", end="10:00", device=DIENST), T(201, 1),
              pkg(2, WED, 2, B, 120, start="10:15", end="12:15", device=DIENST), P(102, 2), task(2, 2, "vorlesung", "b-1", "Folien B.pdf", 120, start="10:15", end="12:15", device=DIENST), T(202, 2),
              pkg(3, WED, 2, A, 120, start="12:30", end="14:30"), task(3, 3, "uebung", "b-2", "Blatt B.pdf", 120, start="12:30", end="14:30")]},
    {"name": "limit_faecher", "about": "2 Faecher je Tag: drei Faecher am Mittwoch, das zuletzt geplante weicht. Am Donnerstag liegen "
     "schon zwei andere Faecher, also Freitag.",
     "seed": [pkg(1, WED, 1, A, 60, start="08:00", end="09:00", device=DIENST), P(101, 1), task(1, 1, "uebung", "a-1", "Blatt A.pdf", 60, start="08:00", end="09:00", device=DIENST), T(201, 1),
              pkg(2, WED, 2, A, 60, start="09:15", end="10:15", device=DIENST), P(102, 2), task(2, 2, "uebung", "b-1", "Blatt B.pdf", 60, start="09:15", end="10:15", device=DIENST), T(202, 2),
              pkg(3, WED, 3, B, 60, start="10:30", end="11:30"), task(3, 3, "uebung", "c-1", "Blatt C.pdf", 60, start="10:30", end="11:30"),
              pkg(4, THU, 1, A, 60, start="08:00", end="09:00", device=DIENST), P(104, 4), task(4, 4, "uebung", "a-2", "Blatt A2.pdf", 60, start="08:00", end="09:00", device=DIENST), T(204, 4),
              pkg(5, THU, 2, A, 60, start="09:15", end="10:15", device=DIENST), P(105, 5), task(5, 5, "uebung", "b-2", "Blatt B2.pdf", 60, start="09:15", end="10:15", device=DIENST), T(205, 5)]},
    {"name": "uebereinander", "about": "Zwei Geraete haben verschiedene Unterlagen auf dieselbe Uhrzeit gelegt: das zuletzt geplante "
     "bekommt das naechste freie Fenster desselben Tags.",
     "seed": [pkg(1, WED, 1, A, 60, start="08:00", end="09:00", device=DIENST), P(101, 1), task(1, 1, "uebung", "a-1", "Blatt A.pdf", 60, start="08:00", end="09:00", device=DIENST), T(201, 1),
              pkg(2, WED, 2, B, 60, start="08:30", end="09:30"), task(2, 2, "uebung", "b-1", "Blatt B.pdf", 60, start="08:30", end="09:30")]},
    {"name": "nur_konto", "about": "Alles an diesem Tag kam aus dem Konto (neues Geraet, neu installiert): der Plan bleibt, wie ihn das "
     "andere Geraet gelegt hat, auch mit drei Faechern.",
     "seed": [pkg(i, WED, i, A, 60, start=f"{7 + i:02d}:00", end=f"{8 + i:02d}:00", device=DIENST) for i in (1, 2, 3)]
     + [P(100 + i, i) for i in (1, 2, 3)]
     + [task(i, i, "uebung", f"datei-{i}", f"Blatt {i}.pdf", 60, start=f"{7 + i:02d}:00", end=f"{8 + i:02d}:00", device=DIENST) for i in (1, 2, 3)]
     + [T(200 + i, i) for i in (1, 2, 3)]},
    {"name": "eigenes_bleibt_liegen", "about": "Von Hand angelegt bleibt immer liegen, auch wenn es zuletzt kam: von den automatischen "
     "Paketen aus dem Konto weicht das spaeter geplante. Heute (Montag) bleibt, wie es ist.",
     "seed": [pkg(1, WED, 1, A, 60, start="08:00", end="09:00", device=DIENST), P(101, 1), task(1, 1, "uebung", "a-1", "Blatt A.pdf", 60, start="08:00", end="09:00", device=DIENST), T(201, 1),
              pkg(2, WED, 2, B, 60, start="09:15", end="10:15", device=DIENST), P(102, 2), task(2, 2, "uebung", "b-1", "Blatt B.pdf", 60, start="09:15", end="10:15", device=DIENST), T(202, 2),
              pkg(3, WED, 3, B, 60, start="10:30", end="11:30", generated=0, title="Eigenes Lernpaket"), task(3, 3, "frei", None, "Klausur ueben", 60, start="10:30", end="11:30"),
              pkg(4, TODAY, 1, A, 60, start="15:00", end="16:00", device=DIENST), P(104, 4), task(4, 4, "uebung", "a-2", "Blatt A2.pdf", 60, start="15:00", end="16:00", device=DIENST), T(204, 4),
              pkg(5, TODAY, 2, A, 60, start="16:15", end="17:15", device=DIENST), P(105, 5), task(5, 5, "uebung", "b-2", "Blatt B2.pdf", 60, start="16:15", end="17:15", device=DIENST), T(205, 5),
              pkg(6, TODAY, 3, B, 60, start="17:30", end="18:30"), task(6, 6, "uebung", "c-2", "Blatt C2.pdf", 60, start="17:30", end="18:30")]},
]

PACKAGES_SQL = ("SELECT id, date, module_id, subject, title, week_no, planned_minutes, status, sort, generated, created_at, start_time, end_time, "
                "source, locked, manual FROM study_packages ORDER BY id")
TASKS_SQL = ("SELECT id, package_id, type, file_id, title, sort, est_minutes, actual_minutes, status, done_at, moved_from, start_time, end_time, "
             "page_from, page_to, steps_done FROM study_tasks ORDER BY id")
TOMB_SQL = "SELECT entity, entity_id FROM sync_tombstones ORDER BY entity, CAST(entity_id AS INTEGER)"


def build(check: bool) -> int:
    src = SchemaSource()
    try:
        from app import plan_merge, sync_client
        today = date.fromisoformat(TODAY)
        src.freeze(lambda: today, lambda: f"{TODAY}T09:00:00")
        cases = []
        for case in CASES:
            path = src.fresh_db("plan-merge-" + case["name"])
            with src.db.cursor() as conn:
                sync_client.ensure_tables(conn)
                for sql in SETUP + case["seed"]:
                    conn.execute(sql)
            with src.db.cursor() as conn:
                result = plan_merge.after_pull(conn, hosted=False, today=today)
            after = dump_tables(path, {"study_packages": PACKAGES_SQL, "study_tasks": TASKS_SQL, "tombstones": TOMB_SQL})
            with src.db.cursor() as conn:
                again = plan_merge.after_pull(conn, hosted=False, today=today)
            assert dump_tables(path, {"study_packages": PACKAGES_SQL, "study_tasks": TASKS_SQL, "tombstones": TOMB_SQL}) == after, case["name"]
            cases.append({"name": case["name"], "about": case["about"], "seed": case["seed"], "result": result, "again": again,
                          "study_packages": after["study_packages"], "study_tasks": after["study_tasks"],
                          "tombstones": [[t["entity"], t["entity_id"]] for t in after["tombstones"]]})
    finally:
        src.cleanup()
    out = {"generator": "tools/gen-plan-merge-fixture.py", "today": TODAY, "timezone": "Europe/Berlin", "setup": SETUP, "cases": cases}
    ok = write_or_check(OUT, json.dumps(out, ensure_ascii=False, indent=1) + "\n", check)
    return 0 if ok or not check else 1


if __name__ == "__main__":
    with berlin_time():
        sys.exit(build("--check" in sys.argv[1:]))
