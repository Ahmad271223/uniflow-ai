"""`GET /api/exam-registration` am PC (Windows-App/Einzelplatz, 05.11.2026): gleiche Antwort wie der Swift-Kern
(ExamRegistration/ExamRegistrationAPI.swift, docs/PRUEFUNGSANMELDUNG-2026-11-05.md). Meldezeitraum des Studiengangs
(app/exam_registration.py), "Diese Prüfungen solltest du anmelden" aus dem persoenlichen Studienverlauf
(app/study_plan.py), Klausurtermine aus allen Quellen (app/exams.py), QIS-Noten (bestanden -> nicht gelistet, Vermerk
AN -> angemeldet) und die gelesenen Zeilen von "Info über angemeldete Prüfungen" (app/qis_registrations.py, im normalen
QIS-Abruf). Rechnet nur; angemeldet wird nie von der App.

Erinnerungen: Die Windows-App hat (noch) keine Systemmitteilungen; statt "7 und 2 Tage vor Ende, erster Tag" um 9:00
zeigt die Oberflaeche an diesen Tagen einen Hinweis in der App (exam-registration.js). `reminders` liefert dieselben
Zeitpunkte wie `ExamRegistrationReminders.plan` (Kennungen ohne Container).
"""
from __future__ import annotations

from datetime import date, timedelta

from fastapi import APIRouter

from . import config, db, exam_registration as periods, exams, qis_registrations, study_plan

router = APIRouter(prefix="/api/exam-registration", tags=["exam-registration"])

HINT = ("Tippe im QIS auf „Prüfungsanmeldung/-abmeldung“, wähle die Prüfung und bestätige selbst. StudiNow füllt nichts "
        "aus und schickt nichts ab.")
DISCLAIMER = ("Verbindlich sind die Fristen im QIS und auf den Seiten des Prüfungsamts. Module aus anderen Studiengängen "
              "können andere Zeiträume haben.")
WARN_DAYS = 3
SUGGEST_STATUSES = {"offen", "geplant", "nicht_bestanden", "angemeldet"}
WD = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]


def vbp(exam) -> bool:
    e = str(exam or "").lower()
    return "vbp" in e or "veranstaltungsbegleitend" in e


def no_exam(exam) -> bool:
    e = str(exam or "").lower().strip()
    return e in ("keine", "-", "–") or e.startswith("keine ")


def withdraw_days(exam, rules: list[dict]) -> tuple[int, str] | None:
    e = str(exam or "").lower()
    if vbp(exam):
        return None
    form = "Mündliche Prüfung" if ("mündlich" in e or "muendlich" in e) else ("Klausur" if (not e or "klausur" in e) else None)
    if not form:
        return None
    r = next((x for x in rules if x.get("form") == form), None)
    if not r or not isinstance(r.get("withdraw_days_before"), int):
        return None
    return r["withdraw_days_before"], r.get("text") or ""


def exams_by_key(items: list[dict]) -> dict[str, list[dict]]:
    out: dict[str, list[dict]] = {}
    for it in items:
        names = [n for n in (it.get("module_name"), it.get("course_title")) if n]
        t, w = it.get("title") or "", it.get("kind_label") or ""
        if w and t.startswith(w + " "):
            names.append(t[len(w) + 1:])
        keys: set[str] = set()
        for n in names:
            k = study_plan.name_key(n)
            if k and k not in keys:
                keys.add(k)
                out.setdefault(k, []).append(it)
    return out


def _university(conn) -> str:
    r = conn.execute("SELECT value FROM settings WHERE key='university'").fetchone()
    if r and r[0]:
        return str(r[0])
    try:
        from . import universities
        return universities.current_key()
    except Exception:  # noqa: BLE001
        return "luh"


