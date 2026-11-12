"""Smart Planner 2.0 (Auftrag des Inhabers vom 12.11.2026, docs/SMART-PLANNER-2.md): deterministischer Stundenplaner.

Reine Funktionen auf JSON-Daten, ohne Datenbank, ohne Uhr, ohne KI und nur mit ganzen Zahlen, damit der Swift-Kern
(LocalBackend/Study/SmartPlanner.swift) Zeichen fuer Zeichen dasselbe liefert (Abgleich:
tools/gen-smart-planner-fixture.py -> packages/shared-contracts/fixtures/local-backend/smart-planner.json).

Regeln
- Zeit in Minuten ab Mitternacht (Ortszeit Berlin, Wanduhr); geplant wird in Einheiten zu 15 Minuten.
- Harte Bedingungen: nur in freien Fenstern (Stundenplan, Schlaf, Freizeit, Verpflichtungen, Arbeit, Sperrzeiten,
  feste Bloecke sind schon abgezogen), heute nicht vor jetzt, nie am oder nach dem Klausurtag des Moduls, je Tag
  hoechstens Nutzungsquote x freie Zeit (und Tages-/Wochenobergrenze), nie mehr als noch noetig.
- Machbarkeit: fuer jede Klausur k muss die Summe der Restzeit aller Module mit Klausur bis k in die Kapazitaet bis k
  passen (kumulierte Zwischenfristen). Sonst wird kein scheinbar vollstaendiger Plan gebaut, sondern erklaert, wie
  viel fehlt, mit Optionen (Quote, Freizeit, Ziele, spaeterer Termin, Prioritaeten, Teilplan) – nie eigenmaechtig.
- Wuensche: gleichmaessig verteilt (je Tag Restzeit x Tageskapazitaet / Kapazitaet bis zur Klausur, aufgerundet),
  fruehere Klausuren zuerst bedient, nach einer Klausur frei werdende Zeit geht an die uebrigen, Bloecke 30-120 min
  mit Pause, keine Mini-Reste.
"""
from __future__ import annotations

UNIT = 15
DEFAULTS = {"utilization": 60, "min_block": 30, "max_block": 120, "break": 10, "max_day_minutes": 0, "max_week_minutes": 0}
FRAME_DEFAULTS = {"sleep_minutes": 600, "bedtime": 1380, "leisure_minutes": 120, "learn_days": [0, 1, 2, 3, 4, 5, 6]}
# Reihenfolge, wenn Material nicht ins Stundenbudget passt: Pruefungsvorbereitung zuerst
KIND_RANK = {"klausur": 0, "uebung": 1, "vorlesung": 2, "loesung": 3, "skript": 4}


