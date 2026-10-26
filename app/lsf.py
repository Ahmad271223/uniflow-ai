"""LSF der Uni Hildesheim (HIS QIS): persoenlicher Stundenplan per iCal-Export.

Ablauf (nur lesend):
 1. Anmeldung ueber das zentrale CAS (Link "Anmelden mit UNI-Account (SSO)" der LSF-Startseite).
 2. Seite "Persoenlicher Stundenplan" oeffnen und den iCal-Link des ganzen Plans lesen
    (moduleCall=iCalendarPlan, enthaelt nur die Termin-Nummern).
 3. Die ICS-Datei holen und als Serien in den Stundenplan der App uebernehmen (Quelle 'lsf').
Vorlesungsfreie Tage (EXDATE) werden als Ausfall eingetragen. Nichts im LSF wird geaendert:
keine Klicks auf "Anmelden/abmelden" oder "Jetzt anmelden".
"""
from __future__ import annotations

import json
import re
from typing import Callable

from . import cas, db, timetable
from .universities import HILDESHEIM_CAS, LSF_BASE

LSF_START = f"{LSF_BASE}/qisserver/rds?state=user&type=0"
SSO_ENTRY = cas.login_url(HILDESHEIM_CAS, f"{LSF_BASE}/qisserver/rds?state=user&type=1")
PLAN_URL = f"{LSF_BASE}/qisserver/rds?state=wplan&act=show&show=plan&P.subc=plan&week=-2"
SUMMARY_RE = re.compile(r"^\s*(\d{3,5})\s*-\s*(.+?)\s*$")
LECTURER_RE = re.compile(r"\s*\(([A-ZÄÖÜ][\wäöüß\-]+(?:\s*[,/]\s*[A-ZÄÖÜ][\wäöüß\-]+)*)\)\s*$")


def is_logged_in(page) -> bool:
    try:
        return "uni-hildesheim.de" in page.url and page.locator("a:has-text('Abmelden')").count() > 0
    except Exception:  # noqa: BLE001
        return False


def login(page, user: str, password: str, log: Callable[[str], None] = print) -> None:
    cas.login(page, SSO_ENTRY, HILDESHEIM_CAS, user, password, lambda: "lsf." in page.url and is_logged_in(page), log)


def plan_ics_link(html_text: str) -> str | None:
    """iCal-Link des ganzen Stundenplans aus der Stundenplan-Seite."""
    m = re.search(r'href="([^"]*moduleCall=iCalendarPlan[^"]*)"', html_text or "")
    if not m:
        return None
    return absolute(m.group(1).replace("&amp;", "&"))


def absolute(href: str) -> str:
    """Link einer LSF-Seite als volle Adresse: http(s) bleibt, "/qisserver/rds?..." gegen die Basis, "rds?..." relativ
    zu /qisserver/ (vorher wurde ein wurzelrelativer Link zu ".../qisserver/qisserver/rds?...")."""
    if href.startswith(("http://", "https://")):
        return href
    if href.startswith("/"):
        return LSF_BASE + href
    return f"{LSF_BASE}/qisserver/{href}"


def fetch_plan_ics(page) -> str | None:
    page.goto(PLAN_URL, wait_until="domcontentloaded")
    page.wait_for_timeout(600)
    if not is_logged_in(page):
        raise RuntimeError("LSF: nicht angemeldet (Stundenplan nicht erreichbar)")
    link = plan_ics_link(page.content())
    if not link:
        return None       # leerer Stundenplan: kein Export-Link
    r = page.request.get(link)
    text = r.text()
    if not r.ok or "BEGIN:VCALENDAR" not in text:
        raise RuntimeError(f"LSF: iCal-Export nicht lesbar ({r.status})")
    if not plan_entries(text):
        # Export-Link mit Terminen, aber kein Termin im Kalender: unvollstaendige Antwort. Nichts uebernehmen und keine
        # LSF-Serie entfernen (import_plan wuerde sonst alle samt Ausnahmen und Teilnahme loeschen); ein leerer Plan
        # ist nur der Fall ohne Export-Link. Dieselbe Regel im Kern der iPad-App (LSFClient.planEntries).
        raise RuntimeError("LSF: iCal-Export ohne Termine")
    return text


def split_summary(summary: str) -> dict:
    """'9449 - Erinnerungen ... (Muster)' -> number, title, lecturer."""
    s = (summary or "").replace("\\,", ",").replace("\\;", ";").strip()
    num = None
    m = SUMMARY_RE.match(s)
    if m:
        num, s = m.group(1), m.group(2)
    lecturer = ""
    m = LECTURER_RE.search(s)
    if m:
        lecturer, s = m.group(1), s[:m.start()].strip()
    return {"number": num, "title": s or summary, "lecturer": lecturer}


PLACEHOLDER_RE = re.compile(r"nur\s+aus\s+technischen\s+Gr(?:ü|ue)nden\s+angezeigt", re.I)


def note_text(description: str | None) -> str:
    """Bemerkung einer LSF-Veranstaltung (iCal DESCRIPTION, HTML) als kurzer Text."""
    from .announcements import html_to_text
    return re.sub(r"\s*\n\s*", " · ", html_to_text(description or ""))[:400]   # Zeilenumbrueche wandelt parse_ics schon um


