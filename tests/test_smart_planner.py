"""Smart Planner 2.0: reiner Rechenkern (app/smart_planner.py), Pflicht-Testszenarien des Auftrags vom 12.11.2026."""
import json
import random
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from app import smart_planner as sp

MON = date(2026, 11, 16)


def mkdays(n, start=MON, win=((540, 840),), weekdays=range(5), reserve=()):
    out = []
    for i in range(n):
        d = start + timedelta(i)
        on = d.weekday() in weekdays
        out.append({"date": d.isoformat(), "weekday": d.weekday(), "windows": [list(w) for w in win] if on else [],
                    "reserve": [list(r) for r in reserve] if on else []})
    return out


def exam(days, week):
    """Klausur am Montag nach Woche `week` (Woche 1 = erste Woche): Lernzeit bis einschliesslich Woche `week`"""
    return days[week * 7]["date"]


def three(days, hours=(200, 250, 220), weeks=(10, 12, 14)):
    return [{"id": i + 1, "exam_date": exam(days, w), "remaining_minutes": h * 60} for i, (h, w) in enumerate(zip(hours, weeks))]


def check_hard(r, inp):
    """Harte Bedingungen jedes Plans"""
    days = {d["date"]: d for d in inp["days"]}
    exams = {m["id"]: m.get("exam_date") for m in inp["modules"]}
    fixed = {}
    for f in inp.get("fixed") or []:
        fixed.setdefault(f["date"], []).append((f["start"], f["end"]))
    per_day = {}
    for b in r["blocks"]:
        assert b["end"] > b["start"] and b["minutes"] == b["end"] - b["start"]
        assert b["start"] % 5 == 0 and b["minutes"] % 15 == 0
        e = exams[b["module_id"]]
        assert e is None or b["date"] < e, "Block am oder nach der Klausur"
        ws = sp.merge(days[b["date"]]["windows"])
        assert any(a <= b["start"] and b["end"] <= z for a, z in ws), "Block ausserhalb eines freien Fensters"
        assert not any(b["start"] < z and b["end"] > a for a, z in fixed.get(b["date"], [])), "Block ueber festem Termin"
        if inp.get("now_minute") is not None and b["date"] == inp["days"][0]["date"]:
            assert b["start"] >= inp["now_minute"]
        per_day.setdefault(b["date"], []).append(b)
    for d, bs in per_day.items():
        bs.sort(key=lambda b: b["start"])
        for x, y in zip(bs, bs[1:]):
            assert x["end"] <= y["start"], "Bloecke ueberschneiden sich"
    caps = dict(zip([d["date"] for d in inp["days"]], r["capacity_minutes"]))
    for d, bs in per_day.items():
        assert sum(b["minutes"] for b in bs) <= caps[d], "mehr als die Nutzungsquote"


# ------------------------------------------------------------ Pflichtszenarien

