"""Moduldetail am PC im echten Browser (app/static/views-misc.js, Auftrag 13.11.2026): Wochen starten zugeklappt, Haken
"erledigt" je Datei ganz rechts, "Woche erledigt" im Wochenkopf mit Fortschritt, zweiter Klick nimmt alle Haken weg.
Gleicher Stand wie die Lernpakete (`study.set_files_done`). Erfundene Daten, kein Netz. Ohne Chromium uebersprungen."""
import pytest
from test_pwa import _browser, served  # noqa: F401  (Fixture `served`)


@pytest.fixture()
def module_id(app, tmp_path, monkeypatch):
    from app import db
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "web-done.db")
    db.init_db()
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name, color, sort, created_at) VALUES ('Web-Analysis', '#175ee8', 0, 't')").lastrowid
        conn.execute("INSERT INTO courses(id, title, subject, kind, active, module_id, created_at) VALUES ('wd-c', 'Web-Analysis', 'Web-Analysis', 'vorlesung', 1, ?, 't')", (mid,))
        for i, n in enumerate(["01 Folien Grenzwerte.pdf", "01 Übungsblatt.pdf", "02 Folien Reihen.pdf"]):
            conn.execute("INSERT INTO files(id, course_id, name, chdate, status) VALUES (?,?,?,?, 'gelesen')", (f"wd-{i}", "wd-c", n, 1_791_000_000 + i))
    return mid


def _status():
    from app import db
    with db.cursor() as conn:
        return {r["id"]: r["status"] for r in db.rows(conn, "SELECT id, status FROM files WHERE id LIKE 'wd-%'")}


def test_ticks_and_collapsed_weeks(served, module_id):
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        pytest.skip("Playwright fehlt")
    with sync_playwright() as p:
        browser = _browser(p)
        if browser is None:
            pytest.skip("kein Chromium fuer Playwright")
        try:
            page = browser.new_context(bypass_csp=True, viewport={"width": 1280, "height": 900}, service_workers="block").new_page()
            errors = []
            page.on("pageerror", lambda e: errors.append(str(e)))
            page.goto(f"{served}/#/modules/{module_id}")
            page.wait_for_selector(".week-block", timeout=30000)
            blocks = page.locator(".week-block")
            n = blocks.count()
            assert n >= 1
            # alle Wochen zugeklappt, Knopf "Woche erledigt" im Kopf
            assert page.eval_on_selector_all(".week-block .wb", "els => els.every(e => e.hidden)")
            assert page.locator(".week-block .week-done").count() == n
            first = blocks.first
            first.locator(".wh h3").click()
            first.locator(".done-tick").first.wait_for(state="visible")
            ids = first.locator(".done-tick").evaluate_all("els => els.map(e => e.dataset.f)")
            # ein Haken
            first.locator(".done-tick").first.click()
            page.wait_for_function("document.querySelector('.week-block .done-tick.on')")
            assert _status()[ids[0]] == "erledigt"
            # die Woche bleibt nach dem Neuzeichnen offen und zeigt den Fortschritt
            assert not page.locator(".week-block").first.locator(".wb").evaluate("e => e.hidden")
            if len(ids) > 1:
                assert f"1/{len(ids)} erledigt" in page.locator(".week-block").first.locator(".wh").inner_text()
            # ganze Woche, dann wieder alle weg
            page.locator(".week-block").first.locator(".week-done").click()
            page.wait_for_function("document.querySelector('.week-block .week-done.on')")
            assert all(_status()[i] == "erledigt" for i in ids)
            page.locator(".week-block").first.locator(".week-done").click()
            page.wait_for_function("!document.querySelector('.week-block .week-done.on')")
            assert all(_status()[i] == "gelesen" for i in ids)
            assert errors == [], errors
        finally:
            browser.close()
