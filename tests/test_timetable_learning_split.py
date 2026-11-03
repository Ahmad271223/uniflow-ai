"""Stundenplan zeigt nur die Hochschultermine; alles zu Lernslots steht im Lernkalender (03.11.2026).

Verfuegbarkeit (learn_start/learn_end, Fahrtzeit, Sperrzeiten) im Kopf des Lernkalenders statt im Stundenplan, nach dem
Import keine Konfliktliste mit "Lernslots neu legen" mehr, sondern eine Zeile mit Wechsel in den Lernkalender; die
Neuplanung (POST /api/timetable/reslot) ruft nur der Lernkalender auf. "Lernblock danach" im Termin-Panel bleibt.
"""
from pathlib import Path

ST = Path(__file__).resolve().parents[1] / "app" / "static"


def _src(name):
    """Quelltext ohne Kommentarzeilen (die Kopfzeilen nennen, was in den Lernkalender gewandert ist)"""
    lines = (ST / name).read_text(encoding="utf-8").split("\n")
    return "\n".join(l for l in lines if not l.lstrip().startswith(("//", "*", "/*")))


def test_availability_moved_to_planner():
    tt, plan, misc = _src("views-tt.js"), _src("views-plan.js"), _src("views-misc.js")
    assert "ttAvail" not in tt and "availabilityDialog" not in tt and "Verfügbarkeit" not in tt
    assert 'id="availBtn"' in plan and "Verfügbarkeit</button>" in plan
    assert "export async function availabilityDialog()" in plan and '$("#availBtn").onclick = () => availabilityDialog();' in plan
    assert 'else if (q === "free") availabilityDialog();' in plan          # Schnell hinzufuegen: Freie Zeit
    assert "learn_start" in plan and "blocked_times" in plan and "learn_start" not in tt and "blocked" not in tt
    assert ".availabilityDialog()" in misc and 'import("./views-tt.js' not in misc.split("openAvail")[1].split("\n")[0]


def test_import_conflicts_are_one_line_and_open_planner():
    tt, plan = _src("views-tt.js"), _src("views-plan.js")
    assert "kollidieren" not in tt and "cfOk" not in tt and "/timetable/reslot" not in tt
    assert "im Lernkalender neu legen" in tt and 'location.hash = "#/plan"' in tt
    assert plan.count('api("/timetable/reslot"') == 2                      # Woche und Tag: "Uhrzeiten vergeben"


def test_timetable_keeps_only_university_schedule():
    tt = _src("views-tt.js")
    for word in ("packages", "d.free", "is-free", "learn_", "blocked"):
        assert word not in tt, word
    assert tt.count("Lernslot") == 1 and "importConflictHint" in tt          # nur die eine Zeile nach dem Import
    assert 'id="evBlock"' in tt and "useFreeWindow" in tt                    # Lernblock danach bleibt (Schnellaktion)
