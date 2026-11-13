"""Lernziele (Smart Planner 2.0) am PC und im Browser (app/static/views-goals.js, 13.11.2026), wie GoalsPage.swift auf
dem iPad: Reiter "Lernziele" im Lernkalender, erste Ziele anlegen, Plan erstellen, Stoppuhr starten und beenden, Zeit
eintragen, Zeitrahmen, bei zu wenig Zeit die Optionen (nichts ohne Klick), Lernblock im Lernpaket sperren, schmal ohne
Ueberbreite. Erfundene Module, kein Netz. Ohne Chromium wird uebersprungen (wie tests/test_pwa.py)."""
import json
from datetime import date

import pytest
from conftest import asgi_call
from test_pwa import _browser, served  # noqa: F401  (Fixture `served`)

# geladen: Kennzahlen oder die erste Karte "Lernziele festlegen" (nicht der Platzhalter "Lade Lernziele …")
READY = "document.querySelector('#view .goals .goals-kpis, #view .goals [data-newgoal], #view .goals .goals-feas')"


@pytest.fixture()
def modules(app, tmp_path, monkeypatch):
    from app import db, study
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "goals.db")
    db.init_db()
    monkeypatch.setattr(study, "today", lambda: date(2026, 11, 13))

    def call(method, path, body=None):
        st, _, b = asgi_call(app, method, path, body=json.dumps(body) if body is not None else None)
        assert st < 300, (path, st, b[:300])
        return json.loads(b) if b else None
    ids = []
    for name, exam in (("Mathematik I", "2027-02-08"), ("Programmieren I", "2027-02-15")):
        mid = call("POST", "/api/modules", {"name": name})["id"]
        call("PATCH", f"/api/modules/{mid}", {"exam_date": exam})
        ids.append(mid)
    call("POST", "/api/timetable/events", {"title": "Analysis", "kind": "vorlesung", "weekday": 0, "start_time": "08:15",
                                           "end_time": "09:45", "module_id": ids[0], "rrule": "weekly"})
    return ids, call


def _run(base, body, width=1400, height=900, hash_="#/plan?view=ziele"):
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        pytest.skip("Playwright fehlt")
    with sync_playwright() as p:
        browser = _browser(p)
        if browser is None:
            pytest.skip("kein Chromium fuer Playwright")
        try:
            context = browser.new_context(bypass_csp=True, viewport={"width": width, "height": height}, service_workers="block")
            page = context.new_page()
            errors = []
            page.on("pageerror", lambda e: errors.append(str(e)))
            page.on("dialog", lambda d: d.accept())               # Rueckfragen (Option uebernehmen) bestaetigen
            page.goto(base + "/" + hash_)
            page.wait_for_function(READY, timeout=30000)
            body(page)
            assert errors == [], errors
        finally:
            browser.close()


def _toast(page, text):
    page.wait_for_function(f"(document.querySelector('#toastEl')?.textContent || '').includes({json.dumps(text)})", timeout=15000)


def test_goals_view_set_goal_plan_timer_and_entry(served, modules):
    ids, call = modules

    def body(page):
        # Reiter in der Leiste des Lernkalenders, aktiv
        assert page.inner_text(".goals .seg button.active").strip() == "Lernziele"
        assert "Lernziele festlegen" in page.inner_text("#view")
        page.click(f"[data-newgoal='{ids[0]}']")
        page.wait_for_selector("#gdT")
        assert page.input_value("#gdE") == "2027-02-08", "Klausurtermin des Moduls vorbelegt"
        page.fill("#gdT", "100,5")
        page.click("#gdOk")
        _toast(page, "Lernziel gespeichert")
        page.wait_for_selector(".goals-mod")
        assert "Ziel 100,5 h" in page.inner_text(".goals-mod")
        assert "Programmieren I" in page.inner_text("#view"), "Module ohne Lernziel bleiben angeboten"
        assert len(page.query_selector_all(".goals-kpis .kpi")) == 4
        # Plan erstellen
        page.click("#glPlan")
        _toast(page, "Lernplan steht")
        page.wait_for_function("document.querySelector('#glPlan')?.textContent.includes('Neu verteilen')", timeout=15000)
        # Stoppuhr starten, laeuft sichtbar, beenden
        page.click(f"[data-start='{ids[0]}']")
        page.wait_for_selector(".goals-timer")
        t0 = page.inner_text(".goals-elapsed")
        page.wait_for_function(f"document.querySelector('.goals-elapsed')?.textContent !== {json.dumps(t0)}", timeout=5000)
        page.click("[data-tstop]")
        _toast(page, "gelernt – gespeichert")
        page.wait_for_function("!document.querySelector('.goals-timer')", timeout=10000)
        # Zeit eintragen: 45 Minuten heute
        page.click(f"[data-entry='{ids[0]}']")
        page.wait_for_selector("#seMin")
        page.fill("#seMin", "45")
        page.click("#seOk")
        _toast(page, "Lernzeit gespeichert")
        # Zeitrahmen: Nutzungsquote speichern
        page.click("#glFrame")
        page.wait_for_selector("#gsQuota")
        page.fill("#gsQuota", "70")
        page.click("#gsAdd")
        page.click("#gsOk")
        _toast(page, "Zeitrahmen gespeichert")
        # Kalender-Ansicht und zurueck ueber die Leiste
        page.click(".goals .seg button[data-view='week']")
        page.wait_for_selector("#cal2")
        assert "Lernziele" in page.inner_text(".cal2-bar .seg")
        page.click(".cal2-bar .seg button[data-view='ziele']")
        page.wait_for_selector(".goals-mod")

    _run(served, body)
    o = call("GET", "/api/goals")
    assert o["settings"]["utilization"] == 70 and len(o["settings"]["commitments"]) == 1
    m = o["modules"][0]
    assert m["target_minutes"] == 6030 and m["stats"]["learned_minutes"] >= 45
    assert o["planned"] and o["running"] == []


