"""KI-Karteikarten und geteilte Stapel im echten Browser (04.11.2026, aus der Cloud-Sitzung an das Stapel-Modell
angepasst): Pro AI laesst sich Karten fuer eine Lernwoche machen (Vorschau, abwaehlen, in den Stapel "KI · Woche 3"
speichern) und teilt den Stapel in der Kurs-Community; ein Plus-Konto sieht bei "KI-Karteikarten" ein Schloss mit Weg
zur Tarifseite, findet den Stapel im Community-Kanal im Reiter "Karteikarten" unter Woche 3, uebernimmt ihn und hat ihn
danach als eigenen Stapel. Dienst im gehosteten Modus, KI-Attrappe statt Anbieter. Ohne Chromium wird uebersprungen."""
import time

import pytest
from test_flashcards_hosted import FakeCardsAI
from test_pwa import _browser
from test_web_community_channel import _http, login, new_user, shot, wait_text
from test_web_hosted_e2e import T, _playwright, served_hosted  # noqa: F401

MODULE = "Programmieren I"


def seed(user):
    """Modul mit der Vorlesung der Lehrwoche 3 im Konto, wie nach einem Hochschul-Abgleich."""
    from app import config, db
    tok = config.set_user_context(user["id"], "luh")
    try:
        db.init_db()
        with db.cursor() as conn:
            mid = conn.execute("INSERT INTO modules(name, semester, color) VALUES (?, '', '#175ee8')", (MODULE,)).lastrowid
            conn.execute("INSERT OR REPLACE INTO courses(id, title, kind, active, module_id, created_at) VALUES ('c1', ?, 'vorlesung', 1, ?, '2026-10-26')", (MODULE, mid))
            conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, status, kind, chdate) VALUES ('f3', 'c1', 'VL03_Rekursion.pdf', 'neu', 'pdf', ?)",
                         (int(time.time()),))
    finally:
        config.reset_user_context(tok)


def join(base, token, key):
    assert _http(base, "POST", "/api/community/claims", {"fingerprints": [], "course_keys": [key]}, cookie=token)[0] == 200
    assert _http(base, "POST", f"/api/community/communities/{key}/join", {"kind": "course"}, cookie=token)[0] == 200


def test_ai_cards_share_and_adopt_in_the_browser(served_hosted, monkeypatch):  # noqa: F811
    from app import accounts, ai_backend, scriptsearch
    from app import solution_format as sf
    from app.studip_sync import classify
    base = served_hosted
    key = sf.community_module_key("luh", classify(MODULE)[0])
    monkeypatch.setattr(scriptsearch, "page_texts", lambda conn, file_id, *a, **k: ["Rekursion: Basisfall und Rekursionsschritt", "Fakultaet rekursiv"])
    fake = FakeCardsAI()
    ai_backend.set_provider(fake)
    try:
        pro, tp = new_user(base, "pro@example.org")
        accounts.set_plan(pro["id"], "pro_ai")
        plus, tl = new_user(base, "plus@example.org")
        seed(pro)
        seed(plus)
        join(base, tp, key)
        join(base, tl, key)
        with _playwright() as p:
            browser = _browser(p)
            if browser is None:
                pytest.skip("kein Chromium fuer Playwright")
            try:
                errors = []
                ctx = browser.new_context(bypass_csp=True)
                login(ctx, base, tp)
                page = ctx.new_page()
                page.on("pageerror", lambda e: errors.append(str(e)))
                page.goto(f"{base}/#/cards")
                page.wait_for_selector("#aiOrder", timeout=T)
                # KI-Auftrag: Fach und Woche 3 (Woche mit Unterlagen) sind vorgewaehlt, 5 Karten
                page.click("#aiOrder")
                page.wait_for_selector("#aiWeek option[value='3']", state="attached", timeout=T)
                assert page.input_value("#aiWeek") == "3" and "Ganzes Modul" in page.inner_text("#aiWeek")
                page.fill("#aiCount", "5")
                page.dispatch_event("#aiCount", "input")
                page.fill("#aiTopic", "Basisfall")
                page.click("#aiGo")
                page.wait_for_selector("[data-keep]", timeout=T)
                assert page.locator("[data-keep]").count() == 5 and "VL03_Rekursion.pdf" in page.inner_text("#aiBody")
                assert "Umfang: Lernwoche 3" in fake.prompts[-1] and "SCHWERPUNKT: Basisfall" in fake.prompts[-1]
                assert page.input_value("#aiStack") == "KI · Woche 3"
                shot(page, "ki-vorschau")
                page.locator("[data-keep]").nth(4).uncheck()
                wait_text(page, "#aiSave", r"Speichern \(4\)")
                page.click("#aiSave")
                wait_text(page, "#toastEl", "4 Karten gespeichert")
                wait_text(page, ".fc-tiles", "KI · Woche 3")
                # Teilen ueber das Menue des Stapels (die Community des Moduls ist schon beigetreten)
                page.wait_for_selector(".fc-tile [data-menu]", timeout=T)
                page.click(".fc-tile [data-menu]")
                page.click(".fc-menu-pop [data-share]")
                page.click("#shGo")
                wait_text(page, "#toastEl", "Stapel geteilt")
                ctx.close()

                # Plus-Konto: Schloss beim KI-Auftrag, Reiter Karteikarten im Community-Kanal, uebernehmen
                ctx = browser.new_context(bypass_csp=True)
                login(ctx, base, tl)
                page = ctx.new_page()
                page.on("pageerror", lambda e: errors.append(str(e)))
                page.goto(f"{base}/#/cards")
                page.wait_for_selector("#aiOrder", timeout=T)
                assert page.locator("#aiOrder rect").count() == 1, "Schloss statt Funken"
                page.click("#aiOrder")
                page.wait_for_selector(".modal a[href='#/abo']", timeout=T)
                assert "Pro AI" in page.inner_text(".modal")
                page.click(".modal button[data-close]")
                page.goto(f"{base}/#/community?space={key}&tab=cards")
                page.wait_for_selector("#ccPanel [data-adopt]", timeout=T)
                assert "Woche 3" in page.inner_text("#ccPanel") and "4 Karten" in page.inner_text("#ccPanel")
                shot(page, "kanal-karteikarten")
                page.click("#ccPanel [data-adopt]")
                wait_text(page, "#toastEl", "Übernommen: 4 Karten")
                page.goto(f"{base}/#/cards")
                wait_text(page, ".fc-tiles", "KI · Woche 3")
                shot(page, "stapel")
                assert not errors, errors
            finally:
                browser.close()
    finally:
        ai_backend.set_provider(None)