def response(conn, today: str, data: dict | None = None, source=None) -> dict:
    data = data or periods.load_data()
    university = _university(conn)
    rules = [r for r in data.get("rules") or [] if isinstance(r, dict)]
    if university != data.get("university", "luh"):
        return {"supported": False, "university": university, "show_card": False, "suggestions": [], "registered": [],
                "warnings": [], "periods": [], "qis_url": None, "hint": HINT, "disclaimer": DISCLAIMER}
    day = date.fromisoformat(today)

    settings, grades = study_plan.load_settings(conn), study_plan.grade_rows(conn)
    source = source or study_plan.DbCatalogSource(conn)
    cat, _ = study_plan.pick_catalog(source.catalogs(), settings, grades)
    full = study_plan.compute(cat, grades, settings, today) if cat is not None else None

    name = (cat or {}).get("program") or study_plan.program_of(grades)
    degree = (cat or {}).get("degree")
    program = periods.find_program(data, name, degree)
    window = periods.window_state(data, program, today, "meldung")
    term_name = window["term"] if window else study_plan.term_name(study_plan.current_term(today))
    vw = periods.window_state(data, program, today, "vbp_meldung")
    vbp_window = vw if vw and vw["term"] == term_name else None
    term = study_plan.parse_term(term_name) or study_plan.current_term(today)

    upcoming = exams.upcoming(conn, day)
    index = exams_by_key(upcoming)
    regs = qis_registrations.rows(conn)
    app_modules: dict[str, list[int]] = {}
    for r in db.rows(conn, "SELECT id, name FROM modules ORDER BY id"):
        app_modules.setdefault(study_plan.name_key(r["name"]), []).append(r["id"])

    def registration(code: str | None, key: str) -> dict | None:
        for r in regs:
            if not r["registered"]:
                continue
            if code and r.get("pruefungsnr") and r["pruefungsnr"].strip() == code:
                return r
            if key and study_plan.name_key(r.get("text") or "") == key:
                return r
        return None

    def exam_fields(key: str, exam, reg: dict | None, o: dict) -> None:
        e = (index.get(key) or [None])[0]
        d, t = (e or {}).get("date"), (e or {}).get("time")
        if d is None and reg and reg.get("iso_date") and reg["iso_date"] >= today:
            d, t = reg["iso_date"], reg.get("clock")
        o["exam_date"] = d
        o["exam_time"] = t or None
        o["exam_room"] = (e or {}).get("room") if e else (reg or {}).get("room")
        o["exam_source"] = (e or {}).get("source_label") if e else ("aus QIS (angemeldet)" if d and reg else None)
        until = (reg or {}).get("iso_withdraw")
        rule = None
        w = withdraw_days(exam, rules)
        if w:
            n, rule = w
            if until is None and d:
                until = (date.fromisoformat(d) - timedelta(days=n)).isoformat()
        o["withdraw_until"] = until
        o["withdraw_rule"] = rule

    suggestions: list[dict] = []
    order: dict[str, int] = {}
    plan_message = None
    if full is not None:
        start = study_plan.parse_term(full["plan"].get("start_term")) or term
        for i, m in enumerate(full["by_id"].values()):
            mid = m["id"]
            st = full["state"].get(mid)
            if not st or st.get("term") != term or st.get("status") not in SUGGEST_STATUSES:
                continue
            exam = m.get("exam") if isinstance(m.get("exam"), str) else None
            if m.get("kind") == "abschluss" or no_exam(exam):
                continue
            key = study_plan.name_key(m.get("title"))
            code = m.get("code").strip() if isinstance(m.get("code"), str) else None
            reg = registration(code, key)
            o = {"id": mid, "title": m.get("title"), "lp": study_plan.lp_of(m), "exam": m.get("exam"), "kind": m.get("kind"),
                 "code": m.get("code"), "status": st["status"], "fachsemester": term - start + 1,
                 "period": "vbp" if vbp(exam) else "meldung", "last_attempt": study_plan.last_attempt(st),
                 "app_module_ids": app_modules.get(key, [])}
            if st["status"] == "nicht_bestanden":
                nxt = (st.get("attempt") or 1) + 1
                o["reason_kind"] = "wiederholung"
                o["reason"] = f"Wiederholung – {nxt}. Versuch" + (f" (nicht bestanden im {st['moved_from']})" if st.get("moved_from") else "")
            elif st.get("moved_from") and "nachholen" in (st.get("reason") or ""):
                o["reason_kind"] = "nachholen"
                o["reason"] = f"nachholen – laut Plan im {st['moved_from']}"
            else:
                o["reason_kind"] = "plan"
                o["reason"] = f"laut deinem Plan im {term - start + 1}. Semester"
            if st["status"] == "angemeldet":
                o["registered"], o["registered_via"] = True, "notenspiegel"
            elif reg is not None:
                o["registered"], o["registered_via"] = True, "qis_info"
            else:
                o["registered"], o["registered_via"] = False, None
            exam_fields(key, exam, reg, o)
            order[mid] = i
            suggestions.append(o)
    else:
        plan_message = ("Ohne Studienverlauf kennt StudiNow deinen Plan nicht. Gezeigt werden die kommenden Klausuren "
                        "deiner Module.")
        seen: set[str] = set()
        for i, e in enumerate(upcoming):
            title = e.get("module_name") or e.get("course_title") or e.get("title") or "Prüfung"
            key = study_plan.name_key(title)
            if not key or key in seen:
                continue
            seen.add(key)
            reg = registration(None, key)
            via_qis = any(s.get("kind") == "qis" for s in e.get("sources") or [])
            eid = e.get("id") or f"exam-{i}"
            o = {"id": eid, "title": title, "lp": None, "exam": None, "kind": None, "code": None, "status": None,
                 "fachsemester": None, "period": "meldung", "last_attempt": False,
                 "app_module_ids": [e["module_id"]] if isinstance(e.get("module_id"), int) else [],
                 "reason_kind": "klausur", "reason": "Klausurtermin bekannt", "registered": via_qis or reg is not None,
                 "registered_via": "notenspiegel" if via_qis else ("qis_info" if reg is not None else None)}
            exam_fields(key, None, reg, o)
            order[eid] = i
            suggestions.append(o)
    suggestions.sort(key=lambda o: (bool(o["registered"]), o.get("exam_date") or "9999", order.get(o["id"], 0)))
    open_ = [o for o in suggestions if not o["registered"]]
    open_main = [o for o in open_ if o["period"] != "vbp"]
    open_vbp = [o for o in open_ if o["period"] == "vbp"]

    def end_text(w: dict) -> str:
        return "heute" if w["days_left"] == 0 else "morgen" if w["days_left"] == 1 else f"in {w['days_left']} Tagen"

    def plural(n: int) -> str:
        return "1 geplante Prüfung ist" if n == 1 else f"{n} geplante Prüfungen sind"

    warnings = []
    if window and window["phase"] == "open" and window["days_left"] <= WARN_DAYS and open_main:
        warnings.append({"kind": "ende", "tone": "bad",
                         "text": f"Die Anmeldung endet {end_text(window)}. {plural(len(open_main))} noch nicht angemeldet."})
    if vbp_window and vbp_window["phase"] == "open" and vbp_window["days_left"] <= WARN_DAYS and open_vbp:
        warnings.append({"kind": "vbp_ende", "tone": "bad",
                         "text": f"Die Anmeldung für VbP endet {end_text(vbp_window)}. {plural(len(open_vbp))} noch nicht angemeldet."})

    run = qis_registrations.last_run(conn) or {}
    show_card = bool(window and window["phase"] in ("open", "soon")) or bool(vbp_window and vbp_window["phase"] == "open" and open_vbp)
    general = (data.get("general") or {}).get("url")
    pname = periods.program_name(name) if name else None
    out = {
        "supported": True, "university": university,
        "program": {"name": pname, "degree": degree, "slug": program["slug"], "url": program["url"],
                    "verified": program.get("table") is not None, "variant": program.get("variant")} if program else None,
        "program_name": pname,
        "source": {"url": program["url"] if program else general, "general_url": general,
                   "checked_at": (program or {}).get("checked_at") or data.get("checked_at")},
        "term": term_name, "window": window, "vbp_window": vbp_window,
        "periods": [{k: p.get(k) for k in ("kind", "n", "label", "start", "end")}
                    for p in periods.term_periods(data, program, window["term"] if window else None)],
        "show_card": show_card, "plan_available": full is not None, "plan_message": plan_message,
        "suggestions": suggestions, "open_count": len(open_), "registered_count": len(suggestions) - len(open_),
        "registered": [{"pruefungsnr": r.get("pruefungsnr"), "text": r.get("text"), "semester": r.get("semester"),
                        "date": r["iso_date"], "date_text": r.get("datum"), "time": r["clock"], "room": r.get("room"),
                        "status": r.get("status"), "registered": r["registered"], "withdraw_until": r["iso_withdraw"],
                        "form": r.get("form")} for r in regs],
        "registrations_checked_at": run.get("at"), "registrations_ok": run.get("ok"),
        "registrations_message": run.get("message"),
        "warnings": warnings, "qis_url": data.get("qis_menu"), "hint": HINT,
        "rules": [r.get("text") for r in rules], "disclaimer": DISCLAIMER,
    }
    out["reminders"] = reminders(out)
    return out


