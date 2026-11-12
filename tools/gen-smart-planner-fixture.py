"""Smart Planner 2.0: Abgleich Python <-> Swift-Kern.

Erzeugt packages/shared-contracts/fixtures/local-backend/smart-planner.json mit Eingaben und den Ergebnissen von
app/smart_planner.py (plan, build_days, credit, diff, assign_materials, module_stats). Der Swift-Test
`SmartPlannerParityTests` rechnet jede Eingabe nach und verlangt dasselbe JSON. Aufruf aus dem Repo:
    python tools/gen-smart-planner-fixture.py [--check]
"""
from __future__ import annotations

import json
import random
import sys
from datetime import date, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app import smart_planner as sp  # noqa: E402

OUT = ROOT / "packages/shared-contracts/fixtures/local-backend/smart-planner.json"
MON = date(2026, 11, 16)


def mkdays(n, start=MON, win=((540, 840),), weekdays=range(5), reserve=()):
    out = []
    for i in range(n):
        d = start + timedelta(i)
        on = d.weekday() in weekdays
        out.append({"date": d.isoformat(), "weekday": d.weekday(), "windows": [list(w) for w in win] if on else [],
                    "reserve": [list(r) for r in reserve] if on else []})
    return out


def three(days, hours=(200, 250, 220), weeks=(10, 12, 14)):
    return [{"id": i + 1, "exam_date": days[w * 7]["date"], "remaining_minutes": h * 60} for i, (h, w) in enumerate(zip(hours, weeks))]


def plan_cases():
    cases = []
    d = mkdays(100)
    cases.append(("unterdeckung_320", {"days": d, "modules": three(d), "settings": {"utilization": 100}}))
    cases.append(("teilplan", {"days": d, "modules": three(d), "settings": {"utilization": 100}, "accept_partial": True}))
    d = mkdays(100, win=((540, 1260),), reserve=((1260, 1380),))
    cases.append(("optionen_quote_freizeit", {"days": d, "modules": three(d), "settings": {"utilization": 50}}))
    d = mkdays(100, win=((480, 1080),))
    cases.append(("machbar_drei_klausuren", {"days": d, "modules": three(d), "settings": {"utilization": 100}}))
    d = mkdays(140)
    m = three(d)
    m[1]["exam_date_2"] = d[133]["date"]
    cases.append(("zweittermin", {"days": d, "modules": m[:2], "settings": {"utilization": 100}}))
    d = mkdays(28, win=((480, 1080),), weekdays=range(7))
    cases.append(("obergrenzen", {"days": d, "settings": {"utilization": 100, "max_week_minutes": 600, "max_day_minutes": 240},
                                  "modules": [{"id": 1, "exam_date": d[27]["date"], "remaining_minutes": 30 * 60}]}))
    d = mkdays(28, win=((480, 1080),))
    cases.append(("feste_bloecke", {"days": d, "settings": {"utilization": 100}, "now_minute": 787,
                                    "fixed": [{"module_id": 1, "date": d[2]["date"], "start": 480, "end": 600},
                                              {"module_id": 1, "date": d[27]["date"], "start": 480, "end": 600},
                                              {"module_id": 2, "date": d[3]["date"], "start": 600, "end": 690, "counts": False}],
                                    "modules": [{"id": 1, "exam_date": d[20]["date"], "remaining_minutes": 10 * 60 + 30},
                                                {"id": 2, "exam_date": None, "remaining_minutes": 300, "priority": 3},
                                                {"id": "x", "exam_date": d[0]["date"], "remaining_minutes": 99}]}))
    rnd = random.Random(1112)
    for case in range(40):
        n = rnd.randint(7, 60)
        days = []
        for i in range(n):
            dd = MON + timedelta(i)
            ws, t = [], rnd.randint(420, 700)
            for _ in range(rnd.randint(0, 3)):
                e = t + rnd.randint(10, 300)
                ws.append([t, min(e, 1440)])
                t = e + rnd.randint(0, 120)
                if t >= 1440:
                    break
            res = [[1260, 1260 + rnd.choice([0, 30, 120])]] if rnd.random() < 0.3 else []
            days.append({"date": dd.isoformat(), "weekday": dd.weekday(), "windows": ws, "reserve": res})
        mods = []
        for k in range(rnd.randint(1, 5)):
            e = rnd.choice([None] + [days[rnd.randint(0, n - 1)]["date"] for _ in range(4)])
            mods.append({"id": k + 1, "exam_date": e, "remaining_minutes": rnd.randint(-60, 80 * 60), "priority": rnd.randint(1, 3),
                         "exam_date_2": rnd.choice([None, days[rnd.randint(0, n - 1)]["date"]])})
        fixed = []
        for _ in range(rnd.randint(0, 3)):
            dd = days[rnd.randint(0, n - 1)]
            if dd["windows"] and dd["windows"][0][1] - dd["windows"][0][0] >= 30:
                a = dd["windows"][0][0]
                fixed.append({"module_id": rnd.randint(1, len(mods)), "date": dd["date"], "start": a, "end": a + 30})
        cases.append((f"zufall_{case}", {"days": days, "modules": mods, "fixed": fixed,
                                         "now_minute": rnd.choice([None, rnd.randint(0, 1439)]),
                                         "settings": {"utilization": rnd.choice([30, 60, 100]), "max_block": rnd.choice([60, 90, 120]),
                                                      "break": rnd.choice([0, 10, 15]), "max_week_minutes": rnd.choice([0, 0, 1200])},
                                         "accept_partial": rnd.random() < 0.5}))
    return [{"name": n, "input": i, "output": sp.plan(i)} for n, i in cases]


