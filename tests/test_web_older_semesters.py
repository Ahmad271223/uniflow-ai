"""Fruehere Semester, leere Dokumentseite und ruhige Abgleich-Anzeige im echten Browser (wie tests/test_web_overview.py;
ohne Chromium uebersprungen). Erfundene Kurse und Dateien, kein Abruf bei einer Hochschule."""
import json
from datetime import date

import pytest
from test_pwa import _browser, served  # noqa: F401  (Fixture `served`)

TODAY = date(2026, 11, 3)


@pytest.fixture
def older(app, monkeypatch, tmp_path):
    from app import db, study
    monkeypatch.setattr(study, "today", lambda: TODAY)
    pdf = tmp_path / "alt.pdf"
    pdf.write_bytes(b"%PDF-1.4\n%%EOF\n")
    with db.cursor() as conn:
        parked = [r["id"] for r in db.rows(conn, "SELECT id FROM courses WHERE COALESCE(active, 1)=0 AND id NOT LIKE 'wo-%'")]
        conn.executemany("UPDATE courses SET active=1 WHERE id=?", [(i,) for i in parked])
        for t in ("older_semester_choice", "older_semester_courses"):
            conn.execute(f"DROP TABLE IF EXISTS {t}")
        for cid, title, sem, active in [("wo-neu", "Aktueller Kurs", "WiSe 2026/27", 1), ("wo-alt", "Alter <b>Kurs</b>", "SoSe 2026", 0),
                                        ("wo-alt2", "Noch alter", "WiSe 2024/25", 0)]:
            conn.execute("INSERT OR REPLACE INTO courses(id, title, semester, kind, active, test_minutes, created_at) VALUES (?,?,?,?,?,?,?)",
                         (cid, title, sem, "vorlesung", active, 90, "2026-10-01"))
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, size, chdate, status, kind, first_seen, local_path, downloaded_at) VALUES "
                     "('wo-f1', 'wo-alt', 'Folien.pdf', 10, 1, 'gelesen', 'pdf', '2026-10-01', ?, '2026-10-02T10:00:00')", (str(pdf),))
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, size, chdate, status, kind, first_seen) VALUES "
                     "('wo-f2', 'wo-alt', 'Blatt.pdf', 10, 1, 'gelesen', 'pdf', '2026-10-01')")
    yield
    with db.cursor() as conn:
        conn.execute("DELETE FROM files WHERE course_id LIKE 'wo-%'")
        conn.execute("DELETE FROM courses WHERE id LIKE 'wo-%'")
        conn.executemany("UPDATE courses SET active=0 WHERE id=?", [(i,) for i in parked])
        for t in ("older_semester_choice", "older_semester_courses"):
            conn.execute(f"DROP TABLE IF EXISTS {t}")


def _page(p, base, hash_):
    browser = _browser(p)
    if browser is None:
        pytest.skip("kein Chromium fuer Playwright")
    ctx = browser.new_context(bypass_csp=True, viewport={"width": 1280, "height": 900}, service_workers="block")
    page = ctx.new_page()
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.goto(base + "/" + hash_)
    return browser, page, errors


def test_library_shows_older_semesters_and_the_course_folder(served, older):
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        pytest.skip("Playwright fehlt")
    with sync_playwright() as p:
        browser, page, errors = _page(p, served, "#/files")
        try:
            page.wait_for_selector(".older-sem", timeout=20000)
            assert "Aktuelles Semester · WiSe 2026/27" in page.inner_text(".older-cur")
            sem = page.inner_text(".older-sem")
            assert "Frühere Semester" in sem and "SoSe 2026" in sem and "WiSe 2024/25" in sem
            assert "StudiNow lädt nur Dateien des aktuellen Semesters" in sem
            assert page.query_selector(".older-course") is None, "zugeklappt"
            page.click("[data-older-toggle='0']")
            assert "Alter <b>Kurs</b>" in page.inner_text(".older-courses"), "Titel als Text, nicht als HTML"
            assert page.query_selector(".older-courses b b") is None
            assert "1 von 2 Dateien geladen" in page.inner_text(".older-courses")
            assert page.query_selector("[data-older-course='wo-alt']") is not None
            # Kursordner
            page.click(".older-ct")
            page.wait_for_selector("#olderHead .older-head-card")
            head = page.inner_text("#olderHead")
            assert "Kurs aus einem früheren Semester" in head and "1 von 2 Dateien geladen." in head and "Blatt.pdf" in head
            assert "Folien" in page.inner_text(".lib-grid, .lib-list"), "geladene Datei steht im Ordner"
            assert "Blatt.pdf" not in page.inner_text(".lib-grid, .lib-list"), "nicht geladene nur im Kopf"
            page.wait_for_timeout(200)
            assert not errors, errors
        finally:
            browser.close()