def ceil_div(a: int, b: int) -> int:
    return -(-a // b)


def hours_text(minutes: int) -> str:
    """"12,5 h" / "320 h": auf eine Nachkommastelle, halbe Zehntel aufgerundet"""
    neg = minutes < 0
    tenths = (abs(minutes) * 10 + 30) // 60
    t = f"{tenths // 10} h" if tenths % 10 == 0 else f"{tenths // 10},{tenths % 10} h"
    return "-" + t if neg else t


# ---------------------------------------------------------------- Intervalle

def merge(intervals: list) -> list[list[int]]:
    out: list[list[int]] = []
    for a, b in sorted([int(x[0]), int(x[1])] for x in intervals if int(x[1]) > int(x[0])):
        if out and a <= out[-1][1]:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return out


def subtract(windows: list, busy: list) -> list[list[int]]:
    out: list[list[int]] = []
    bs = merge(busy)
    for a, b in merge(windows):
        cur = a
        for x, y in bs:
            if y <= cur or x >= b:
                continue
            if x > cur:
                out.append([cur, x])
            cur = max(cur, y)
            if cur >= b:
                break
        if cur < b:
            out.append([cur, b])
    return out


def usable(windows: list, min_block: int, not_before: int | None = None) -> list[list[int]]:
    """Fenster auf das 15-Minuten-Raster (Beginn auf-, Ende abgerundet), heute ab jetzt, ohne zu kurze"""
    out = []
    for a, b in windows:
        if not_before is not None:
            a = max(a, not_before)
        a = ceil_div(a, UNIT) * UNIT
        b = (b // UNIT) * UNIT
        if b - a >= max(min_block, UNIT):
            out.append([a, b])
    return out


# ---------------------------------------------------------------- Tagesrahmen

def day_frame(settings: dict, weekday: int) -> dict | None:
    """Wachzeit ohne Freizeit: Aufstehen = Schlafenszeit + Schlafdauer; Freizeit am Abend vor dem Schlafen.
    None an Tagen ohne Lernen. Schlafenszeit nach Mitternacht: Rahmen bis 24:00."""
    s = {**FRAME_DEFAULTS, **(settings or {})}
    if weekday not in s["learn_days"]:
        return None
    bed, sleep, leisure = int(s["bedtime"]), int(s["sleep_minutes"]), int(s["leisure_minutes"])
    if sleep >= 1440 or sleep < 0 or leisure < 0:
        return None
    wake = (bed + sleep) % 1440
    end = bed if bed > wake else 1440
    if end - leisure <= wake:
        return None
    return {"frame": [wake, end - leisure], "reserve": [end - leisure, end] if leisure > 0 else None}


def build_days(dates: list[dict], settings: dict) -> list[dict]:
    """dates: [{date, weekday, busy: [[s,e]]}] -> Planer-Tage mit freien Fenstern (Rahmen minus Termine minus
    Verpflichtungen/Arbeit je Wochentag) und dem Freizeit-Fenster (fuer die Option "Freizeit senken")"""
    s = {**FRAME_DEFAULTS, **(settings or {})}
    out = []
    for d in dates:
        fr = day_frame(s, d["weekday"])
        commit = [[c["start"], c["end"]] for c in (s.get("commitments") or []) if c.get("weekday") == d["weekday"]]
        if fr is None:
            out.append({"date": d["date"], "weekday": d["weekday"], "windows": [], "reserve": []})
            continue
        busy = list(d.get("busy") or []) + commit
        out.append({"date": d["date"], "weekday": d["weekday"], "windows": subtract([fr["frame"]], busy),
                    "reserve": subtract([fr["reserve"]], busy) if fr["reserve"] else []})
    return out


# ---------------------------------------------------------------- Kapazitaet

def _settings(inp: dict) -> dict:
    s = {**DEFAULTS, **(inp.get("settings") or {})}
    s["utilization"] = min(100, max(1, int(s["utilization"])))
    s["min_block"] = max(UNIT, int(s["min_block"]))
    s["max_block"] = max(s["min_block"], int(s["max_block"]))
    return s


def _windows(inp: dict, s: dict, extra: int = 0) -> list[list[list[int]]]:
    """Nutzbare Fenster je Tag (feste Bloecke abgezogen); `extra`: so viele Minuten der Freizeit dazu"""
    fixed: dict[str, list] = {}
    for b in inp.get("fixed") or []:
        fixed.setdefault(b["date"], []).append([b["start"], b["end"]])
    now = inp.get("now_minute")
    out = []
    for i, d in enumerate(inp["days"]):
        ws = list(d.get("windows") or [])
        if extra:
            left = extra
            for a, b in merge(d.get("reserve") or []):
                take = min(left, b - a)
                if take > 0:
                    ws.append([a, a + take])
                    left -= take
        ws = subtract(merge(ws), fixed.get(d["date"], []))
        out.append(usable(ws, s["min_block"], now if i == 0 and now is not None else None))
    return out


def _caps(days: list[dict], wins: list, s: dict, quota: int) -> list[int]:
    dm = int(s["max_day_minutes"] or 0) // UNIT
    wk = int(s["max_week_minutes"] or 0) // UNIT
    out, used, prev = [], 0, None
    for i, d in enumerate(days):
        c = sum((b - a) // UNIT for a, b in wins[i]) * quota // 100
        if dm:
            c = min(c, dm)
        if wk:
            if prev is None or d["weekday"] <= prev:
                used = 0
            c = min(c, max(0, wk - used))
            used += c
        prev = d["weekday"]
        out.append(c)
    return out


def _prefix(cap: list[int]) -> list[int]:
    p = [0]
    for c in cap:
        p.append(p[-1] + c)
    return p


# ---------------------------------------------------------------- Module

def _modules(inp: dict) -> list[dict]:
    days = inp["days"]
    h = len(days)
    index = {d["date"]: i for i, d in enumerate(days)}
    first = days[0]["date"] if days else ""
    last = days[-1]["date"] if days else ""
    fixed = inp.get("fixed") or []
    out = []
    for k, m in enumerate(inp.get("modules") or []):
        exam = m.get("exam_date")
        if exam is None:
            e = h
        elif h == 0 or exam <= first:
            e = 0
        elif exam in index:
            e = index[exam]
        elif exam > last:
            e = h
        else:
            raise ValueError(f"Klausurtag fehlt in den Tagen: {exam}")
        fx = sum(b["end"] - b["start"] for b in fixed
                 if b.get("module_id") == m["id"] and b.get("counts", True) and (exam is None or b["date"] < exam))
        need = max(0, int(m.get("remaining_minutes") or 0) - fx)
        out.append({"id": m["id"], "order": k, "E": e, "rem": ceil_div(need, UNIT) if e > 0 else 0, "need": need,
                    "fixed": fx, "exam": exam, "priority": int(m.get("priority") or 2),
                    "exam_date_2": m.get("exam_date_2"), "passed": exam is not None and e == 0})
    return out


def _deadlines(mods: list[dict], p: list[int], rem: dict | None = None) -> list[dict]:
    rem = rem if rem is not None else {m["order"]: m["rem"] for m in mods}
    es = sorted({m["E"] for m in mods if m["E"] > 0 and rem[m["order"]] > 0})
    out = []
    for e in es:
        need = sum(rem[m["order"]] for m in mods if 0 < m["E"] <= e)
        out.append({"E": e, "need": need, "available": p[e], "missing": max(0, need - p[e]),
                    "modules": [m["id"] for m in mods if m["E"] == e and rem[m["order"]] > 0]})
    return out


def _feasible(mods: list[dict], p: list[int], rem: dict | None = None) -> bool:
    return all(x["missing"] == 0 for x in _deadlines(mods, p, rem))


# ---------------------------------------------------------------- Verteilen

def _place(ws: list, wants: list, min_u: int, max_u: int, brk: int) -> list[tuple]:
    """Tagesmengen in die Fenster: der Reihe nach, Stuecke hoechstens max_u, keine Reste unter min_u, wenn es sich
    vermeiden laesst; Pausen nur aus dem Spielraum des Fensters (kostet nie Lernzeit)"""
    freeu = [(b - a) // UNIT for a, b in ws]
    pieces: list[list] = [[] for _ in ws]
    for key, units in wants:
        left = units
        for k in range(len(ws)):
            while left > 0 and freeu[k] > 0:
                p = min(left, max_u, freeu[k])
                if p < left and left - p < min_u and left - min_u >= min_u:
                    p = min(p, left - min_u)
                if p < min_u and p < left:
                    break
                pieces[k].append([key, p])
                freeu[k] -= p
                left -= p
            if left == 0:
                break
    out = []
    for k, (a, b) in enumerate(ws):
        ps = pieces[k]
        if not ps:
            continue
        slack = (b - a) - sum(p for _, p in ps) * UNIT
        gap = min(brk, slack // (len(ps) - 1)) // 5 * 5 if len(ps) > 1 else 0
        t = a
        for key, p in ps:
            out.append((key, t, t + p * UNIT))
            t += p * UNIT + gap
    return out


def _allocate(inp: dict, s: dict, mods: list[dict], wins: list, cap: list[int], p: list[int]) -> tuple[list, dict, dict]:
    days = inp["days"]
    min_u, max_u = s["min_block"] // UNIT, s["max_block"] // UNIT
    rem = {m["order"]: m["rem"] for m in mods}
    planned: dict[int, int] = {}
    blocks = []
    for d in range(len(days)):
        act = sorted([m for m in mods if rem[m["order"]] > 0 and m["E"] > d], key=lambda m: (m["E"], m["order"]))
        c = cap[d]
        if not act or c == 0:
            continue
        x = {}
        for m in act:
            cf = p[m["E"]] - p[d]
            r = rem[m["order"]]
            x[m["order"]] = min(r, ceil_div(r * c, cf)) if cf > 0 else 0
        for m in act:
            o = m["order"]
            if 0 < x[o] < min_u and rem[o] > x[o]:
                x[o] = min(min_u, rem[o])
        left = c
        for m in act:
            o = m["order"]
            x[o] = min(x[o], left)
            left -= x[o]
        # Zwischenfristen: was heute mindestens fuer die Klausuren bis E noetig ist, damit es danach noch passt
        for e in sorted({m["E"] for m in act}):
            group = [m for m in act if m["E"] <= e]
            need = sum(rem[m["order"]] for m in group) - (p[e] - p[d + 1])
            delta = need - sum(x[m["order"]] for m in group)
            if delta <= 0:
                continue
            take = min(delta, c - sum(x.values()))
            for m in reversed(act):
                if take >= delta:
                    break
                if m["E"] > e:
                    t = min(x[m["order"]], delta - take)
                    x[m["order"]] -= t
                    take += t
            for m in group:
                if take == 0:
                    break
                o = m["order"]
                a = min(take, rem[o] - x[o])
                x[o] += a
                take -= a
        wants = [(m["order"], x[m["order"]]) for m in act if x[m["order"]] > 0]
        for o, a, b in _place(wins[d], wants, min_u, max_u, int(s["break"])):
            rem[o] -= (b - a) // UNIT
            planned[o] = planned.get(o, 0) + (b - a)
            blocks.append({"module_id": mods[o]["id"], "date": days[d]["date"], "start": a, "end": b, "minutes": b - a})
    blocks.sort(key=lambda b: (b["date"], b["start"]))
    return blocks, rem, planned


# ---------------------------------------------------------------- Optionen bei Unterdeckung

def _reduce_goals(mods: list[dict], p: list[int]) -> dict:
    rem = {m["order"]: m["rem"] for m in mods}
    cut = {m["order"]: 0 for m in mods}
    for e in sorted({m["E"] for m in mods if m["E"] > 0}):
        group = sorted([m for m in mods if 0 < m["E"] <= e], key=lambda m: (m["E"], m["order"]))
        miss = sum(rem[m["order"]] for m in group) - p[e]
        if miss <= 0:
            continue
        total = sum(rem[m["order"]] for m in group)
        parts = {m["order"]: miss * rem[m["order"]] // total for m in group}
        left = miss - sum(parts.values())
        for m in group:
            if left == 0:
                break
            if rem[m["order"]] - parts[m["order"]] > 0:
                parts[m["order"]] += 1
                left -= 1
        for o, v in parts.items():
            rem[o] -= v
            cut[o] += v
    return cut


def _options(inp: dict, s: dict, mods: list[dict], p: list[int]) -> list[dict]:
    days = inp["days"]
    out = []
    quota = s["utilization"]
    # 1. Nutzungsquote
    wins = _windows(inp, s)
    for q in list(range(quota + 5, 100, 5)) + [100]:
        if q <= quota:
            continue
        if _feasible(mods, _prefix(_caps(days, wins, s, q))):
            out.append({"kind": "nutzungsquote", "value": q,
                        "text": f"Nutzungsquote der freien Zeit von {quota} % auf {q} % erhöhen"})
            break
    else:
        if quota < 100:
            out.append({"kind": "nutzungsquote", "value": None,
                        "text": "Auch 100 % der freien Zeit reichen allein nicht."})
    # 2. Freizeit senken (je Lerntag bis zur ganzen Freizeit, in 15-Minuten-Schritten)
    most = max([sum(b - a for a, b in merge(d.get("reserve") or [])) for d in days] or [0])
    found = None
    for extra in range(UNIT, most + 1, UNIT):
        if _feasible(mods, _prefix(_caps(days, _windows(inp, s, extra), s, quota))):
            found = extra
            break
    if found is not None:
        out.append({"kind": "freizeit", "minutes_per_day": found,
                    "text": f"Freizeit an Lerntagen um {hours_text(found)} pro Tag senken"})
    elif most > 0:
        out.append({"kind": "freizeit", "minutes_per_day": None, "text": "Auch ohne Freizeit reicht die Zeit allein nicht."})
    # 3. Ziele senken
    cut = _reduce_goals(mods, p)
    cuts = [{"module_id": m["id"], "minutes": cut[m["order"]] * UNIT} for m in mods if cut[m["order"]] > 0]
    if cuts:
        out.append({"kind": "ziele", "cuts": cuts,
                    "text": "Ziele senken: " + ", ".join(hours_text(c["minutes"]) for c in cuts) + " weniger"})
    # 4. Spaeterer Termin: Zweittermin, wenn er reicht, sonst der frueheste machbare Tag im Zeitraum
    blocked = {str(mid) for x in _deadlines(mods, p) if x["missing"] > 0 for mid in x["modules"]}
    index = {d["date"]: i for i, d in enumerate(days)}
    for m in mods:
        if str(m["id"]) not in blocked or m["exam"] is None:
            continue

        def ok(e2: int) -> bool:
            return _feasible([dict(x, E=e2) if x["order"] == m["order"] else x for x in mods], p)
        second = m.get("exam_date_2")
        if second in index and index[second] > m["E"] and ok(index[second]):
            out.append({"kind": "zweittermin", "module_id": m["id"], "date": second,
                        "text": f"Zweittermin am {second} schreiben"})
            continue
        e2 = next((e for e in range(m["E"] + 1, len(days)) if ok(e)), None)
        if e2 is not None:
            out.append({"kind": "spaeterer_termin", "module_id": m["id"], "date": days[e2]["date"],
                        "text": f"Klausur frühestens am {days[e2]['date']} schreiben"})
    # 5. Prioritaeten: wichtigste Module voll, die uebrigen nicht
    order = sorted(mods, key=lambda m: (-m["priority"], m["E"], m["order"]))
    rem = {m["order"]: 0 for m in mods}
    covered, dropped = [], []
    for m in order:
        if m["rem"] == 0:
            continue
        rem[m["order"]] = m["rem"]
        if _feasible(mods, p, rem):
            covered.append(m["id"])
        else:
            rem[m["order"]] = 0
            dropped.append(m["id"])
    if covered and dropped:
        out.append({"kind": "prioritaeten", "covered": covered, "dropped": dropped,
                    "text": "Nach Priorität planen: wichtigste Module voll, die übrigen nur mit Restzeit"})
    out.append({"kind": "teilplan", "text": "Trotzdem planen: Teilplan mit der vorhandenen Zeit (fehlende Stunden bleiben offen)"})
    return out


# ---------------------------------------------------------------- Planen

def plan(inp: dict) -> dict:
    """Eingabe: {days: [{date, weekday, windows, reserve}], now_minute, modules: [{id, exam_date, remaining_minutes,
    priority, exam_date_2}], fixed: [{module_id, date, start, end, counts}], settings, accept_partial}"""
    s = _settings(inp)
    days = inp["days"]
    mods = _modules(inp)
    wins = _windows(inp, s)
    cap = _caps(days, wins, s, s["utilization"])
    p = _prefix(cap)
    dl = _deadlines(mods, p)
    feasible = all(x["missing"] == 0 for x in dl)
    deadlines = [{"date": days[x["E"]]["date"] if x["E"] < len(days) else None, "need_minutes": x["need"] * UNIT,
                  "available_minutes": x["available"] * UNIT, "missing_minutes": x["missing"] * UNIT,
                  "modules": x["modules"]} for x in dl]
    out = {"status": "ok", "feasible": feasible, "deadlines": deadlines, "blocks": [], "options": [],
           "message": None, "capacity_minutes": [c * UNIT for c in cap]}
    if not feasible:
        worst = max(dl, key=lambda x: (x["missing"], x["E"]))
        out["status"] = "unterdeckt"
        out["missing_minutes"] = worst["missing"] * UNIT
        out["message"] = (f"{hours_text(worst['need'] * UNIT)} nötig, {hours_text(worst['available'] * UNIT)} verfügbar, "
                          f"fehlen {hours_text(worst['missing'] * UNIT)}")
        out["options"] = _options(inp, s, mods, p)
        if not inp.get("accept_partial"):
            out["modules"] = [_mod_out(m, 0, m["rem"]) for m in mods]
            return out
        out["status"] = "teilplan"
    blocks, rem, planned = _allocate(inp, s, mods, wins, cap, p)
    out["blocks"] = blocks
    out["modules"] = [_mod_out(m, planned.get(m["order"], 0), rem[m["order"]]) for m in mods]
    if feasible and any(rem[m["order"]] > 0 for m in mods):
        out["status"] = "teilweise"
        miss = sum(rem[m["order"]] for m in mods) * UNIT
        out["message"] = f"{hours_text(miss)} passen nicht in die freien Fenster (zu kleine Lücken)."
    return out


def _mod_out(m: dict, planned: int, rem_units: int) -> dict:
    return {"id": m["id"], "need_minutes": m["need"], "fixed_minutes": m["fixed"], "planned_minutes": planned,
            "unplanned_minutes": rem_units * UNIT if m["E"] > 0 else 0, "exam_passed": m["passed"]}


# ---------------------------------------------------------------- Lernzeit, Abgleich, Material, Prognose

def credit(sessions: list[dict], now_ts: int) -> dict:
    """Anerkannte Lernzeit je Modul und je Block. Dieselbe uuid zaehlt einmal (die zuletzt geaenderte), geloeschte
    nicht; Zeitabschnitte (Stoppuhr, eingetragene Uhrzeiten) zaehlen ueberlappend nur einmal, auch ueber Geraete und
    Module hinweg (frueher begonnener Abschnitt zuerst); ein abgehakter Block mit Minuten ersetzt die Stoppuhr-Zeit
    dieses Blocks (Korrektur), je Block zaehlt nur der letzte Haken; offene Abschnitte laufen bis jetzt, nichts in der
    Zukunft."""
    latest: dict[str, dict] = {}
    for x in sessions:
        u = x["uuid"]
        if u not in latest or (x.get("updated_at") or "", u) > (latest[u].get("updated_at") or "", u):
            latest[u] = x
    live = [x for x in latest.values() if not x.get("deleted")]
    block_last: dict = {}
    for x in live:
        if x.get("kind") == "block" and x.get("package_id") is not None:
            k = str(x["package_id"])
            if k not in block_last or (x.get("updated_at") or "", x["uuid"]) > (block_last[k].get("updated_at") or "", block_last[k]["uuid"]):
                block_last[k] = x
    by_module: dict[str, int] = {}
    by_block: dict[str, int] = {}
    segs = []
    for x in live:
        pk = str(x["package_id"]) if x.get("package_id") is not None else None
        if x.get("kind") == "block":
            if pk is None or block_last[pk]["uuid"] != x["uuid"]:
                continue
            m = max(0, int(x.get("minutes") or 0)) * 60
            by_module[str(x["module_id"])] = by_module.get(str(x["module_id"]), 0) + m
            by_block[pk] = by_block.get(pk, 0) + m
            continue
        if pk is not None and pk in block_last:
            continue
        if x.get("segments"):
            for sg in x["segments"]:
                a = int(sg[0])
                b = int(sg[1]) if sg[1] is not None else now_ts
                b = min(b, now_ts)
                if b > a:
                    segs.append((a, b, x["uuid"], str(x["module_id"]), pk))
        else:
            m = max(0, int(x.get("minutes") or 0)) * 60
            by_module[str(x["module_id"])] = by_module.get(str(x["module_id"]), 0) + m
            if pk is not None:
                by_block[pk] = by_block.get(pk, 0) + m
    covered = None
    for a, b, _u, mid, pk in sorted(segs):
        start = a if covered is None else max(a, covered)
        if b > start:
            by_module[mid] = by_module.get(mid, 0) + (b - start)
            if pk is not None:
                by_block[pk] = by_block.get(pk, 0) + (b - start)
        covered = b if covered is None else max(covered, b)
    return {"modules": {k: v // 60 for k, v in sorted(by_module.items())},
            "blocks": {k: v // 60 for k, v in sorted(by_block.items())}}


def diff(existing: list[dict], new: list[dict]) -> dict:
    """Geringste Aenderung: gleiche Bloecke (Modul, Tag, Beginn, Ende) behalten ihre ID"""
    pool: dict[tuple, list] = {}
    for b in sorted(existing, key=lambda b: (b["date"], b["start"], b["id"])):
        pool.setdefault((str(b["module_id"]), b["date"], b["start"], b["end"]), []).append(b["id"])
    keep, add = [], []
    for b in new:
        ids = pool.get((str(b["module_id"]), b["date"], b["start"], b["end"]))
        if ids:
            keep.append(ids.pop(0))
        else:
            add.append(b)
    remove = sorted([i for ids in pool.values() for i in ids])
    return {"keep": sorted(keep), "remove": remove, "add": add}


def assign_materials(blocks: list[dict], materials: list[dict], max_block: int = 120) -> dict:
    """Material ins Stundenbudget: je Datei (lange in hoechstens 4 Teilen) der erste Block desselben Moduls ab ihrer
    Lehrwoche mit genug freiem Budget; was nicht passt, bleibt draussen (Konflikt, nach Wichtigkeit) – das Budget
    waechst nie. blocks: [{id, module_id, date, minutes, used}], materials: [{file_id, module_id, kind, from_date, est}]"""
    bl = sorted([dict(b) for b in blocks], key=lambda b: (b["date"], b.get("start") or 0, b["id"]))
    mats = sorted(materials, key=lambda f: (f.get("from_date") or "", KIND_RANK.get(f.get("kind"), 5), f["file_id"]))
    assign, overflow = [], []
    for f in mats:
        est = max(UNIT, int(f.get("est") or 45))
        n = min(4, ceil_div(est, max(UNIT, max_block)))
        part = ceil_div(est, n)
        got = []
        for k in range(n):
            for b in bl:
                if str(b["module_id"]) != str(f["module_id"]) or b["date"] < (f.get("from_date") or ""):
                    continue
                if b["minutes"] - b["used"] >= part:
                    b["used"] += part
                    got.append({"file_id": f["file_id"], "block_id": b["id"], "part": k + 1, "parts": n, "minutes": part})
                    break
            else:
                break
        if len(got) == n:
            assign += got
        else:
            for g in got:
                for b in bl:
                    if b["id"] == g["block_id"]:
                        b["used"] -= g["minutes"]
            overflow.append({"file_id": f["file_id"], "module_id": f["module_id"], "kind": f.get("kind"), "est": est})
    overflow.sort(key=lambda f: (KIND_RANK.get(f.get("kind"), 5), f["file_id"]))
    return {"assign": assign, "overflow": overflow}


def module_stats(m: dict) -> dict:
    """Ziel, gelernt, fehlt, Tage, Stunden je Woche, Prognose. m: {target_minutes, learned_minutes, lecture_minutes,
    days_left (None ohne Termin), planned_minutes (kuenftige Bloecke vor der Klausur), adherence (Prozent der
    geplanten Zeit der letzten 14 Tage, die gelernt wurde; None ohne Verlauf)}"""
    target = max(0, int(m.get("target_minutes") or 0))
    learned = max(0, int(m.get("learned_minutes") or 0))
    lecture = max(0, int(m.get("lecture_minutes") or 0))
    remaining = max(0, target - learned - lecture)
    days = m.get("days_left")
    per_week = None
    if days is not None and days > 0:
        per_week = ceil_div(remaining * 7, days)
    adh = m.get("adherence")
    adh = 100 if adh is None else max(0, min(100, int(adh)))
    planned = max(0, int(m.get("planned_minutes") or 0))
    forecast = learned + lecture + planned * adh // 100
    pct = forecast * 100 // target if target else 100
    if remaining == 0:
        status = "erreicht"
    elif days is not None and days <= 0:
        status = "vorbei"
    elif pct >= 100:
        status = "auf_kurs"
    elif pct >= 90:
        status = "knapp"
    else:
        status = "gefaehrdet"
    return {"target_minutes": target, "learned_minutes": learned, "lecture_minutes": lecture,
            "remaining_minutes": remaining, "days_left": days, "per_week_minutes": per_week,
            "planned_minutes": planned, "forecast_minutes": forecast, "forecast_percent": pct, "status": status}
