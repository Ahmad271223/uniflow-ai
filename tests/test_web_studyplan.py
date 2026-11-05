"""Seite "Studienverlauf" im echten Browser (app/static/study-plan.js, study-plan-logic.js): Eintrag in der Seitenleiste, Kopf mit Ring und
Studiengang, Pruefungsordnung bestaetigen, Semester-Spalten mit Modulkarten, Filter, "Nachholen im naechsten passenden Semester",
Moduldetail mit Versuchen, Sprung von der Modulseite, ohne QIS einen Studiengang aus dem Register waehlen, schmal ohne Ueberbreite.
Daten: der mitgelieferte Grundstock (nur Fakten) und erfundene Noten; kein Netz. Ohne Chromium wird uebersprungen (wie tests/test_pwa.py)."""
import time
from datetime import date

import pytest
from test_pwa import _browser, served  # noqa: F401  (Fixture `served`)

TI_LABEL = "Technische Informatik (PO-Version 2017)"
READY = "document.querySelector('#view .sp-board, #view .sp-notice')"


class NoNetwork:
    def __init__(self):
        self.calls = []

    def __call__(self, url, etag=None, last_modified=None):
        self.calls.append(url)
        raise AssertionError(f"echtes Netz in einem Test: {url}")


@pytest.fixture()
def fresh(app, tmp_path, monkeypatch):
    from app import db, study, study_catalog as sc
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "web.db")
    db.init_db()
    monkeypatch.setattr(study, "today", lambda: date(2026, 11, 4))
    net = NoNetwork()
    monkeypatch.setattr(sc, "FETCH", net)
    monkeypatch.setattr(sc, "AUTO_SYNC", True)
    sc._active.clear()
    yield net
    sc._active.clear()


def _grades():
    """Programmieren I und Mathematik I bestanden, Elektrotechnische Grundlagen nicht bestanden (Versuch 1), alle im WiSe 25/26"""
    from app import db
    rows = [("1001", "Programmieren I", "1,7", "bestanden"), ("1002", "Mathematik für die Ingenieurwissenschaften I", "2,3", "bestanden"),
            ("1003", "Elektrotechnische Grundlagen der Informatik", "5,0", "nicht bestanden")]
    with db.cursor() as conn:
        for nr, text, note, status in rows:
            conn.execute("INSERT INTO grades(pruefungsnr, text, semester, note, status, credits, versuch, datum, abschluss) VALUES (?,?,?,?,?,?,?,?,?)",
                         (nr, text, "WiSe 25/26", note, status, "5", "1", "2026-02-10", TI_LABEL))


def _open(browser, base, width, height, hash_="#/studyplan", ready=READY):
    context = browser.new_context(bypass_csp=True, viewport={"width": width, "height": height}, service_workers="block")
    page = context.new_page()
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.goto(base + "/" + hash_)
    page.wait_for_function(ready, timeout=30000)
    return page, errors


def _run(served_url, body, width=1280, height=900, hash_="#/studyplan", ready=READY):
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        pytest.skip("Playwright fehlt")
    with sync_playwright() as p:
        browser = _browser(p)
        if browser is None:
            pytest.skip("kein Chromium fuer Playwright")
        try:
            page, errors = _open(browser, served_url, width, height, hash_, ready)
            body(page)
            assert errors == [], errors
        finally:
            browser.close()