def build_days_cases():
    dates = []
    for i in range(21):
        d = MON + timedelta(i)
        dates.append({"date": d.isoformat(), "weekday": d.weekday(), "busy": [[600, 780]] if d.weekday() in (0, 3) else []})
    sets = [{}, {"sleep_minutes": 600, "bedtime": 1380, "leisure_minutes": 120, "commitments": [{"weekday": 2, "start": 960, "end": 1200}]},
            {"bedtime": 60, "sleep_minutes": 480, "leisure_minutes": 0, "learn_days": [0, 1, 2, 3, 4]},
            {"sleep_minutes": 1440}, {"leisure_minutes": 900}]
    return [{"dates": dates, "settings": s, "output": sp.build_days(dates, s)} for s in sets]


def credit_cases():
    a = 1_795_338_000
    s1 = [{"uuid": "u1", "module_id": 1, "kind": "timer", "segments": [[a, a + 3600]], "updated_at": "1"},
          {"uuid": "u1", "module_id": 1, "kind": "timer", "segments": [[a, a + 3600]], "updated_at": "1"},
          {"uuid": "u2", "module_id": 1, "kind": "timer", "segments": [[a + 1800, a + 5400]], "updated_at": "1"},
          {"uuid": "u3", "module_id": 2, "kind": "manual", "minutes": 90, "updated_at": "1"},
          {"uuid": "u4", "module_id": 2, "kind": "manual", "minutes": 30, "updated_at": "1", "deleted": True},
          {"uuid": "u5", "module_id": 3, "package_id": 9, "kind": "timer", "segments": [[a + 7200, a + 9000]], "updated_at": "1"},
          {"uuid": "u6", "module_id": 3, "package_id": 9, "kind": "block", "minutes": 25, "updated_at": "2"},
          {"uuid": "u7", "module_id": 3, "package_id": 9, "kind": "block", "minutes": 40, "updated_at": "1"},
          {"uuid": "u8", "module_id": 4, "package_id": 11, "kind": "manual", "minutes": 15, "updated_at": "1"},
          {"uuid": "u9", "module_id": 4, "kind": "timer", "segments": [[a + 20000, None]], "updated_at": "1"},
          {"uuid": "u2", "module_id": 1, "kind": "timer", "segments": [[a + 1800, a + 4000]], "updated_at": "3"}]
    rnd = random.Random(7)
    s2 = []
    for i in range(80):
        st = a + rnd.randint(0, 50000)
        s2.append({"uuid": f"r{rnd.randint(0, 60)}", "module_id": rnd.randint(1, 4), "kind": rnd.choice(["timer", "manual", "block"]),
                   "package_id": rnd.choice([None, 1, 2, 3]), "updated_at": str(rnd.randint(0, 9)),
                   "segments": [[st, st + rnd.randint(-100, 4000)], [st + 5000, rnd.choice([None, st + 6000])]] if rnd.random() < 0.6 else [],
                   "minutes": rnd.randint(-5, 120), "deleted": rnd.random() < 0.1})
    return [{"sessions": s, "now_ts": a + 30000, "output": sp.credit(s, a + 30000)} for s in (s1, s2, [])]