def test_question_after_open_stores_the_choice_and_keeps_current_semester(served, older):
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        pytest.skip("Playwright fehlt")
    with sync_playwright() as p:
        browser, page, errors = _page(p, served, "#/dashboard")
        try:
            page.wait_for_selector(".modal", timeout=30000)
            txt = page.inner_text(".modal")
            assert "Auch frühere Semester laden?" in txt and "Dazu gibt es 2 Kurse aus früheren Semestern." in txt
            assert "(WiSe 2026/27)" in txt
            page.click(".modal .btn.primary")                        # Nur aktuelles Semester
            page.wait_for_selector(".modal", state="detached")
            overview = json.loads(page.evaluate("fetch('/api/older-semesters').then(r => r.text())"))
            assert overview["choice"] == "current", "schon beim Zeigen gilt 'nur aktuelles Semester'"
            page.reload()
            page.wait_for_timeout(8000)
            assert page.query_selector(".modal") is None, "die Frage kommt nie wieder"
            assert not errors, errors
        finally:
            browser.close()


def test_settings_switch_and_empty_document_page(served, older, monkeypatch):
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        pytest.skip("Playwright fehlt")
    from app import db, older_semesters, older_semesters_api
    with db.cursor() as conn:
        older_semesters.set_choice(conn, "current", db.now_iso())
    monkeypatch.setattr(older_semesters_api, "start_loading", lambda: {"started": True, "note": "Die Dateien werden geladen."})
    with sync_playwright() as p:
        browser, page, errors = _page(p, served, "#/settings")
        try:
            page.wait_for_selector("#sOlderAll", timeout=20000)
            assert not page.is_checked("#sOlderAll")
            assert "Aus: StudiNow lädt nur Dateien des aktuellen Semesters." in page.inner_text(".set-mods")
            page.check("#sOlderAll")
            page.wait_for_timeout(600)
            assert json.loads(page.evaluate("fetch('/api/older-semesters').then(r => r.text())"))["choice"] == "all"
            # leere Dokumentseite
            page.goto(served + "/#/doc")
            page.wait_for_selector(".card.empty", timeout=10000)
            assert "Dokument wählen" in page.inner_text(".card.empty")
            page.click(".card.empty a.btn")
            page.wait_for_function("/Dokumente & Notizen/.test(document.querySelector('#view h1')?.textContent || '')", timeout=10000)
            assert page.evaluate("location.hash").startswith("#/files")
            # gemerktes Dokument nicht mehr da
            page.goto(served + "/#/doc/gibt-es-nicht")
            page.wait_for_selector(".card.empty", timeout=10000)
            assert "Dieses Dokument gibt es nicht mehr." in page.inner_text(".card.empty")
            assert not errors, errors
        finally:
            browser.close()


def test_sync_chip_is_quiet_without_news(served, older):
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        pytest.skip("Playwright fehlt")
    from app import db
    with db.cursor() as conn:
        conn.execute("INSERT INTO sync_log(started_at, finished_at, ok, new_files, message) VALUES ('2099-01-01T08:00:00', '2099-01-01T08:01:00', 1, 0, '0 neue/geaenderte Dateien')")
        quiet_id = conn.execute("SELECT MAX(id) FROM sync_log").fetchone()[0]
    try:
        with sync_playwright() as p:
            browser, page, errors = _page(p, served, "#/files")
            try:
                page.wait_for_selector(".older-sem", timeout=20000)
                page.wait_for_timeout(500)
                assert page.inner_text("#syncChip").strip() == "", "ruhig: nichts Neues, kein Fehler"
                with db.cursor() as conn:
                    conn.execute("INSERT INTO sync_log(started_at, finished_at, ok, new_files, message) VALUES ('2099-01-01T09:00:00', '2099-01-01T09:01:00', 1, 3, '3 neue/geaenderte Dateien')")
                page.goto(served + "/#/plan")
                page.reload()
                page.wait_for_function("document.querySelector('#syncChip').textContent.trim().length > 0", timeout=20000)
                assert "3 neue Dateien" in page.inner_text("#syncChip")
                assert not errors, errors
            finally:
                browser.close()
    finally:
        with db.cursor() as conn:
            conn.execute("DELETE FROM sync_log WHERE started_at LIKE '2099-%'")
