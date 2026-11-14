"""Lernplaner im Browser (app/static/plan-choice.js, Auftrag des Inhabers 14.11.2026, Teil 1), wie PlanChoiceViews.swift
auf dem iPad: Knopf "Diese Woche" (Wochenwunsch), Faecher in der Lernkombination (abwaehlen, eigenes Fach hinzufuegen),
"Thema schon gemacht" im Aufgaben-Menue, "Hier ein anderes Fach gemacht" im Lernpaket. Feste Uhr auf beiden Seiten
(Freitag 13.11.2026, 12:00 Berlin), erfundene Module, kein Netz. Ohne Chromium wird uebersprungen (wie test_pwa.py)."""
import json
import time
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import pytest
from conftest import asgi_call
from test_pwa import _browser, served  # noqa: F401  (Fixture `served`)

T0 = datetime(2026, 11, 13, 12, 0, tzinfo=ZoneInfo("Europe/Berlin"))


@pytest.fixture()
def plan(app, tmp_path, monkeypatch):
    from app import db, smart_goals, study
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "choice.db")
    db.init_db()
    started = time.monotonic()

    def now():
        return T0 + timedelta(seconds=time.monotonic() - started)
    monkeypatch.setattr(smart_goals, "now", now)
    monkeypatch.setattr(study, "today", lambda: now().date())

    def call(method, path, body=None):
        st, _, b = asgi_call(app, method, path, body=json.dumps(body) if body is not None else None)
        assert st < 300, (path, st, b[:300])
        return json.loads(b) if b else None
    math = call("POST", "/api/modules", {"name": "Mathematik I"})["id"]
    phys = call("POST", "/api/modules", {"name": "Physik I"})["id"]
    with db.cursor() as conn:
        ids = {}
        for key, mid, subject, day, start, end, title in (("today", phys, "Physik I", "2026-11-13", "14:00", "15:00", "Kapitel 3 lesen"),
                                                          ("later", math, "Mathematik I", "2026-11-17", "10:00", "11:00", "Reihen üben"),
                                                          ("mon", math, "Mathematik I", "2026-11-14", "10:00", "10:45", "Folgen wiederholen")):
            pid = conn.execute("INSERT INTO study_packages(date, module_id, subject, title, planned_minutes, status, sort, generated, created_at, start_time, end_time) "
                               "VALUES (?,?,?,?,60,'geplant',0,1,'2026-11-12T09:00:00',?,?)", (day, mid, subject, subject, start, end)).lastrowid
            tid = conn.execute("INSERT INTO study_tasks(package_id, type, title, sort, est_minutes, status, created_at) VALUES (?, 'frei', ?, 0, 60, 'geplant', '2026-11-12')",
                               (pid, title)).lastrowid
            ids[key] = (pid, tid)
    return {"math": math, "phys": phys, "ids": ids}, call


def _run(base, body, width=1400, height=900, hash_="#/plan?view=week&date=2026-11-13"):
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        pytest.skip("Playwright fehlt")
    with sync_playwright() as p:
        browser = _browser(p)
        if browser is None:
            pytest.skip("kein Chromium fuer Playwright")
        try:
            context = browser.new_context(bypass_csp=True, viewport={"width": width, "height": height}, service_workers="block",
                                          timezone_id="Europe/Berlin")
            page = context.new_page()
            page.clock.install(time=T0)
            page.clock.resume()
            errors = []
            page.on("pageerror", lambda e: errors.append(str(e)))
            page.on("dialog", lambda d: d.accept())
            page.goto(base + "/" + hash_)
            page.wait_for_selector("#wishBtn", timeout=30000)
            body(page)
            assert errors == [], errors
        finally:
            browser.close()


def _toast(page, text):
    page.wait_for_function(f"(document.querySelector('#toastEl')?.textContent || '').includes({json.dumps(text)})", timeout=15000)


def test_week_wish_subjects_topic_done_and_other_subject(served, plan):
    d, call = plan

    def body(page):
        # Wochenwunsch: Mathematik antippen, speichern
        page.click("#wishBtn")
        page.wait_for_selector("[data-ww='Mathematik I']")
        page.click("[data-ww='Mathematik I']")
        page.click("#wwOk")
        page.wait_for_function("!document.querySelector('#wwOk')", timeout=10000)
        # Lernpaket von heute (Physik): dort Mathematik gemacht -> Dienstag wird frei, Physik rueckt dorthin
        page.wait_for_selector(f".cal2-ev[data-pkg='{d['ids']['today'][0]}']")
        page.click(f".cal2-ev[data-pkg='{d['ids']['today'][0]}']")
        page.click("#pkOther")
        page.wait_for_selector(f"[data-ot='{d['ids']['later'][1]}']")
        page.check(f"[data-ot='{d['ids']['later'][1]}']")
        page.click("#otOk")
        _toast(page, "1 Termin frei")
        # Aufgabenmenue: "Thema schon gemacht" (Samstag)
        page.wait_for_selector(f".cal2-ev[data-pkg='{d['ids']['mon'][0]}']", timeout=15000)
        page.click(f".cal2-ev[data-pkg='{d['ids']['mon'][0]}']")
        page.click(f"[data-taskmenu='{d['ids']['mon'][1]}']")
        page.click("[data-a='topicdone']")
        _toast(page, "1 Aufgabe erledigt")
        # Lernkombination: Faecher, eigenes Fach hinzufuegen, Physik abwaehlen
        page.click("#cfgBtn")
        page.wait_for_selector("[data-subj='Physik I']")
        page.fill("#cSubjNew", "Englisch")
        page.click("#cSubjAdd")
        page.wait_for_selector("[data-subj='Englisch']")
        page.click("[data-subj='Physik I']")
        page.click("#cOk")
        _toast(page, "Lernkombination gespeichert")

    _run(served, body)
    assert call("GET", "/api/calendar/week-wish")["modules"] == ["Mathematik I"]
    mods = {m["name"]: m["planned"] for m in call("GET", "/api/calendar/modules")["modules"]}
    assert mods == {"Mathematik I": True, "Physik I": False, "Englisch": True}
    cal = call("GET", "/api/calendar?start=2026-11-13&end=2026-11-17")
    pk = {p["id"]: p for day in cal["days"] for p in day["packages"]}
    later, mon = d["ids"]["later"], d["ids"]["mon"]
    assert later[0] not in pk, "Dienstag (Mathematik) frei"
    assert all(t["status"] == "erledigt" for p in pk.values() for t in p["tasks"] if t["id"] in (later[1], mon[1]))
    assert not any(p["subject"] == "Physik I" and p["status"] == "geplant" for p in pk.values()), "Physik abgewaehlt: kein geplantes Paket"


def test_narrow_window_has_the_week_button(served, plan):
    def body(page):
        page.click("#wishBtn")
        page.wait_for_selector("#wwOk")
        assert page.evaluate("document.documentElement.scrollWidth <= window.innerWidth + 1")

    _run(served, body, width=390, height=844)