def diff_cases():
    ex = [{"id": 5, "module_id": 1, "date": "2026-11-17", "start": 600, "end": 720},
          {"id": 3, "module_id": 1, "date": "2026-11-17", "start": 600, "end": 720},
          {"id": 7, "module_id": 2, "date": "2026-11-18", "start": 540, "end": 600},
          {"id": 9, "module_id": 2, "date": "2026-11-19", "start": 540, "end": 600}]
    new = [{"module_id": 1, "date": "2026-11-17", "start": 600, "end": 720, "minutes": 120},
           {"module_id": 2, "date": "2026-11-19", "start": 540, "end": 615, "minutes": 75},
           {"module_id": 2, "date": "2026-11-18", "start": 540, "end": 600, "minutes": 60}]
    return [{"existing": ex, "new": new, "output": sp.diff(ex, new)}, {"existing": [], "new": [], "output": sp.diff([], [])}]


def assign_cases():
    blocks = [{"id": 1, "module_id": 1, "date": "2026-11-17", "start": 600, "minutes": 120, "used": 0},
              {"id": 2, "module_id": 1, "date": "2026-11-24", "start": 600, "minutes": 90, "used": 30},
              {"id": 3, "module_id": 2, "date": "2026-11-17", "start": 900, "minutes": 60, "used": 0},
              {"id": 4, "module_id": 1, "date": "2026-11-17", "start": 480, "minutes": 60, "used": 0}]
    mats = [{"file_id": "a", "module_id": 1, "kind": "vorlesung", "from_date": "2026-11-16", "est": 60},
            {"file_id": "b", "module_id": 1, "kind": "uebung", "from_date": "2026-11-23", "est": 60},
            {"file_id": "c", "module_id": 1, "kind": "skript", "from_date": "2026-11-16", "est": 300},
            {"file_id": "d", "module_id": 1, "kind": "klausur", "from_date": "2026-11-16", "est": 60},
            {"file_id": "e", "module_id": 2, "kind": None, "from_date": None, "est": 0},
            {"file_id": "f", "module_id": 2, "kind": "loesung", "from_date": "2026-11-16", "est": 200}]
    return [{"blocks": blocks, "materials": mats, "max_block": mb, "output": sp.assign_materials(blocks, mats, mb)} for mb in (120, 60)]


def stats_cases():
    ms = [{"target_minutes": 12000, "learned_minutes": 1800, "lecture_minutes": 0, "days_left": 70, "planned_minutes": 10200, "adherence": None},
          {"target_minutes": 12000, "learned_minutes": 1800, "lecture_minutes": 2400, "days_left": 70, "planned_minutes": 7800, "adherence": 50},
          {"target_minutes": 6000, "learned_minutes": 6100},
          {"target_minutes": 6000, "learned_minutes": 100, "days_left": 0},
          {"target_minutes": 6000, "learned_minutes": 100, "days_left": 13, "planned_minutes": 5300, "adherence": 95},
          {"target_minutes": 0, "learned_minutes": 0, "days_left": None}]
    return [{"input": m, "output": sp.module_stats(m)} for m in ms]


def build() -> dict:
    return {"generator": "tools/gen-smart-planner-fixture.py", "plan": plan_cases(), "build_days": build_days_cases(),
            "credit": credit_cases(), "diff": diff_cases(), "assign": assign_cases(), "stats": stats_cases(),
            "hours_text": {str(m): sp.hours_text(m) for m in (0, 10, 15, 30, 59, 60, 61, 150, 670 * 60, 19200, -90)}}


def main() -> int:
    check = "--check" in sys.argv
    content = json.dumps(build(), ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n"
    current = OUT.read_text(encoding="utf-8") if OUT.exists() else None
    if current == content:
        print(f"aktuell: {OUT.relative_to(ROOT)}")
        return 0
    if check:
        print(f"VERALTET: {OUT.relative_to(ROOT)}", file=sys.stderr)
        return 1
    OUT.write_text(content, encoding="utf-8")
    print(f"geschrieben: {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