def test_too_little_time_shows_options_and_partial_plan_only_on_click(served, modules):
    ids, call = modules
    call("PUT", f"/api/goals/{ids[0]}", {"target_hours": 2000})          # Obergrenze des Dienstes
    call("POST", "/api/goals/plan", {})
    assert call("GET", "/api/goals")["plan"]["status"] == "unterdeckt"

    def body(page):
        page.wait_for_selector(".goals-feas")
        text = page.inner_text(".goals-feas")
        assert "Zu wenig Zeit" in text and "nötig" in text and "verfügbar" in text
        assert "StudiNow ändert nichts, bevor du eine Option wählst" in text
        opts = page.query_selector_all(".goals-option")
        teil = [o for o in opts if "Teilplan" in o.inner_text()]
        assert teil, [o.inner_text() for o in opts]
        teil[0].query_selector("[data-opt]").click()
        _toast(page, "Lernplan steht")

    _run(served, body)
    assert call("GET", "/api/goals")["plan"]["status"] == "teilplan"


def test_smart_block_in_the_package_drawer_can_be_locked(served, modules):
    ids, call = modules
    call("PUT", f"/api/goals/{ids[0]}", {"target_hours": 40})
    call("POST", "/api/goals/plan", {})
    cal = call("GET", "/api/calendar?start=2026-11-16&end=2026-11-22")
    pid = next(p["id"] for d in cal["days"] for p in d["packages"] if p.get("source") == "smart")

    def body(page):
        page.evaluate(f"import('/views-plan.js').then(m => m.openPackage({pid}))")
        page.wait_for_selector("#drawerEl .goals-block")
        assert "Lernblock aus deinen Lernzielen" in page.inner_text("#drawerEl .goals-block")
        page.click("#sbLock")
        _toast(page, "Gesperrt")
        page.wait_for_function("document.querySelector('#drawerEl .goals-block')?.textContent.includes('gesperrt')", timeout=10000)

    _run(served, body)
    assert call("GET", f"/api/packages/{pid}")["locked"] == 1


def test_narrow_window_without_horizontal_overflow(served, modules):
    ids, call = modules
    call("PUT", f"/api/goals/{ids[0]}", {"target_hours": 80})

    def body(page):
        page.wait_for_selector(".goals-mod")
        wide = page.evaluate("""[...document.querySelectorAll('#view *')].filter(e => { const r = e.getBoundingClientRect();
            return r.width > 0 && r.right > innerWidth + 1; }).slice(0, 5).map(e => e.tagName + '.' + e.className + ' ' + e.textContent.slice(0, 30))""")
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth + 1"), wide
        assert page.evaluate("getComputedStyle(document.querySelector('.goals-cols')).gridTemplateColumns.split(' ').length") == 1
        # auch die Kalender-Ansicht mit der laengeren Leiste (sechs Ansichten) bleibt in der Breite
        page.click(".goals .seg button[data-view='week']")
        page.wait_for_selector("#cal2")
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth + 1")

    _run(served, body, width=390, height=844)