def test_study_plan_page_with_grades(served, fresh):
    _grades()

    def body(page):
        # Eintrag in der Seitenleiste (Gruppe Studium, nach "Meine Module")
        labels = page.eval_on_selector_all("#nav a", "els => els.map(e => e.dataset.route)")
        assert labels.index("studyplan") == labels.index("modules") + 1
        assert page.eval_on_selector("#nav a[data-route=studyplan]", "e => e.classList.contains('active')")
        page.wait_for_selector(".sp-board", timeout=30000)        # Suche im Hintergrund aus dem Grundstock, dann Plan
        head = page.inner_text(".sp-head")
        assert "Technische Informatik" in head and "PO 2025" in head and "Verbindlich ist die Prüfungsordnung" in head
        assert "von " in page.inner_text(".sp-ring") and "LP" in page.inner_text(".sp-ring")
        # die PO ist nur vorgeschlagen: Karte mit Bestaetigen
        assert "PO 2025?" in page.inner_text("#spPo")
        # Spalten je Semester mit dem laufenden hervorgehoben
        cur = page.query_selector(".sp-sem.current")
        assert cur is not None and "WiSe 26/27" in cur.inner_text() and "Aktuell" in cur.inner_text()
        titles = page.eval_on_selector_all(".sp-mod-title", "els => els.map(e => e.textContent)")
        assert "Programmieren I" in titles and "Elektrotechnische Grundlagen der Informatik" in titles
        # Bestanden mit Note, nicht bestanden mit Versuch
        prog1 = page.locator(".sp-mod", has_text="Programmieren I").first
        assert "Bestanden · 1,7" in prog1.inner_text()
        etg = page.locator(".sp-mod", has_text="Elektrotechnische Grundlagen der Informatik").first
        assert "Nicht bestanden · Versuch 1" in etg.inner_text() and "nächster Versuch" in etg.inner_text()
        # Nachholen im naechsten passenden Semester
        back = page.inner_text(".sp-backlog")
        assert "Nachholen im nächsten passenden Semester" in back and "Elektrotechnische Grundlagen der Informatik" in back
        assert "WiSe 25/26" in back and "WiSe 26/27" in back
        # Filter Bestanden: nur bestandene Module
        page.click("[data-filter=passed]")
        assert page.eval_on_selector_all(".sp-mod", "els => els.every(e => e.classList.contains('passed'))")
        assert page.locator(".sp-mod").count() == 2
        page.click("[data-filter=open]")
        assert page.locator(".sp-mod.passed").count() == 0
        page.click("[data-filter=all]")
        # Seite scrollt nicht quer; nur das Board scrollt in sich
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        # PO bestaetigen: Karte verschwindet, Plan bleibt
        page.click("#spPoYes")
        page.wait_for_selector("#spPo", state="detached")
        assert page.locator(".sp-mod").count() > 5
        from app import study_plan
        from app import db
        with db.cursor() as conn:
            assert study_plan.load_settings(conn)["po"] == "2025"

    _run(served, body)


def test_module_detail_shows_own_state_and_facts(served, fresh):
    _grades()

    def body(page):
        page.wait_for_selector(".sp-board", timeout=30000)
        page.locator(".sp-mod", has_text="Elektrotechnische Grundlagen der Informatik").first.click()
        page.wait_for_selector(".sp-detail")
        d = page.inner_text(".sp-detail")
        assert "Dein Stand" in d and "Nicht bestanden · Versuch 1" in d and "5,0" in d and "WiSe 25/26" in d
        assert "Leistungspunkte" in d and "Prüfungsleistung" in d and "Voraussetzungen" in d
        assert "Verbindlich ist die Prüfungsordnung" in d
        # Quelle nur als Link mit Seite, im neuen Tab
        a = page.query_selector(".sp-src a")
        assert a and a.get_attribute("rel") == "noopener noreferrer" and a.get_attribute("target") == "_blank"
        assert a.get_attribute("href").startswith("https://") and "#page=" in a.get_attribute("href")
        # Schliessen
        page.click(".sp-modal [data-close]")
        page.wait_for_selector(".sp-modal", state="detached")

    _run(served, body)


def test_settings_save_electives_and_start_term(served, fresh):
    _grades()

    def body(page):
        page.wait_for_selector(".sp-board", timeout=30000)
        page.click("#spSettings")
        page.wait_for_selector("#spSave")
        assert "Prüfungsordnung" in page.inner_text(".sp-set") and "Studienbeginn" in page.inner_text(".sp-set")
        page.select_option("#spSetStart", "WiSe 24/25")
        before = page.inner_text("#spCount") if page.query_selector("#spCount") else ""
        if page.query_selector("[data-el]"):
            page.locator("[data-el]").first.check()
            assert page.inner_text("#spCount") != before or before == ""
        page.click("#spSave")
        page.wait_for_selector("#overlay .modal", state="detached")
        from app import db, study_plan
        with db.cursor() as conn:
            s = study_plan.load_settings(conn)
        assert s["start_term"] == "WiSe 24/25"
        # Studienbeginn aendert die Fachsemester im Plan
        page.wait_for_selector(".sp-board")
        assert "WiSe 24/25" in page.inner_text(".sp-board")

    _run(served, body)


