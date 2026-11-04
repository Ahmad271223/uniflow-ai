"""Karteikarten-Stapel im echten Browser (04.11.2026): Pro AI laesst sich Karten fuer eine Lernwoche machen (Vorschau,
abwaehlen, uebernehmen) und teilt den Stapel in der Kurs-Community; ein Plus-Konto sieht im Community-Kanal den Reiter
"Karteikarten" mit dem Stapel der Woche, uebernimmt ihn und hat ihn danach als Stapel "aus der Community"; ohne Pro AI
zeigt "KI-Karteikarten" ein Schloss mit Weg zur Tarifseite. Dienst im gehosteten Modus, KI-Attrappe statt Anbieter.
Ohne Chromium wird uebersprungen."""
import time

import pytest
from test_flashcards_hosted import FakeCardsAI
from test_pwa import _browser
from test_web_community_channel import login, new_user, shot, wait_text
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


def test_ai_cards_share_and_adopt_in_the_browser(served_hosted, monkeypatch):  # noqa: F811
    from app import accounts, ai_backend, scriptsearch
    base = served_hosted
    monkeypatch.setattr(scriptsearch, "page_texts", lambda conn, file_id, *a, **k: ["Rekursion: Basisfall und Rekursionsschritt", "Fakultaet rekursiv"])
    fake = FakeCardsAI()
    ai_backend.set_provider(fake)
    try:
        pro, tp = new_user(base, "pro@example.org")
        accounts.set_plan(pro["id"], "pro_ai")
        plus, tl = new_user(base, "plus@example.org")
        seed(pro)
        seed(plus)
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
                page.wait_for_selector("#fcStacks #stAi", timeout=T)
                # KI-Auftrag: Fach und Woche 3 sind vorgewaehlt, 5 Karten
                page.click("#stAi")
                page.wait_for_selector("#pkWeek", timeout=T)
                assert page.input_value("#pkWeek") == "3" and "Ganzes Modul" in page.inner_text("#pkWeek")
                page.fill("#aiCount", "5")
                page.dispatch_event("#aiCount", "input")
                page.fill("#aiTopic", "Basisfall")
                page.click("#aiGo")
                page.wait_for_selector("[data-keep]", timeout=T)
                assert page.locator("[data-keep]").count() == 5 and "VL03_Rekursion.pdf" in page.inner_text("#aiBody")
                assert "Umfang: Lernwoche 3" in fake.prompts[-1] and "SCHWERPUNKT: Basisfall" in fake.prompts[-1]
                shot(page, "ki-vorschau")
                page.locator("[data-keep]").nth(4).uncheck()
                wait_text(page, "#aiSave", r"Übernehmen \(4\)")
                page.click("#aiSave")
                wait_text(page, "#fcStacks", "4 Karten · 4 fällig · 4 von der KI")
                assert "Woche 3" in page.inner_text("#fcStacks")
                # Teilen: Community des Moduls beitreten, dann teilen
                page.click("[data-share]")
                page.wait_for_selector("#shBody #shTitle", timeout=T)
                page.click("#shJoin")
                page.wait_for_selector("#shGo:not([disabled])", timeout=T)
                assert page.input_value("#shTitle") == "Programmieren I · Woche 3"
                shot(page, "teilen")
                page.click("#shGo")
                wait_text(page, "#toastEl", "Stapel geteilt")
                ctx.close()

                # Plus-Konto: Community-Kanal, Reiter Karteikarten, uebernehmen
                ctx = browser.new_context(bypass_csp=True)
                login(ctx, base, tl)
                page = ctx.new_page()
                page.on("pageerror", lambda e: errors.append(str(e)))
                page.goto(f"{base}/#/cards")
                page.wait_for_selector("#fcStacks #stAi", timeout=T)
                assert "primary" not in page.get_attribute("#stAi", "class") and page.locator("#stAi rect").count() == 1, "Schloss statt Funken"
                page.click("#stAi")
                page.wait_for_selector(".modal a[href='#/abo']", timeout=T)
                assert "Pro AI" in page.inner_text(".modal")
                page.click(".modal button[data-close]")
                # ueber "Aus der Community": beitreten, Stapel der Woche sehen und uebernehmen
                page.click("#stComm")
                page.wait_for_selector("#cdJoin", timeout=T)
                page.click("#cdJoin")
                page.wait_for_selector("#cdList [data-adopt]", timeout=T)
                assert "Programmieren I · Woche 3" in page.inner_text("#cdList") and "4 Karten" in page.inner_text("#cdList")
                page.click(".modal button[data-close]")
                # im Community-Kanal: Reiter Karteikarten mit der Woche
                from app import solution_format as sf
                from app.studip_sync import classify
                key = sf.community_module_key("luh", classify(MODULE)[0])
                page.goto(f"{base}/#/community?space={key}&tab=cards")
                page.wait_for_selector("#ccPanel [data-adopt]", timeout=T)
                assert "Woche 3" in page.inner_text("#ccPanel")
                shot(page, "kanal-karteikarten")
                page.click("#ccPanel [data-adopt]")
                wait_text(page, "#toastEl", "4 Karten übernommen")
                page.goto(f"{base}/#/cards")
                wait_text(page, "#fcStacks", "4 aus der Community")
                shot(page, "stapel")
                assert not errors, errors
            finally:
                browser.close()
    finally:
        ai_backend.set_provider(None)
