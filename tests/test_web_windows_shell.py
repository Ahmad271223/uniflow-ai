"""Windows-/Web-Oberflaeche im echten Browser (05.11.2026, Paket A: iPad-Stand vom 04./05.11.): Seite "Nachrichten" mit Menuepunkt,
Zaehler, Suche, Lesebereich und Link nach Stud.IP; Demo nur ueber den kleinen Link auf der ersten Seite ohne Hochschulverbindung
und die schmale Leiste mit "Beenden"; keine Kauf- und Bezahllinks im Einzelplatz. Ohne Chromium wird uebersprungen."""
import json

import pytest
from test_pwa import _browser, served  # noqa: F401  (Fixture `served`)

DASHBOARD = "document.querySelector('#view') && /Guten|Heute|Willkommen/.test(document.querySelector('#view').textContent)"
URL = "https://studip.uni-hannover.de/dispatch.php/messages/overview"


@pytest.fixture
def inbox(app):
    from app import db, studip_extras
    db.init_db()
    items = [
        {"id": "sp-msg-1", "sender": "Lehrende", "subject": "Tutorium entfällt am 12.11.", "sent_at": "2026-11-02T08:15:00+01:00", "url": URL,
         "preview": "Das Tutorium am 12.11. fällt aus.\nBitte Blatt 3 allein bearbeiten.", "dates": [{"date": "2099-11-12", "time": None, "kind": "ausfall"}]},
        {"id": "sp-msg-2", "sender": "Verwaltung", "subject": "Prüfung angemeldet", "sent_at": "2026-11-04T10:00:00+01:00", "url": URL,
         "preview": "Deine Anmeldung zur Klausur ist bestätigt.", "dates": []},
    ]
    with db.cursor() as conn:
        studip_extras.store_messages(conn, items, "2026-11-05T07:30:00+00:00")
        conn.execute("DELETE FROM settings WHERE key='messages_seen_up_to'")
    yield items
    with db.cursor() as conn:
        conn.execute("DELETE FROM studip_messages")
        conn.execute("DELETE FROM settings WHERE key='messages_seen_up_to'")


def _run(served, fn, width=1280, height=800, hash_="#/dashboard", routes=None):
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
            requests = []
            page.on("request", lambda r: requests.append((r.method, r.url)))
            for pattern, body in (routes or {}).items():
                page.route(pattern, lambda route, request, body=body: route.fulfill(status=200, content_type="application/json", body=json.dumps(body)))
            page.goto(served + "/" + hash_)
            page.wait_for_selector("#nav a[data-route=dashboard]", timeout=20000)
            return fn(page, requests)
        finally:
            browser.close()


# ---------------------------------------------------------------- Nachrichten

def test_nav_item_hidden_without_messages_or_connection(served):
    def check(page, _):
        page.wait_for_function(DASHBOARD, timeout=20000)
        page.wait_for_timeout(800)
        assert page.query_selector("#nav a[data-route=messages]") is None, "ohne Verbindung und ohne Nachrichten kein Menuepunkt"
    _run(served, check)


