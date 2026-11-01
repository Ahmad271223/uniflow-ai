"""Uebersicht (Startseite, app/static/views-home.js, "Design 2") im echten Browser: die Frage "Was mache ich heute?"
steht oben links im groessten Block (nachzuholen mit Hauptknopf), die drei Zahlenkaesten sind weg, es gibt keine
Schatten und keine Verlaeufe, und auf dem Handy steht der Install-Hinweis UNTER dem Tagesplan, der im ersten Bildschirm
beginnt. Ohne Chromium wird uebersprungen (wie tests/test_pwa.py)."""
from datetime import date, timedelta

import pytest
from test_pwa import _browser, served  # noqa: F401  (Fixture `served`)

DASHBOARD = "document.querySelector('#view') && /Guten/.test(document.querySelector('#view').textContent)"
FLAT = """() => ({
  shadows: [...document.querySelectorAll('#view .ov, #view .ov *')].filter(e => getComputedStyle(e).boxShadow !== 'none').length,
  gradients: [...document.querySelectorAll('#view .ov, #view .ov *')].filter(e => /gradient/.test(getComputedStyle(e).backgroundImage)).length,
  hscroll: document.documentElement.scrollWidth > innerWidth })"""


@pytest.fixture
def backlog(app):
    """Ein Lernpaket von gestern mit offener Aufgabe: die Uebersicht zaehlt es als "nachzuholen"."""
    from app import db
    db.init_db()
    yesterday = (date.today() - timedelta(days=1)).isoformat()
    with db.cursor() as conn:
        cur = conn.execute("INSERT INTO study_packages(date, subject, title, week_no, planned_minutes, status, sort, generated, created_at) "
                           "VALUES (?, 'Ueberblick-Test', 'Rueckstand', 1, 30, 'geplant', 0, 0, ?)", (yesterday, db.now_iso()))
        pid = cur.lastrowid
        conn.execute("INSERT INTO study_tasks(package_id, type, title, sort, est_minutes, status, created_at) VALUES (?, 'vorlesung', 'Folien nachholen', 0, 30, 'geplant', ?)", (pid, db.now_iso()))
    yield pid
    with db.cursor() as conn:
        conn.execute("DELETE FROM study_tasks WHERE package_id=?", (pid,))
        conn.execute("DELETE FROM study_packages WHERE id=?", (pid,))


def _open(browser, base, width, height):
    context = browser.new_context(bypass_csp=True, viewport={"width": width, "height": height}, service_workers="block")
    page = context.new_page()
    page.goto(base + "/#/dashboard")
    page.wait_for_function(DASHBOARD, timeout=20000)
    return page


def test_overview_answers_what_to_do_today(served, backlog):
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        pytest.skip("Playwright fehlt")
    with sync_playwright() as p:
        browser = _browser(p)
        if browser is None:
            pytest.skip("kein Chromium fuer Playwright")
        try:
            page = _open(browser, served, 1280, 800)
            page.wait_for_selector(".ov-focus")
            focus = page.text_content(".ov-focus")
            assert "nachzuholen" in focus and "Jetzt nachholen" in focus
            assert page.query_selector(".ov-focus #rescueBtn") is not None, "Hauptknopf im groessten Block"
            box = page.eval_on_selector(".ov-focus", "e => { const b = e.getBoundingClientRect(); return [b.left, b.top, b.width]; }")
            plan = page.eval_on_selector(".ov-plan, .ov-aside", "e => { const b = e.getBoundingClientRect(); return [b.left, b.top]; }")
            assert box[1] < 300 and plan[0] >= box[0], "Fokus oben links, Tagesplan daneben oder darin"
            assert page.query_selector("#view .kpi") is None, "die drei Zahlenkaesten sind zu einer Zeile geworden"
            flat = page.evaluate(FLAT)
            assert flat == {"shadows": 0, "gradients": 0, "hscroll": False}, flat
            # leere Baender: keine Karte ohne Inhalt
            for card in page.query_selector_all(".ov-rest > .ov-card"):
                assert card.inner_text().strip(), "leere Karte"
        finally:
            browser.close()


def test_overview_mobile_plan_in_first_screen_install_hint_below(served, backlog):
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        pytest.skip("Playwright fehlt")
    with sync_playwright() as p:
        browser = _browser(p)
        if browser is None:
            pytest.skip("kein Chromium fuer Playwright")
        try:
            page = _open(browser, served, 390, 844)
            page.evaluate("window.dispatchEvent(new Event('beforeinstallprompt'))")      # Handy-Chrome bietet "Installieren" an
            page.evaluate("__app.route()")
            page.wait_for_selector("#pwaHint")
            top = page.evaluate("""() => { const t = s => document.querySelector(s).getBoundingClientRect().top + scrollY;
              return { plan: t('.ov-plan h2, .ov-aside h2'), hint: t('#pwaHint') }; }""")
            assert top["plan"] < 844, f"Tagesplan beginnt im ersten Bildschirm: {top}"
            assert top["hint"] > top["plan"], f"Install-Hinweis unter dem Tagesplan: {top}"
            flat = page.evaluate(FLAT)
            assert flat == {"shadows": 0, "gradients": 0, "hscroll": False}, flat
        finally:
            browser.close()