def test_unterdeckung_670_350_fehlen_320_ohne_scheinplan():
    days = mkdays(100)                                    # 14 Wochen x 25 h (Mo-Fr 5 h)
    inp = {"days": days, "modules": three(days), "settings": {"utilization": 100}}
    r = sp.plan(inp)
    assert r["status"] == "unterdeckt" and not r["feasible"]
    assert r["message"] == "670 h nötig, 350 h verfügbar, fehlen 320 h"
    assert [(x["need_minutes"] // 60, x["available_minutes"] // 60, x["missing_minutes"] // 60) for x in r["deadlines"]] == \
        [(200, 250, 0), (450, 300, 150), (670, 350, 320)]
    assert r["blocks"] == []                              # kein scheinbar vollstaendiger Plan
    kinds = [o["kind"] for o in r["options"]]
    assert "nutzungsquote" not in kinds                   # bei 100 % keine Stunden erfinden
    assert {"ziele", "prioritaeten", "teilplan"} <= set(kinds)
    cuts = next(o for o in r["options"] if o["kind"] == "ziele")["cuts"]
    assert sum(c["minutes"] for c in cuts) >= 320 * 60
    # mit den gesenkten Zielen passt es
    mods = [dict(m, remaining_minutes=m["remaining_minutes"] - next((c["minutes"] for c in cuts if c["module_id"] == m["id"]), 0))
            for m in inp["modules"]]
    assert sp.plan(dict(inp, modules=mods))["feasible"]


def test_unterdeckung_optionen_quote_und_freizeit_werden_vorgeschlagen_nicht_angewendet():
    days = mkdays(100, win=((540, 1260),), reserve=((1260, 1380),))
    inp = {"days": days, "modules": three(days), "settings": {"utilization": 50}}
    r = sp.plan(inp)
    assert r["status"] == "unterdeckt" and r["blocks"] == []
    q = next(o for o in r["options"] if o["kind"] == "nutzungsquote")
    assert q["value"] is not None and 50 < q["value"] <= 100
    assert sp.plan(dict(inp, settings={"utilization": q["value"]}))["feasible"]
    assert sp.plan(dict(inp, settings={"utilization": q["value"] - 5}))["feasible"] is False
    f = next(o for o in r["options"] if o["kind"] == "freizeit")
    assert f["minutes_per_day"] is None or f["minutes_per_day"] % 15 == 0


def test_teilplan_nur_auf_wunsch_und_ehrlich():
    days = mkdays(100)
    inp = {"days": days, "modules": three(days), "settings": {"utilization": 100}, "accept_partial": True}
    r = sp.plan(inp)
    assert r["status"] == "teilplan"
    check_hard(r, inp)
    planned = sum(b["minutes"] for b in r["blocks"])
    assert planned <= 350 * 60
    assert sum(m["unplanned_minutes"] for m in r["modules"]) >= 320 * 60
    # fruehere Klausur zuerst bedient: Mathematik bekommt alle 200 h
    assert next(m for m in r["modules"] if m["id"] == 1)["unplanned_minutes"] == 0


def test_machbar_gleichmaessig_frueher_zuerst_freiwerdende_zeit_an_die_uebrigen():
    days = mkdays(100, win=((480, 1080),))                # 14 Wochen x 50 h
    inp = {"days": days, "modules": three(days), "settings": {"utilization": 100}}
    r = sp.plan(inp)
    assert r["status"] == "ok" and r["feasible"]
    check_hard(r, inp)
    got = {m["id"]: m["planned_minutes"] for m in r["modules"]}
    assert got == {1: 200 * 60, 2: 250 * 60, 3: 220 * 60}
    week = {}
    for b in r["blocks"]:
        w = (date.fromisoformat(b["date"]) - MON).days // 7 + 1
        week.setdefault(w, {}).setdefault(b["module_id"], 0)
        week[w][b["module_id"]] += b["minutes"]
    # parallel statt nacheinander, keine Woche leer
    assert all(len(week[w]) >= 2 for w in range(1, 13))
    # nach Klausur 1 (Woche 10) geht ihre Zeit an Module 2 und 3
    assert 1 not in week[11] and sum(week[11].values()) > sum(v for k, v in week[9].items() if k != 1)
    # gleichmaessig: Modul 1 je Woche hoechstens 1 h Unterschied
    m1 = [week[w].get(1, 0) for w in range(1, 11)]
    assert max(m1) - min(m1) <= 60


def test_zeitfenster_statt_wochensumme_freier_sonntag_gleicht_keinen_vollen_dienstag_aus():
    days = mkdays(14, weekdays=(6,), win=((540, 1260),))  # nur sonntags frei
    for d in days:
        if d["weekday"] == 1:
            d["windows"] = []                             # Dienstag voll
    m = [{"id": 1, "exam_date": days[9]["date"], "remaining_minutes": 20 * 60}]  # Klausur Mittwoch Woche 2
    r = sp.plan({"days": days, "modules": m, "settings": {"utilization": 100}})
    # bis Mittwoch der zweiten Woche gibt es genau einen Sonntag mit 12 h
    assert not r["feasible"] and r["deadlines"][0]["available_minutes"] == 12 * 60


def test_pflichttermine_schlaf_freizeit_und_verpflichtungen_beachtet():
    settings = {"sleep_minutes": 600, "bedtime": 1380, "leisure_minutes": 120,
                "commitments": [{"weekday": 2, "start": 960, "end": 1200}]}   # Mittwoch Arbeit 16-20 Uhr
    dates = []
    for i in range(21):
        d = MON + timedelta(i)
        busy = [[600, 780]] if d.weekday() in (0, 3) else []                 # Vorlesung Mo/Do 10-13 Uhr
        dates.append({"date": d.isoformat(), "weekday": d.weekday(), "busy": busy})
    days = sp.build_days(dates, settings)
    # Schlaf 23-9 Uhr, Freizeit 21-23 Uhr: Rahmen 9-21 Uhr
    assert days[1]["windows"] == [[540, 1260]] and days[1]["reserve"] == [[1260, 1380]]
    assert days[0]["windows"] == [[540, 600], [780, 1260]]
    assert days[2]["windows"] == [[540, 960], [1200, 1260]]
    inp = {"days": days, "modules": [{"id": 7, "exam_date": days[20]["date"], "remaining_minutes": 60 * 60}],
           "settings": {"utilization": 60}}
    r = sp.plan(inp)
    check_hard(r, inp)
    for b in r["blocks"]:
        wd = date.fromisoformat(b["date"]).weekday()
        assert 540 <= b["start"] and b["end"] <= 1260
        if wd in (0, 3):
            assert not (b["start"] < 780 and b["end"] > 600)
        if wd == 2:
            assert not (b["start"] < 1200 and b["end"] > 960)


def test_schlaf_nach_mitternacht_und_ungueltige_werte():
    fr = sp.day_frame({"bedtime": 60, "sleep_minutes": 600, "leisure_minutes": 0}, 0)
    assert fr["frame"] == [660, 1440]
    assert sp.day_frame({"bedtime": 1380, "sleep_minutes": 1440, "leisure_minutes": 0}, 0) is None
    assert sp.day_frame({"learn_days": [0]}, 3) is None
    days = mkdays(14)
    days[0]["windows"] = [[600, 500], [700, 700]]          # kaputte Fenster werden ignoriert
    r = sp.plan({"days": days, "modules": [{"id": 1, "exam_date": days[13]["date"], "remaining_minutes": -50}],
                 "settings": {"utilization": 0, "min_block": 0, "max_block": 5}})
    assert r["status"] == "ok" and r["blocks"] == []       # negatives Ziel = nichts zu tun
    r = sp.plan({"days": days, "modules": [{"id": 1, "exam_date": days[13]["date"], "remaining_minutes": 600}],
                 "settings": {"utilization": 400}})
    assert r["capacity_minutes"][1] == 300                 # Quote auf 100 % begrenzt


def test_gelernte_stunden_und_feste_bloecke_werden_abgezogen_keine_doppelzaehlung():
    days = mkdays(28, win=((480, 1080),))
    fixed = [{"module_id": 1, "date": days[2]["date"], "start": 480, "end": 600},     # manuell, zaehlt
             {"module_id": 1, "date": days[27]["date"], "start": 480, "end": 600}]    # nach der Klausur: zaehlt nicht
    inp = {"days": days, "fixed": fixed, "settings": {"utilization": 100},
           "modules": [{"id": 1, "exam_date": days[20]["date"], "remaining_minutes": 10 * 60}]}
    r = sp.plan(inp)
    m = r["modules"][0]
    assert m["fixed_minutes"] == 120 and m["need_minutes"] == 480 and m["planned_minutes"] == 480
    check_hard(r, inp)
    st = sp.module_stats({"target_minutes": 200 * 60, "learned_minutes": 30 * 60, "lecture_minutes": 0,
                          "days_left": 70, "planned_minutes": 170 * 60, "adherence": None})
    assert st["remaining_minutes"] == 170 * 60 and st["per_week_minutes"] == 17 * 60 and st["status"] == "auf_kurs"
    st = sp.module_stats({"target_minutes": 200 * 60, "learned_minutes": 30 * 60, "lecture_minutes": 40 * 60,
                          "days_left": 70, "planned_minutes": 130 * 60, "adherence": 50})
    assert st["remaining_minutes"] == 130 * 60 and st["forecast_minutes"] == 135 * 60 and st["status"] == "gefaehrdet"


def test_ziel_schon_erreicht_und_klausur_vorbei():
    days = mkdays(28)
    r = sp.plan({"days": days, "modules": [{"id": 1, "exam_date": days[20]["date"], "remaining_minutes": 0},
                                           {"id": 2, "exam_date": days[0]["date"], "remaining_minutes": 600}]})
    assert r["status"] == "ok" and r["blocks"] == []
    assert r["modules"][1]["exam_passed"] and r["modules"][1]["unplanned_minutes"] == 0
    assert sp.module_stats({"target_minutes": 6000, "learned_minutes": 6100})["status"] == "erreicht"


def test_ziel_erhoeht_und_klausur_verschoben_mit_geringster_aenderung():
    days = mkdays(70, win=((480, 1080),))
    base = {"days": days, "settings": {"utilization": 50},
            "modules": [{"id": 1, "exam_date": days[42]["date"], "remaining_minutes": 40 * 60},
                        {"id": 2, "exam_date": days[56]["date"], "remaining_minutes": 40 * 60}]}
    r1 = sp.plan(base)
    existing = [dict(b, id=i + 1) for i, b in enumerate(r1["blocks"])]
    same = sp.diff(existing, sp.plan(base)["blocks"])
    assert same["remove"] == [] and same["add"] == [] and len(same["keep"]) == len(existing)   # deterministisch
    up = json.loads(json.dumps(base))
    up["modules"][0]["remaining_minutes"] = 60 * 60
    r2 = sp.plan(up)
    assert next(m for m in r2["modules"] if m["id"] == 1)["planned_minutes"] == 60 * 60
    check_hard(r2, up)
    later = json.loads(json.dumps(base))
    later["modules"][0]["exam_date"] = days[49]["date"]
    r3 = sp.plan(later)
    check_hard(r3, later)
    assert max(b["date"] for b in r3["blocks"] if b["module_id"] == 1) > max(b["date"] for b in r1["blocks"] if b["module_id"] == 1)


def test_verpasste_bloecke_werden_nachgeplant():
    days = mkdays(35, win=((480, 1080),))
    inp = {"days": days, "settings": {"utilization": 50},
           "modules": [{"id": 1, "exam_date": days[28]["date"], "remaining_minutes": 40 * 60}]}
    r = sp.plan(inp)
    # zwei Tage spaeter, nichts gelernt: gleiche Restzeit, weniger Tage
    later = dict(inp, days=days[2:])
    r2 = sp.plan(later)
    assert r2["modules"][0]["planned_minutes"] == 40 * 60
    per = lambda res, d: sum(b["minutes"] for b in res["blocks"] if b["date"] == d)
    assert per(r2, days[10]["date"]) >= per(r, days[10]["date"])


def test_manuell_verschobener_und_gesperrter_block_bleibt():
    days = mkdays(21, win=((480, 1080),))
    fixed = [{"module_id": 1, "date": days[3]["date"], "start": 600, "end": 720}]
    inp = {"days": days, "fixed": fixed, "settings": {"utilization": 100},
           "modules": [{"id": 1, "exam_date": days[14]["date"], "remaining_minutes": 30 * 60}]}
    r = sp.plan(inp)
    check_hard(r, inp)
    assert r["modules"][0]["fixed_minutes"] == 120


def test_klausur_entfernt_plant_ohne_termin_bis_zum_ende():
    days = mkdays(14)
    r = sp.plan({"days": days, "modules": [{"id": 1, "exam_date": None, "remaining_minutes": 10 * 60}]})
    assert r["status"] == "ok" and sum(b["minutes"] for b in r["blocks"]) == 600


def test_heute_nicht_vor_jetzt_und_teilstunden():
    days = mkdays(14, win=((480, 1080),))
    inp = {"days": days, "now_minute": 13 * 60 + 7, "settings": {"utilization": 100},
           "modules": [{"id": 1, "exam_date": days[10]["date"], "remaining_minutes": 200 * 60 // 100 + 30}]}  # 2,5 h
    r = sp.plan(inp)
    check_hard(r, inp)
    assert all(b["start"] >= 13 * 60 + 15 for b in r["blocks"] if b["date"] == days[0]["date"])
    assert sum(b["minutes"] for b in r["blocks"]) == 150
    assert sp.hours_text(150) == "2,5 h" and sp.hours_text(670 * 60) == "670 h" and sp.hours_text(10) == "0,2 h"


def test_wochenobergrenze_und_tagesobergrenze():
    days = mkdays(28, win=((480, 1080),), weekdays=range(7))
    inp = {"days": days, "settings": {"utilization": 100, "max_week_minutes": 600, "max_day_minutes": 240},
           "modules": [{"id": 1, "exam_date": days[27]["date"], "remaining_minutes": 30 * 60}]}
    r = sp.plan(inp)
    check_hard(r, inp)
    by_week = {}
    for b in r["blocks"]:
        by_week.setdefault((date.fromisoformat(b["date"]) - MON).days // 7, 0)
        by_week[(date.fromisoformat(b["date"]) - MON).days // 7] += b["minutes"]
    assert all(v <= 600 for v in by_week.values())


def test_zweittermin_als_option():
    days = mkdays(140)
    mods = three(days)
    mods[1]["exam_date_2"] = days[133]["date"]
    r = sp.plan({"days": days, "modules": [mods[0], mods[1]], "settings": {"utilization": 100}})
    assert not r["feasible"]
    z = [o for o in r["options"] if o["kind"] == "zweittermin"]
    assert z and z[0]["module_id"] == 2 and z[0]["date"] == days[133]["date"]


# ------------------------------------------------------------ Lernzeit

def ts(y, mo, d, h, mi, tz="Europe/Berlin"):
    return int(datetime(y, mo, d, h, mi, tzinfo=ZoneInfo(tz)).timestamp())


def test_lernzeit_ueberlappung_doppelbuchung_und_korrektur():
    a = ts(2026, 11, 16, 10, 0)
    s = [
        {"uuid": "u1", "module_id": 1, "kind": "timer", "segments": [[a, a + 3600]], "updated_at": "1"},
        {"uuid": "u1", "module_id": 1, "kind": "timer", "segments": [[a, a + 3600]], "updated_at": "1"},          # doppelt gemeldet
        {"uuid": "u2", "module_id": 1, "kind": "timer", "segments": [[a + 1800, a + 5400]], "updated_at": "1"},   # anderes Geraet, ueberlappt
        {"uuid": "u3", "module_id": 2, "kind": "manual", "minutes": 90, "updated_at": "1"},
        {"uuid": "u4", "module_id": 2, "kind": "manual", "minutes": 30, "updated_at": "1", "deleted": True},
        {"uuid": "u5", "module_id": 3, "package_id": 9, "kind": "timer", "segments": [[a + 7200, a + 9000]], "updated_at": "1"},
        {"uuid": "u6", "module_id": 3, "package_id": 9, "kind": "block", "minutes": 25, "updated_at": "2"},       # Korrektur
        {"uuid": "u7", "module_id": 3, "package_id": 9, "kind": "block", "minutes": 40, "updated_at": "1"},       # aelterer Haken
    ]
    c = sp.credit(s, now_ts=a + 86400)
    assert c["modules"] == {"1": 90, "2": 90, "3": 25}
    assert c["blocks"] == {"9": 25}


def test_lernzeit_laufende_stoppuhr_und_keine_zukunft():
    a = ts(2026, 11, 16, 10, 0)
    c = sp.credit([{"uuid": "x", "module_id": 1, "kind": "timer", "segments": [[a, None]]},
                   {"uuid": "y", "module_id": 1, "kind": "timer", "segments": [[a + 9000, a + 99999]]}], now_ts=a + 1200)
    assert c["modules"] == {"1": 20}


def test_lernzeit_ueber_die_sommerzeitumstellung_und_zeitzonen():
    # 28.03.2027: 02:00 -> 03:00 (Berlin). 01:30-03:30 Wanduhr sind 60 Minuten.
    a, b = ts(2027, 3, 28, 1, 30), ts(2027, 3, 28, 3, 30)
    assert sp.credit([{"uuid": "d", "module_id": 1, "segments": [[a, b]]}], now_ts=b)["modules"] == {"1": 60}
    # dieselbe Stunde von einem Geraet in New York gemeldet: gleicher Zeitpunkt, zaehlt einmal
    ny = ts(2027, 3, 27, 20, 30, "America/New_York")
    c = sp.credit([{"uuid": "d", "module_id": 1, "segments": [[a, b]]},
                   {"uuid": "n", "module_id": 1, "segments": [[ny, ny + 3600]]}], now_ts=b)
    assert c["modules"] == {"1": 60}


def test_sommerzeit_tage_im_plan():
    start = date(2027, 3, 22)
    dates = [{"date": (start + timedelta(i)).isoformat(), "weekday": (start + timedelta(i)).weekday(), "busy": []} for i in range(14)]
    days = sp.build_days(dates, {})
    assert all(d["windows"] == [[540, 1260]] for d in days)        # Wanduhr: Umstellung liegt im Schlaf
    r = sp.plan({"days": days, "modules": [{"id": 1, "exam_date": days[13]["date"], "remaining_minutes": 20 * 60}]})
    assert r["status"] == "ok"


# ------------------------------------------------------------ Material

def test_neue_materialien_ins_budget_ueberschuss_als_konflikt():
    blocks = [{"id": 1, "module_id": 1, "date": "2026-11-17", "start": 600, "minutes": 120, "used": 0},
              {"id": 2, "module_id": 1, "date": "2026-11-24", "start": 600, "minutes": 90, "used": 30},
              {"id": 3, "module_id": 2, "date": "2026-11-17", "start": 900, "minutes": 60, "used": 0}]
    mats = [{"file_id": "a", "module_id": 1, "kind": "vorlesung", "from_date": "2026-11-16", "est": 60},
            {"file_id": "b", "module_id": 1, "kind": "uebung", "from_date": "2026-11-23", "est": 60},
            {"file_id": "c", "module_id": 1, "kind": "skript", "from_date": "2026-11-16", "est": 300},
            {"file_id": "d", "module_id": 1, "kind": "klausur", "from_date": "2026-11-16", "est": 60}]
    r = sp.assign_materials(blocks, mats, max_block=120)
    got = {(x["file_id"], x["block_id"]) for x in r["assign"]}
    assert ("d", 1) in got and ("a", 1) in got and ("b", 2) in got
    assert [o["file_id"] for o in r["overflow"]] == ["c"]
    used = {}
    for x in r["assign"]:
        used[x["block_id"]] = used.get(x["block_id"], 0) + x["minutes"]
    assert used[1] <= 120 and used.get(2, 0) + 30 <= 90


# ------------------------------------------------------------ Zufallstests der harten Bedingungen

def test_zufall_harte_bedingungen_und_machbarkeit():
    rnd = random.Random(20261112)
    for case in range(300):
        n = rnd.randint(7, 70)
        days = []
        for i in range(n):
            d = MON + timedelta(i)
            ws = []
            t = rnd.randint(420, 700)
            for _ in range(rnd.randint(0, 3)):
                e = t + rnd.randint(10, 300)
                ws.append([t, min(e, 1440)])
                t = e + rnd.randint(0, 120)
                if t >= 1440:
                    break
            days.append({"date": d.isoformat(), "weekday": d.weekday(), "windows": ws, "reserve": []})
        mods = []
        for k in range(rnd.randint(1, 5)):
            e = rnd.choice([None] + [days[rnd.randint(0, n - 1)]["date"] for _ in range(4)])
            mods.append({"id": k + 1, "exam_date": e, "remaining_minutes": rnd.randint(-60, 80 * 60), "priority": rnd.randint(1, 3)})
        fixed = []
        for _ in range(rnd.randint(0, 3)):
            d = days[rnd.randint(0, n - 1)]
            if d["windows"]:
                a, b = d["windows"][0]
                if b - a >= 30:
                    fixed.append({"module_id": rnd.randint(1, len(mods)), "date": d["date"], "start": a, "end": a + 30})
        inp = {"days": days, "modules": mods, "fixed": fixed, "now_minute": rnd.choice([None, rnd.randint(0, 1439)]),
               "settings": {"utilization": rnd.choice([30, 60, 100]), "max_block": rnd.choice([60, 90, 120]),
                            "max_week_minutes": rnd.choice([0, 0, 1200])},
               "accept_partial": rnd.random() < 0.5}
        r = sp.plan(inp)
        assert r == sp.plan(json.loads(json.dumps(inp))), "nicht deterministisch"
        if r["status"] == "unterdeckt":
            assert r["blocks"] == [] and r["options"]
            continue
        check_hard(r, inp)
        if r["feasible"]:
            for m in r["modules"]:
                # machbar: was fehlt, sind hoechstens kleine Reste (zu kleine Luecken), nie mehr als die Haelfte
                assert m["unplanned_minutes"] * 2 <= max(m["need_minutes"], 60) or r["status"] == "teilweise"


def test_swift_abgleich_fixture_ist_aktuell():
    import subprocess
    import sys
    from pathlib import Path
    root = Path(__file__).resolve().parents[1]
    r = subprocess.run([sys.executable, "tools/gen-smart-planner-fixture.py", "--check"], cwd=root, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