def test_messages_page_wide(served, inbox):
    def check(page, requests):
        page.wait_for_selector("#nav a[data-route=messages]", timeout=15000)
        labels = page.eval_on_selector_all("#nav a", "els => els.map(e => e.dataset.route)")
        assert labels.index("messages") == labels.index("dashboard") + 1, "direkt nach der Uebersicht"
        assert page.text_content("#nav a[data-route=messages] .msg-count").strip() == "2", "zwei neue"
        page.click("#nav a[data-route=messages]")
        page.wait_for_selector(".msg-row", timeout=10000)
        rows = page.query_selector_all(".msg-row")
        assert len(rows) == 2 and "Prüfung angemeldet" in rows[0].inner_text(), "neueste zuerst"
        assert all("fresh" in (r.get_attribute("class") or "") for r in rows), "beim ersten Besuch beide neu"
        # breit: Liste und Lesebereich nebeneinander, die erste Nachricht ist offen
        assert page.text_content(".msg-title") == "Prüfung angemeldet"
        list_box = page.eval_on_selector("#msgList", "e => e.getBoundingClientRect().toJSON()")
        reader_box = page.eval_on_selector("#msgReader", "e => e.getBoundingClientRect().toJSON()")
        assert reader_box["left"] >= list_box["right"] - 1 and abs(reader_box["top"] - list_box["top"]) < 2
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        # zweite Nachricht lesen: ganzer Text mit Zeilenumbruch, Chip, Link in den Posteingang
        rows[1].click()
        page.wait_for_function("document.querySelector('.msg-title').textContent.startsWith('Tutorium')")
        text = page.text_content(".msg-text")
        assert "Das Tutorium am 12.11. fällt aus." in text and "Bitte Blatt 3 allein bearbeiten." in text
        assert "white-space: pre-wrap" in page.eval_on_selector(".msg-text", "e => getComputedStyle(e).whiteSpace === 'pre-wrap' ? 'white-space: pre-wrap' : ''")
        assert "Ausfall? 12.11." in page.text_content(".msg-chips")
        link = page.query_selector("#msgReader a.btn")
        assert link.get_attribute("href") == URL and link.get_attribute("target") == "_blank" and "noopener" in link.get_attribute("rel")
        assert "In Stud.IP öffnen" in link.inner_text()
        assert "markiert sie in Stud.IP nicht als gelesen" in page.text_content("#msgReader")
        # Zaehler ist weg, Marke steht auf dem Server
        page.wait_for_function("!document.querySelector('#nav a[data-route=messages] .msg-count')", timeout=5000)
        seen = page.evaluate("fetch('/api/studip/messages').then(r => r.json())")
        assert seen["new_count"] == 0 and seen["seen_up_to"] == "2026-11-04T10:00:00+01:00"
        # Suche (ohne Akzente), kein Treffer
        page.fill("#msgQ", "PRUFUNG")
        page.wait_for_function("document.querySelectorAll('.msg-row').length === 1", timeout=5000)
        assert "Prüfung angemeldet" in page.text_content(".msg-row")
        page.fill("#msgQ", "gibtsnicht")
        page.wait_for_selector(".msg-none", timeout=5000)
        assert "Keine Treffer für „gibtsnicht“" in page.text_content(".msg-none")
        # nie Einzelansicht, nie Markieren in Stud.IP: nur diese Pfade gingen an den Server
        api = {u.split("/api/", 1)[1].split("?")[0] for m, u in requests if "/api/studip/messages" in u}
        assert api <= {"studip/messages", "studip/messages/status", "studip/messages/seen"}, api
        assert not [u for m, u in requests if "studip.uni-hannover.de" in u], "die Seite fragt nie bei Stud.IP an"
    _run(served, check)


def test_messages_page_narrow_list_then_reader_with_back(served, inbox):
    def check(page, _):
        page.goto(page.url.split("#")[0] + "#/messages")
        page.wait_for_selector(".msg-row", timeout=15000)
        assert page.is_visible("#msgList") and not page.is_visible("#msgReader"), "schmal erst die Liste"
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        page.click(".msg-row >> nth=1")
        page.wait_for_selector(".msg-back", state="visible")
        assert not page.is_visible("#msgList") and "Tutorium" in page.text_content(".msg-title")
        page.click(".msg-back")
        page.wait_for_selector("#msgList", state="visible")
        assert not page.is_visible("#msgReader")
    _run(served, check, width=390, height=844)


def test_messages_empty_state_when_connected_but_nothing_stored(served, monkeypatch):
    from app import studip_messages
    monkeypatch.setattr(studip_messages, "stud_ip_connected", lambda: True)

    def check(page, _):
        page.wait_for_selector("#nav a[data-route=messages]", timeout=15000)
        assert page.query_selector("#nav a[data-route=messages] .msg-count") is None
        page.click("#nav a[data-route=messages]")
        page.wait_for_selector("#msgEmpty", timeout=10000)
        assert "Keine Nachrichten" in page.text_content("#msgEmpty") and "Noch nicht mit Stud.IP abgeglichen" in page.text_content("#msgEmpty")
        assert page.query_selector("#msgSync") is not None
    _run(served, check)


# ---------------------------------------------------------------- Demo nur fuer die Store-Pruefung

FRESH = {"**/api/modules": [], "**/api/university/session": {"session": False, "saved_at": None, "window": {}, "name": "STUDIP_COOKIES", "hosted": False},
         "**/api/credentials": {"user": "", "password_set": False}}


