"""Stud.IP-Inhalte der iPad-App im Web (03.11.2026) im echten Browser: Karte "Neuigkeiten" auf der Uebersicht mit der Zeile
"Schwarzes Brett: N neue Anzeigen", Karte "Schwarzes Brett" unter "Uni & Noten" mit Leser, "Aus Stud.IP" in der Modulansicht.
Erfundene Daten in der Test-Datenbank, kein Netz zu einer Hochschule. Ohne Chromium wird uebersprungen (wie
tests/test_pwa.py)."""
from datetime import date

import pytest
from test_pwa import _browser, served  # noqa: F401  (Fixture `served`)

TODAY = date.today().isoformat()
LONG = " ".join(f"Wort{i}" for i in range(1, 301)) + "\nLetzter Absatz."
TITLE = "WG-Zimmer in der Nordstadt ab Dezember, 18 m², möbliert, mit Balkon"


@pytest.fixture
def seeded(app):
    from app import announcements, db, studip_bulletin as sb, studip_extras, studip_texts
    db.init_db()
    now = f"{TODAY}T09:15:00"
    with db.cursor() as conn:
        studip_extras.store_global_news(conn, studip_extras.global_news(
            [{"id": "g-browser", "type": "news", "attributes": {"title": "Rückmeldung zum Sommersemester", "content": "<p>Bitte zurückmelden.</p>",
                                                                "publication-start": f"{TODAY}T08:00:00+01:00"}}], "https://studip.test"), now)
        studip_extras.store_messages(conn, [{"id": "sp-msg-b1", "sender": "Lehrende", "subject": "Tutorium entfällt", "preview": "Liebe Studierende,\ndas Tutorium fällt aus.",
                                             "sent_at": now, "url": "https://studip.test/dispatch.php/messages/overview", "dates": []}], now)
        d = sb.Download({})
        d.topics = [{"id": "a", "title": "Biete", "count": 40}, {"id": "b", "title": "Wohnliches", "count": 9}]
        d.entries = [{"id": "sb-1", "topic": "Wohnliches", "title": TITLE, "text": LONG, "url": "https://studip.test/plugins.php/schwarzesbrettplugin/article/view/1", "posted_at": now},
                     {"id": "sb-2", "topic": "Biete", "title": "Fahrrad zu verkaufen", "text": "Gut erhaltenes Rad.\nNur Abholung.", "url": "", "posted_at": now},
                     {"id": "sb-3", "topic": "Biete", "title": "Alter Tisch", "text": "Holz.", "url": "javascript:alert(1)", "posted_at": "2020-01-01T09:00:00"}]
        sb.store(d, conn, now)
        mid = conn.execute("INSERT INTO modules(name, color) VALUES ('Browser-Analysis', '#175ee8')").lastrowid
        conn.execute("INSERT INTO courses(id, title, module_id, active, created_at) VALUES ('c-browser', 'Browser-Analysis I', ?, 1, 't')", (mid,))
        studip_texts.ensure_tables(conn)
        conn.execute("INSERT INTO studip_texts(id, course_id, kind, title, text, url, changed, fetched_at) VALUES "
                     "('wiki-browser', 'c-browser', 'wiki', 'Formelsammlung', ?, 'https://studip.test/wiki', ?, 't')", (LONG, TODAY))
        conn.execute("INSERT INTO studip_texts(id, course_id, kind, title, text, url, changed, fetched_at) VALUES "
                     "('cw-browser', 'c-browser', 'courseware', 'Grenzwerte', 'Text', NULL, ?, 't')", (TODAY,))
    yield mid
    with db.cursor() as conn:
        conn.execute("DELETE FROM announcements WHERE id='sp-news-g-browser'")
        conn.execute("DROP TABLE IF EXISTS studip_messages")
        conn.execute("DROP TABLE IF EXISTS studip_bulletin")
        conn.execute("DELETE FROM settings WHERE key IN ('studip_bulletin_topics', 'studip_bulletin_fetched_at', 'studip_missing_endpoints')")
        conn.execute("DELETE FROM studip_texts WHERE course_id='c-browser'")
        conn.execute("DELETE FROM courses WHERE id='c-browser'")
        conn.execute("DELETE FROM modules WHERE name='Browser-Analysis'")


def _page(browser, base, route):
    context = browser.new_context(bypass_csp=True, viewport={"width": 1280, "height": 900}, service_workers="block")
    page = context.new_page()
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
    page.goto(base + route)
    return page, errors