def is_placeholder(note: str | None) -> bool:
    """LSF-Termin, der laut Bemerkung "nur aus technischen Gruenden angezeigt" wird (kein echter Termin)."""
    return bool(PLACEHOLDER_RE.search(note or ""))


def plan_entries(ics_text: str) -> list[dict]:
    out = []
    for e in timetable.parse_ics(ics_text):
        p = split_summary(e["title"])
        e.update(title=p["title"], number=p["number"], lecturer=p["lecturer"] or e.get("lecturer") or "",
                 kind=timetable.guess_kind(p["title"]), note=note_text(e.get("description")))
        out.append(e)
    return out


def _norm_sem(s: str | None) -> str:
    return re.sub(r"[\s.]", "", (s or "").lower()).replace("wintersemester", "wise").replace("sommersemester", "sose")


def _key(e: dict) -> tuple:
    return (re.sub(r"\W+", "", (e["title"] or "").lower())[:40], int(e["weekday"]), e["start_time"], e["end_time"],
            e.get("rrule") or "weekly", e.get("date_from") or "")


def import_plan(conn, entries: list[dict]) -> dict:
    """LSF-Termine als eigene Serien (Quelle 'lsf') uebernehmen. Bestehende LSF-Serien bleiben mit Ausnahmen und
    Teilnahme-Einstellungen erhalten; nicht mehr im Plan stehende LSF-Serien werden entfernt. Andere Quellen
    (manuell, Stud.IP, ICS-Import) bleiben unberuehrt."""
    term_name = _norm_sem(timetable.term(conn).get("name"))
    for e in entries:
        c = None
        if e.get("number"):
            for row in db.rows(conn, "SELECT id, module_id, semester FROM courses WHERE number=?", (e["number"],)):
                if _norm_sem(row["semester"]) == term_name:
                    c = row
                    break
        e["course_id"] = c["id"] if c else None
        e["module_id"] = (c or {}).get("module_id")
    entries = timetable.enrich(conn, entries)
    existing = db.rows(conn, "SELECT * FROM course_events WHERE source='lsf'")
    ex_map = {_key(x): x for x in existing}
    want: dict[tuple, dict] = {}
    for e in entries:
        want.setdefault(_key(e), e)
    new = [e for k, e in want.items() if k not in ex_map]
    removed = [x["id"] for k, x in ex_map.items() if k not in want]
    # Ausfaelle legt import_plan unten selbst an (Notiz "laut LSF", auch fuer bestehende Serien), nicht apply_import
    res = timetable.apply_import(conn, [{**e, "exdates": None} for e in new], "lsf", remove_ids=removed)
    # Vorlesungsfreie Tage (EXDATE) als Ausfall, fuer neue und bestehende Serien (ohne Doppelte)
    ids = {k: x["id"] for k, x in ex_map.items() if k in want}
    for e, new_id in zip(new, res["ids"]):
        ids[_key(e)] = new_id
    # Bemerkung aus dem LSF uebernehmen. Platzhalter ("nur aus technischen Gruenden angezeigt") werden einmalig auf
    # "nicht besuchen" gestellt, wenn der Hinweis neu ist; eine spaetere Entscheidung des Nutzers bleibt bestehen.
    n_placeholder = 0
    for k, e in want.items():
        eid = ids.get(k)
        if not eid:
            continue
        old = (db.row(conn, "SELECT note FROM event_notes WHERE event_id=?", (eid,)) or {}).get("note") or ""
        note = e.get("note") or ""
        if old != note:
            if note:
                conn.execute("""INSERT INTO event_notes(event_id, note, source, updated_at) VALUES (?, ?, 'lsf', ?)
                                ON CONFLICT(event_id) DO UPDATE SET note=excluded.note, updated_at=excluded.updated_at""", (eid, note, db.now_iso()))
            else:
                conn.execute("DELETE FROM event_notes WHERE event_id=?", (eid,))
            if is_placeholder(note) and not is_placeholder(old):
                conn.execute("UPDATE course_events SET attend=0 WHERE id=?", (eid,))
                n_placeholder += 1
    n_exc = 0
    for k, e in want.items():
        eid = ids.get(k)
        for d in e.get("exdates") or []:
            if eid and not db.row(conn, "SELECT 1 FROM event_exceptions WHERE event_id=? AND date=?", (eid, d)):
                conn.execute("INSERT INTO event_exceptions(event_id, date, type, note, created_at) VALUES (?,?, 'cancelled', ?, ?)",
                             (eid, d, "fällt aus laut LSF", db.now_iso()))
                n_exc += 1
    conn.execute("INSERT INTO schedule_imports(source, created_at, status, raw, parsed, confirmed) VALUES ('lsf-auto', ?, 'auto', '', ?, 1)",
                 (db.now_iso(), json.dumps(new, ensure_ascii=False, default=str)))
    return {"new": res["new"], "removed": len(removed), "kept": len(want) - len(new), "cancelled_dates": n_exc,
            "placeholders": n_placeholder}