def _when(iso: str) -> str:
    """"So, 22.11." wie DueReminders.when"""
    d = date.fromisoformat(iso)
    return f"{WD[d.weekday()]}, {d.day:02d}.{d.month:02d}."


def reminders(resp: dict) -> list[dict]:
    """Zeitpunkte wie `ExamRegistrationReminders.plan` (9:00 Berlin; am ersten Tag, 7 und 2 Tage vor dem Ende; VbP nur,
    wenn dort etwas fehlt). Ohne Systemmitteilungen zeigt die Oberflaeche sie ab dem Tag als Hinweis."""
    if not resp.get("supported"):
        return []
    sugg = resp.get("suggestions") or []
    out = []
    for key, period in (("window", "meldung"), ("vbp_window", "vbp")):
        w = resp.get(key)
        if not isinstance(w, dict) or not w.get("start") or not w.get("end"):
            continue
        missing = sum(1 for s in sugg if not s.get("registered") and (s.get("period") or "meldung") == period)
        if period == "vbp" and missing == 0:
            continue
        what = "Prüfungsanmeldung (VbP)" if period == "vbp" else "Prüfungsanmeldung"
        count = "" if missing == 0 else (" · 1 Prüfung laut Plan noch nicht angemeldet" if missing == 1
                                         else f" · {missing} Prüfungen laut Plan noch nicht angemeldet")
        body = f"{w['term']}: bis {_when(w['end'])}{count}"
        start, end = date.fromisoformat(w["start"]), date.fromisoformat(w["end"])
        slots = [("start", start, f"{what} beginnt heute")]
        if end - timedelta(days=7) > start:
            slots.append(("d7", end - timedelta(days=7), f"{what}: noch 7 Tage"))
        if end - timedelta(days=2) > start:
            slots.append(("d2", end - timedelta(days=2), f"{what} endet übermorgen"))
        base = f"examreg.{periods.slugify(w['term'])}.{'vbp' if period == 'vbp' else 'meldung'}{w.get('n', 1)}."
        for tag, d, title in slots:
            out.append({"id": base + tag, "day": d.isoformat(), "time": "09:00", "until": w["end"], "title": title,
                        "body": body, "route": "#/studyplan"})
    out.sort(key=lambda r: (r["day"], r["id"]))
    return out


@router.get("")
def api_exam_registration():
    if config.is_hosted():
        # im Dienst kein QIS-Abruf und keine Info-Seite: wie die iPad-App "nur auf dem Geraet"
        return {"supported": False, "university": config.university(), "show_card": False, "suggestions": [], "registered": [],
                "warnings": [], "periods": [], "qis_url": None, "hint": HINT, "disclaimer": DISCLAIMER, "reminders": []}
    with db.cursor() as conn:
        return response(conn, study_plan_today())


def study_plan_today() -> str:
    from . import study
    return study.today().isoformat()