def test_demo_link_bar_and_end(served):
    from app import db, demo

    def check(page, requests):
        page.wait_for_selector("#demoStart", timeout=20000)
        link = page.query_selector("#demoStart")
        assert link.inner_text() == "Ohne Hochschulkonto ansehen (Demo)"
        assert link.evaluate("e => e.tagName") == "BUTTON" and "btn" not in (link.get_attribute("class") or "")
        size = link.evaluate("e => parseFloat(getComputedStyle(e).fontSize)")
        assert size <= 13, f"kleiner Link, kein Knopf ({size}px)"
        connect = page.eval_on_selector("#firstStart a.btn", "e => e.getBoundingClientRect().bottom")
        assert link.evaluate("e => e.getBoundingClientRect().top") > connect, "unter dem Verbinden-Knopf"
        assert page.evaluate("document.querySelector('#view .content').lastElementChild.id") == "firstStart", "ganz unten auf der Seite"
        assert page.query_selector("#demoBar") is None, "ohne Demo keine Leiste"
        # Demo starten
        link.click()
        page.wait_for_selector("#demoBar", timeout=15000)
        bar = page.text_content("#demoBar")
        assert "Demo-Inhalte – erfunden, ohne Hochschule" in bar and "Beenden" in bar
        assert page.evaluate("fetch('/api/demo').then(r => r.json())")["enabled"] is True
        # die Leiste bleibt auf jeder Seite, der Link ist weg
        page.goto(page.url.split("#")[0] + "#/files")
        page.wait_for_selector("#demoBar")
        assert page.query_selector("#demoStart") is None
        # kein Abgleich mit der Hochschule waehrend der Demo
        before = len([1 for m, u in requests if m == "POST" and u.endswith("/api/sync")])
        page.click("#syncBtn")
        page.wait_for_selector("#toastEl:has-text('Zum Anmelden die Demo oben mit')", timeout=5000)
        assert len([1 for m, u in requests if m == "POST" and u.endswith("/api/sync")]) == before
        # Beenden fragt nach, raeumt alles weg und fuehrt zur ersten Seite zurueck
        page.click("#demoEnd")
        page.wait_for_selector("#demoEndYes")
        page.click("#demoEndYes")
        page.wait_for_selector("#demoBar", state="detached", timeout=10000)
        assert page.evaluate("fetch('/api/demo').then(r => r.json())") == {**page.evaluate("fetch('/api/demo').then(r => r.json())"), "enabled": False, "files": 0, "events": 0, "packages": 0}
        page.wait_for_selector("#demoStart", timeout=15000)
        assert page.url.endswith("#/dashboard")
    try:
        _run(served, check, routes=FRESH)
    finally:
        with db.cursor() as conn:
            demo.remove(conn)


def test_demo_link_absent_once_the_university_is_connected(served):
    def check(page, _):
        page.wait_for_function(DASHBOARD, timeout=20000)
        page.wait_for_timeout(1200)
        assert page.query_selector("#demoStart") is None and page.query_selector("#firstStart") is None
    _run(served, check, routes={**FRESH, "**/api/university/session": {"session": True, "saved_at": "2026-11-05T08:00:00+00:00", "window": {}, "name": "STUDIP_COOKIES", "hosted": False}})


def test_demo_not_in_settings_any_more(served):
    """Die Demo gibt es nur ueber den Link der ersten Seite (Entscheidung 04.11.2026 "Nur fuer Pruefer"), nicht mehr unter Einstellungen."""
    def check(page, _):
        page.goto(page.url.split("#")[0] + "#/settings?tab=diag")
        page.wait_for_selector("#diagCopy", timeout=15000)
        assert page.query_selector("#demoToggle") is None and "Demo-Inhalte anlegen" not in page.text_content("#view")
    _run(served, check)


# ---------------------------------------------------------------- Store-Tauglichkeit

def test_no_purchase_or_payment_links_in_single_user_mode(served):
    """Microsoft-Store: im Einzelplatzmodus nirgends ein Kauf-, Abo-Abschluss- oder Bezahllink (auch nicht auf der Tarifseite)."""
    def check(page, requests):
        bad_href = "stripe|checkout|paypal|pay\\.|buy|kaufen|billing/portal|apps\\.apple|itunes|play\\.google"
        for hash_ in ("#/dashboard", "#/abo", "#/settings", "#/settings?tab=account", "#/services", "#/community", "#/cards"):
            page.goto(page.url.split("#")[0] + hash_)
            page.wait_for_timeout(900)
            hrefs = page.eval_on_selector_all("a[href]", "els => els.map(e => e.getAttribute('href'))")
            hits = [h for h in hrefs if __import__("re").search(bad_href, h or "", __import__("re").I)]
            assert not hits, (hash_, hits)
            assert page.query_selector("[data-buy], #aboPortal, [data-portal]") is None, hash_
            buttons = page.eval_on_selector_all("#view button, #view a.btn", "els => els.map(e => e.textContent.trim())")
            assert not [b for b in buttons if __import__("re").search("kaufen|abschließen|bezahlen|zahlung|abonnieren|upgrade|plus holen|pro ai holen", b, __import__("re").I)], (hash_, buttons)
            text = page.text_content("#view") or ""
            for word in ("Jetzt kaufen", "Kreditkarte", "Zahlungsdaten", "Plus holen", "Pro AI holen"):
                assert word not in text, (hash_, word)
        assert page.query_selector("#sideAcct .side-acct-cta") is None, "kein 'Plus holen' in der Seitenleiste"
        assert not [u for m, u in requests if "checkout" in u or "/billing/stripe" in u], "kein Aufruf des Bezahlsystems"
        # Tarifseite: ehrlich, ohne Kaufknopf
        page.goto(page.url.split("#")[0] + "#/abo")
        page.wait_for_selector(".abo-term", timeout=10000)
        assert "keine Tarife" in page.text_content(".abo-term")
        assert page.eval_on_selector_all(".plan .btn", "els => els.map(e => e.textContent.trim())") == []
    _run(served, check)