def test_without_qis_choose_program_from_register(served, fresh):
    """Ohne Notenspiegel: 'QIS verbinden' und die Wahl eines Studiengangs aus dem Register; danach der Plan aus dem Grundstock"""
    def body(page):
        assert "Verbinde QIS" in page.inner_text(".sp-notice")
        assert page.query_selector("a[href='#/services']")
        page.click("#spPick")
        page.wait_for_selector(".sp-prog li")
        assert page.locator(".sp-prog li").count() >= 20
        page.fill("#spProgQ", "informatik")
        assert 1 <= page.locator(".sp-prog li").count() < 60
        page.locator("[data-pick=INFBSc22]").first.click()
        page.wait_for_selector(".sp-board", timeout=30000)
        assert "Informatik" in page.inner_text(".sp-head") and "PO 2022" in page.inner_text(".sp-head")
        assert page.eval_on_selector_all(".sp-mod", "els => els.every(e => !e.classList.contains('passed'))"), "ohne Noten nichts bestanden"
        # Studiengang ohne PO-Auswahl-Fehler: gewaehlte Ordnung gilt als bestaetigt (keine Rueckfrage)
        assert page.query_selector("#spPo") is None

    _run(served, body)


def test_no_catalog_shows_link_field_and_rejects_http(served, fresh):
    from app import db, study_plan
    with db.cursor() as conn:
        conn.execute("INSERT INTO grades(pruefungsnr, text, semester, note, status, credits, versuch, datum, abschluss) VALUES "
                     "('9','Etwas','WiSe 25/26','2,0','bestanden','5','1','2026-02-10','Musterfach Unbekannt (PO-Version 2017)')")

    def body(page):
        page.wait_for_selector("#spLink", timeout=30000)
        assert "Noch kein Katalog für deinen Studiengang" in page.inner_text(".sp-notice")
        assert "Musterfach Unbekannt" in page.inner_text(".sp-notice")
        page.fill("#spLink", "http://example.org/a.pdf")
        page.click("#spLinkSave")
        assert "https://" in page.inner_text("#spLinkMsg")
        with db.cursor() as conn:
            assert "catalog_url" not in study_plan.load_settings(conn)

    _run(served, body)


def test_module_page_links_to_study_plan(served, fresh):
    from app import db
    _grades()
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name, color, sort, created_at) VALUES ('Programmieren I', '#4f5bd5', 0, '2026-11-01')").lastrowid

    def body(page):
        page.wait_for_selector("#modStudyPlan")
        page.click("#modStudyPlan")
        page.wait_for_selector(".sp-detail", timeout=30000)       # springt zum Modul und oeffnet sein Detail
        assert page.inner_text(".sp-detail h2") == "Programmieren I"
        assert "Bestanden · 1,7" in page.inner_text(".sp-detail")
        assert page.eval_on_selector("#nav a[data-route=studyplan]", "e => e.classList.contains('active')")

    _run(served, body, hash_=f"#/modules/{mid}", ready="document.querySelector('#modStudyPlan')")


def test_mobile_has_no_horizontal_overflow_and_stacks_semesters(served, fresh):
    _grades()

    def body(page):
        page.wait_for_selector(".sp-board", timeout=30000)
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth"), "keine Ueberbreite am Handy"
        tops = page.eval_on_selector_all(".sp-sem", "els => els.slice(0, 3).map(e => Math.round(e.getBoundingClientRect().top))")
        assert tops == sorted(tops) and len(set(tops)) == len(tops), "Semester untereinander"
        box = page.eval_on_selector(".sp-mod", "e => { const b = e.getBoundingClientRect(); return [b.left, b.right]; }")
        assert box[0] >= 0 and box[1] <= 390

    _run(served, body, width=390, height=844)


def test_dark_mode_page_renders_readable(served, fresh):
    _grades()

    def body(page):
        page.evaluate("document.documentElement.dataset.theme = 'dark'")
        page.wait_for_selector(".sp-board", timeout=30000)
        bg = page.eval_on_selector(".sp-mod", "e => getComputedStyle(e).backgroundColor")
        r, g, b = [int(x) for x in bg[bg.index("(") + 1:bg.index(")")].split(",")[:3]]
        assert max(r, g, b) < 90, f"dunkle Karte, war {bg}"

    _run(served, body)