def test_news_card_and_bulletin_line_on_the_overview(served, seeded):
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        pytest.skip("Playwright fehlt")
    with sync_playwright() as p:
        browser = _browser(p)
        if browser is None:
            pytest.skip("kein Chromium fuer Playwright")
        try:
            page, errors = _page(browser, served, "/#/dashboard")
            page.wait_for_selector(".news-card", timeout=20000)
            card = page.inner_text(".news-card")
            assert "Neuigkeiten" in card and "Tutorium entfällt" in card and "Rückmeldung zum Sommersemester" in card
            assert page.inner_text(".news-bulletin") == "Schwarzes Brett: 2 neue Anzeigen", "nur Anzeigen der letzten sieben Tage"
            assert page.query_selector(".ov-rest > .ov-card .ann-item:not(.news-item)") is None, "die alte Karte 'Ankündigungen' ist ersetzt"
            # aufklappen: ganzer Text
            page.click(".news-item:has-text('Tutorium entfällt') summary")
            assert "das Tutorium fällt aus." in page.inner_text(".news-item[open] .body")
            # Alle anzeigen: Fenster mit Filter-Chips; Nachrichten filtern
            page.click("#newsAll")
            page.wait_for_selector(".modal [data-nf]")
            assert "Nachrichten 1" in page.inner_text(".modal")
            page.click(".modal [data-nf='nachricht']")
            assert page.locator(".modal .news-item").count() == 1
            assert "nicht als gelesen" in page.inner_text(".modal")
            page.click(".modal [data-close]")
            # Zeile fuehrt zu Uni & Noten
            page.click(".news-bulletin")
            page.wait_for_function("location.hash === '#/services'")
            assert errors == []
        finally:
            browser.close()


def test_bulletin_card_and_reader_under_uni_und_noten(served, seeded):
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        pytest.skip("Playwright fehlt")
    with sync_playwright() as p:
        browser = _browser(p)
        if browser is None:
            pytest.skip("kein Chromium fuer Playwright")
        try:
            page, errors = _page(browser, served, "/#/services")
            page.wait_for_selector(".bb-card", timeout=20000)
            text = page.inner_text(".bb-card")
            assert "Schwarzes Brett" in text and "Alle 3" in text and "Biete 2" in text and "Wohnliches 1" in text
            assert TITLE in text and "Wort300\nLetzter Absatz." in text.replace("\r", ""), "ganzer Titel und ganzer Text in der Liste"
            assert "…" not in text
            assert "Namen der Anbietenden holt StudiNow nicht" in text
            # Thema filtert
            page.click(".bb-card [data-btopic='Biete']")
            assert page.locator(".bb-card .bb-entry").count() == 2
            # Leser
            page.click(".bb-card .bb-entry:has-text('Fahrrad zu verkaufen')")
            page.wait_for_selector(".modal .bb-reader")
            assert "Gut erhaltenes Rad." in page.inner_text(".modal .bb-reader")
            assert "Antworten und Kontakt über die Anzeige in Stud.IP." in page.inner_text(".modal")
            page.click(".modal [data-close]")
            # Anzeige mit gefaehrlichem Link: kein Link
            page.click(".bb-card .bb-entry:has-text('Alter Tisch')")
            page.wait_for_selector(".modal .bb-reader")
            assert page.locator(".modal a[href^='javascript']").count() == 0
            page.click(".modal [data-close]")
            # Brett steht vor den Uni-Diensten
            order = page.evaluate("[...document.querySelectorAll('#view h2')].map(h => h.textContent.trim())")
            assert order.index("Schwarzes Brett") < order.index("Uni-Dienste"), order
            assert errors == []
        finally:
            browser.close()


def test_no_bulletin_card_without_ads(served, app):
    """Ohne gespeicherte Anzeigen bleibt der Platz leer (kein Rahmen, keine Zeile)"""
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        pytest.skip("Playwright fehlt")
    from app import db
    db.init_db()
    with sync_playwright() as p:
        browser = _browser(p)
        if browser is None:
            pytest.skip("kein Chromium fuer Playwright")
        try:
            page, errors = _page(browser, served, "/#/services")
            page.wait_for_selector("#bulletinHost", state="attached", timeout=20000)
            page.wait_for_function("document.querySelector('#bulletinHost') && document.querySelector('.card-head') !== null")
            assert page.inner_html("#bulletinHost").strip() == ""
            assert errors == []
        finally:
            browser.close()


def test_studip_texts_in_the_module_view(served, seeded):
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        pytest.skip("Playwright fehlt")
    with sync_playwright() as p:
        browser = _browser(p)
        if browser is None:
            pytest.skip("kein Chromium fuer Playwright")
        try:
            page, errors = _page(browser, served, f"/#/modules/{seeded}")
            page.wait_for_selector(".st-card", timeout=20000)
            head = page.inner_text(".st-head")
            assert "Aus Stud.IP" in head and "Courseware 1 · Wiki 1" in head, head
            assert page.locator(".st-line").count() == 0, "zugeklappt"
            page.click("#stToggle")
            assert page.locator(".st-line").count() == 2
            page.click(".st-line[data-stkind='wiki']")
            assert "Formelsammlung" in page.inner_text(".st-items")
            page.click(".st-item[data-stid='wiki-browser']")
            page.wait_for_selector(".modal .bb-reader")
            assert "Wort300\nLetzter Absatz." in page.inner_text(".modal .bb-reader").replace("\r", "")
            assert "In Stud.IP öffnen" in page.inner_text(".modal")
            page.click(".modal [data-close]")
            assert errors == []
        finally:
            browser.close()
