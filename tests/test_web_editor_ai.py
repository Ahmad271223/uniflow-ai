"""Editor, KI-Oberflaeche und Test-Design im echten Browser (05.11.2026, Paket B, aus den iPad-Aenderungen vom 04./05.11.):
KI-Hilfe im Editor mit drei farbigen Reitern, Antworten als Markdown und Verlauf, Erklaerungsspeicher ("Schon erklaert · 0
Credits", "Neu erklaeren lassen"), "Als Karteikarte" aus markiertem PDF-Text, Formerkennung nach Halten, KI-Start (#/ki),
Dialog "Wochentest erstellen" mit Aufgabenzahl, Schwierigkeit und Aufgabenarten, Testlauf mit Wahr/Falsch und Luecken-
text. Eigener PC (nicht gehostet), KI-Attrappe statt Anbieter, kein echter Aufruf. Ohne Chromium wird uebersprungen."""
import json
import os
import re

import pytest
from test_pageocr import make_pdf
from test_pwa import _browser, served  # noqa: F401
from test_web_community_channel import shot
from test_web_hosted_e2e import _playwright

T = 20000
TEXT = ["Ein Eigenwert ist ein Skalar.", "Das charakteristische Polynom liefert alle Eigenwerte."]
_n = [0]


@pytest.fixture
def doc(app, tmp_path):
    """Dokument mit zwei Textseiten im Modul 'Editor KI Test'; (Datei-ID, Modul-ID)"""
    from app import db, scriptsearch
    _n[0] += 1
    fid, mod = f"ed-ai-{os.getpid()}-{_n[0]}", 9300 + _n[0]
    pdf = make_pdf(tmp_path / f"{fid}.pdf", [TEXT, ["Zweite Seite mit anderem Text."]])
    with db.cursor() as conn:
        scriptsearch.ensure_table(conn)
        conn.execute("INSERT OR IGNORE INTO modules(id, name, color, created_at) VALUES (?, 'Editor KI Test', '#175ee8', '2026-10-26')", (mod,))
        conn.execute("INSERT OR IGNORE INTO courses(id, title, subject, kind, module_id, created_at) VALUES (?, 'Editor KI Kurs', 'Editor KI Test', 'vorlesung', ?, '2026-10-26')", (f"c-{fid}", mod))
        conn.execute("INSERT INTO files(id, course_id, name, kind, status, chdate, local_path, downloaded_at, studip_folder) VALUES (?, ?, 'VL Eigenwerte.pdf', 'pdf', 'neu', 1761900000, ?, '2026-10-30', 'Skript')",
                     (fid, f"c-{fid}", str(pdf)))
    yield fid, mod
    with db.cursor() as conn:
        conn.execute("DELETE FROM flashcards WHERE file_id=?", (fid,))
        conn.execute("DELETE FROM flashcard_stacks WHERE file_id=?", (fid,))
        conn.execute("DELETE FROM annotations WHERE file_id=?", (fid,))
        conn.execute("DELETE FROM files WHERE id=?", (fid,))


@pytest.fixture
def fake_ai(monkeypatch):
    """Die KI des Nutzers antwortet mit Markdown und merkt sich die Prompts."""
    from app import ai
    prompts = []

    def fake(prompt, system):
        prompts.append(prompt)
        return f"## Antwort {len(prompts)}\n\n- **Punkt** eins\n- Punkt zwei"
    monkeypatch.setattr(ai, "ask", fake)
    return prompts


def open_page(base, hash_, sync_p):
    browser = _browser(sync_p)
    if browser is None:
        pytest.skip("kein Chromium fuer Playwright")
    ctx = browser.new_context(bypass_csp=True, service_workers="block", viewport={"width": 1280, "height": 900})
    page = ctx.new_page()
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.goto(f"{base}/#{hash_}")
    return browser, page, errors


EDITOR_READY = "window.__app && __app.state.editors.length === 1 && !!__app.state.editors[0].model && !__app.state.editors[0].destroyed && __app.state.editors[0].pages.length === 2"


def test_ai_panel_tabs_markdown_history_and_stored_explanations(served, doc, fake_ai):  # noqa: F811
    fid, _ = doc
    with _playwright() as p:
        browser, page, errors = open_page(served, f"/doc/{fid}", p)
        try:
            page.wait_for_function(EDITOR_READY, timeout=T)
            page.click("[data-act=ai]")
            page.wait_for_selector(".ed-ai:not([hidden])", timeout=T)
            # drei Reiter, Erklaeren zuerst; Reiter wechseln zeigt jeweils nur die eigenen Aktionen
            tabs = page.locator(".ed-ai-tab")
            assert [t.strip() for t in tabs.all_inner_texts()] == ["Erklären", "Karteikarten", "Test"]
            assert page.get_attribute("#edAiTab-explain", "aria-selected") == "true" and page.is_visible("[data-pane=explain]")
            page.click("#edAiTab-cards")
            assert page.is_visible("[data-pane=cards]") and page.is_hidden("[data-pane=explain]") and "Karteikarten zur Seite erstellen" in page.inner_text("[data-pane=cards]")
            page.click("#edAiTab-test")
            assert page.is_visible("[data-mode=similar]") and page.is_visible("[data-mode=check]") and page.locator(".ed-ai a[href='#/exams']").count() == 1
            page.click("#edAiTab-explain")
            shot(page, "editor-ki-reiter")
            assert page.get_attribute(".ed-ai-start", "href") == "#/ki"
            # Erklaeren: Antwort als Markdown (Titel, Liste, Fett), die Seite steht in der Fusszeile
            page.click("[data-mode=explain]")
            page.wait_for_selector(".ed-ai-bot h3", timeout=T)
            assert page.inner_text(".ed-ai-bot h3") == "Antwort 1" and page.locator(".ed-ai-bot > ul > li").count() == 2 and page.inner_text(".ed-ai-bot b") == "Punkt"
            assert page.inner_text(".ed-ai-me") == "Erklären" and page.inner_text(".ed-ai-foot").startswith("Seite 1")
            assert len(fake_ai) == 1 and page.locator(".ed-ai-stored").count() == 0
            # dasselbe noch einmal: sofort aus dem Erklaerungsspeicher, kein zweiter KI-Aufruf
            page.click("[data-mode=explain]")
            page.wait_for_selector(".ed-ai-stored", timeout=T)
            assert "Schon erklärt · 0 Credits" in page.inner_text(".ed-ai-stored") and len(fake_ai) == 1
            assert "Schon erklärt · 0 Credits" in page.inner_text(".ed-ai-foot")
            # "Neu erklaeren lassen" fragt live nach (die neue Antwort ist keine gespeicherte)
            page.click(".ed-ai-rebuild")
            page.wait_for_function("document.querySelectorAll('.ed-ai-me').length === 3 && document.querySelector('.ed-ai-out').lastElementChild.classList.contains('ed-ai-bot')", timeout=T)
            assert page.evaluate("document.querySelector('.ed-ai-out').lastElementChild.querySelector('.ed-ai-stored')") is None, "die neue Antwort ist keine gespeicherte"
            assert page.locator(".ed-ai-stored").count() == 1, "die fruehere bleibt als Hinweis im Verlauf"
            assert len(fake_ai) == 2 and "Erklären (neu)" in page.inner_text(".ed-ai-out")
            # freie Frage: Enter sendet, der Verlauf geht mit, Anschlussfragen nur unter der letzten Antwort
            page.fill(".ed-ai-q", "Was ist ein Skalar?")
            page.press(".ed-ai-q", "Enter")
            page.wait_for_function("document.querySelectorAll('.ed-ai-bot h3').length === 4", timeout=T)
            assert len(fake_ai) == 3 and "Was ist ein Skalar?" in page.inner_text(".ed-ai-me >> nth=3")
            assert "Antwort 2" in fake_ai[2] and "Erklären (neu)" in fake_ai[2], "bisheriges Gespraech als history im Prompt"
            assert page.locator(".ed-ai-fu").count() == 1 and page.locator(".ed-ai-fu button").count() >= 2
            # Anschlussfrage "Ein Beispiel dazu" schickt die vorbereitete Frage
            page.click(".ed-ai-fu button:has-text('Ein Beispiel dazu')")
            page.wait_for_function("document.querySelectorAll('.ed-ai-bot h3').length === 5", timeout=T)
            assert "konkretes Beispiel" in fake_ai[3]
            # "Lösung prüfen": Feld wird zur Loesung, Senden pruefen; "Neu" leert das Gespraech
            page.click("#edAiTab-test"); page.click("[data-mode=check]")
            assert page.is_visible(".ed-ai-checkpill") and "Lösung" in page.get_attribute(".ed-ai-q", "placeholder")
            page.fill(".ed-ai-q", "x = 3"); page.press(".ed-ai-q", "Enter")
            page.wait_for_function("document.querySelectorAll('.ed-ai-bot h3').length === 6", timeout=T)
            assert "x = 3" in fake_ai[4] and page.is_hidden(".ed-ai-checkpill")
            shot(page, "editor-ki-verlauf")
            page.click(".ed-ai-new")
            assert page.locator(".ed-ai-me").count() == 0 and "Frag etwas zur offenen Seite" in page.inner_text(".ed-ai-out")
            assert not errors, errors
        finally:
            browser.close()


def test_ai_error_keeps_the_question_and_does_not_break(served, doc, monkeypatch):  # noqa: F811
    from app import ai
    monkeypatch.setattr(ai, "ask", lambda prompt, system: (_ for _ in ()).throw(ai.AIError("Die KI ist gerade nicht erreichbar.")))
    fid, _ = doc
    with _playwright() as p:
        browser, page, errors = open_page(served, f"/doc/{fid}", p)
        try:
            page.wait_for_function(EDITOR_READY, timeout=T)
            page.click("[data-act=ai]")
            page.fill(".ed-ai-q", "Warum?"); page.press(".ed-ai-q", "Enter")
            page.wait_for_selector(".ed-ai-out .ed-err", timeout=T)
            assert "nicht erreichbar" in page.inner_text(".ed-err")
            assert page.input_value(".ed-ai-q") == "Warum?", "die Frage steht wieder im Feld"
            assert page.locator(".ed-ai-me").count() == 0 and page.is_enabled(".ed-ai-go")
        finally:
            browser.close()


def test_card_from_marked_text_and_ai_from_marked_text(served, doc, fake_ai):  # noqa: F811
    fid, _ = doc
    with _playwright() as p:
        browser, page, errors = open_page(served, f"/doc/{fid}", p)
        try:
            page.wait_for_function(EDITOR_READY, timeout=T)
            sel = "(async () => { const ed = __app.state.editors[0]; await ed.textSelection(ed.pages[0], { x: 0, y: 0, w: 595, h: 300 }); })()"
            page.evaluate(sel)
            page.wait_for_selector("[data-mk=card]", timeout=T)
            assert page.locator("[data-mk=ai]").count() == 1
            page.click("[data-mk=card]")
            page.wait_for_selector("#edCardForm", timeout=T)
            q = page.input_value("#edCardForm [name=question]")
            assert "Eigenwert ist ein Skalar" in q and "charakteristische Polynom" in q and "\n" not in q, q
            page.click("#edCardForm [type=submit]")
            assert "nötig" in page.inner_text("#edCardErr"), "ohne Antwort geht es nicht"
            page.fill("#edCardForm [name=answer]", "Ein Skalar λ mit A v = λ v.")
            page.click("#edCardForm [type=submit]")
            page.wait_for_selector("#edCardForm", state="detached", timeout=T)
            cards = json.loads(page.evaluate("fetch('/api/flashcards').then(r => r.text())"))
            mine = [c for c in cards if c["file_id"] == fid]
            assert len(mine) == 1 and mine[0]["answer"].startswith("Ein Skalar") and "Eigenwert" in mine[0]["question"]
            # "An den KI-Tutor": Panel geht auf, die Markierung wird erklaert (Zitat in der Blase)
            page.evaluate(sel)
            page.wait_for_selector("[data-mk=ai]", timeout=T)
            page.click("[data-mk=ai]")
            page.wait_for_selector(".ed-ai-bot h3", timeout=T)
            assert page.is_visible(".ed-ai") and "Eigenwert ist ein Skalar" in page.inner_text(".ed-ai-quote")
            assert "MARKIERTER TEXT" in fake_ai[0].upper() or "Eigenwert ist ein Skalar" in fake_ai[0]
            assert not errors, errors
        finally:
            browser.close()


def _draw(page, pts, hold_ms=0, box=None):
    x0, y0 = box["x"], box["y"]
    page.mouse.move(x0 + pts[0][0], y0 + pts[0][1])
    page.mouse.down()
    for x, y in pts[1:]:
        page.mouse.move(x0 + x, y0 + y)
    if hold_ms:
        page.wait_for_timeout(hold_ms)
    page.mouse.up()


def _along(vertices, closed=False, step=6):
    v = vertices + [vertices[0]] if closed else vertices
    out = []
    for (ax, ay), (bx, by) in zip(v, v[1:]):
        n = max(1, int(((bx - ax) ** 2 + (by - ay) ** 2) ** 0.5 / step))
        out += [(ax + (bx - ax) * k / n, ay + (by - ay) * k / n) for k in range(n)]
    return out + [v[-1]]


def test_shape_snapping_after_holding_the_pen(served, doc):  # noqa: F811
    fid, _ = doc
    with _playwright() as p:
        browser, page, errors = open_page(served, f"/doc/{fid}", p)
        try:
            page.wait_for_function(EDITOR_READY, timeout=T)
            page.click("[data-tool=pen]")
            page.wait_for_selector("[data-snap]", timeout=T)
            assert page.get_attribute("[data-snap]", "aria-pressed") == "true", "Standard: an"
            z = page.evaluate("__app.state.editors[0].zoom")
            box = page.locator(".ed-pages .ed-page, .ed-page").first.bounding_box()
            rect = [(60 * z, 80 * z), (260 * z, 80 * z), (260 * z, 180 * z), (60 * z, 180 * z)]
            objs = "() => __app.state.editors[0].model.pages[__app.state.editors[0].pages[0].key].objects"
            # 1. gehalten: Rechteck mit scharfen Ecken, bleibt ein Strich
            _draw(page, _along(rect, closed=True, step=8 * z), hold_ms=800, box=box)
            page.wait_for_function(f"({objs})().length === 1", timeout=T)
            o = page.evaluate(f"({objs})()[0]")
            assert o["type"] == "stroke" and "widths" not in o
            xs, ys = o["points"][0::2], o["points"][1::2]
            assert abs((max(xs) - min(xs)) - 200) < 8 and abs((max(ys) - min(ys)) - 100) < 8, "Rechteck 200 x 100"
            first = (o["points"][0], o["points"][1])
            assert sum(1 for i in range(0, len(o["points"]), 2) if (o["points"][i], o["points"][i + 1]) == first) >= 3, "Ecke dreifach"
            # 2. ohne Halten bleibt der Strich, wie er gezeichnet wurde (viele Zwischenpunkte)
            _draw(page, _along([(60 * z, 300 * z), (260 * z, 300 * z), (260 * z, 400 * z), (60 * z, 400 * z)], closed=True, step=8 * z), hold_ms=0, box=box)
            page.wait_for_function(f"({objs})().length === 2", timeout=T)
            raw = page.evaluate(f"({objs})()[1]")
            f2 = (raw["points"][0], raw["points"][1])
            assert sum(1 for i in range(0, len(raw["points"]), 2) if (raw["points"][i], raw["points"][i + 1]) == f2) < 3, "keine scharfen Ecken: der Strich blieb, wie er war"
            ys2 = raw["points"][1::2]
            assert abs((max(ys2) - min(ys2)) - 100) < 12
            # 3. abgeschaltet: auch mit Halten bleibt es ein einfacher Strich
            page.click("[data-snap]")
            assert page.get_attribute("[data-snap]", "aria-pressed") == "false"
            _draw(page, _along([(300 * z, 80 * z), (500 * z, 80 * z)], step=8 * z), hold_ms=800, box=box)
            page.wait_for_function(f"({objs})().length === 3", timeout=T)
            line = page.evaluate(f"({objs})()[2]")
            assert len(line["points"]) < 120 and not any(line["points"][i] == line["points"][0] and line["points"][i + 1] == line["points"][1] for i in range(2, len(line["points"]), 2))
            assert not errors, errors
        finally:
            browser.close()


def test_ai_start_page_conversation_help_and_recents(served, fake_ai, doc):  # noqa: F811
    with _playwright() as p:
        browser, page, errors = open_page(served, "/ki", p)
        try:
            page.wait_for_selector("#aiRoot", timeout=T)
            assert "Was möchtest du heute lernen?" in page.inner_text("#aiHead")
            assert page.locator(".ai-pill").count() == 5 and page.get_attribute("#aiRoot", "data-layout") == "start"
            assert [t.strip() for t in page.locator(".ai-pill-t b").all_inner_texts()] == ["Fragen", "Karteikarten", "Erklären / PDF analysieren", "Wochentest", "Hilfe"]
            # Hilfe fragt keine KI
            page.click("[data-act=help]")
            page.wait_for_selector("#aiHelp:not([hidden])", timeout=T)
            assert "ohne KI · 0 Credits" in page.inner_text("#aiHelp") and len(fake_ai) == 0
            page.click("#aiHelp [data-ex='0']")
            assert page.input_value("#aiQ").startswith("Erkläre mir diese Seite")
            page.fill("#aiQ", "Erkläre mir den Satz von Bolzano")
            page.press("#aiQ", "Enter")
            page.wait_for_selector(".ai-md h3", timeout=T)
            assert page.get_attribute("#aiRoot", "data-layout") == "chat" and page.is_hidden("#aiHead") and page.is_visible("#aiNew")
            assert page.inner_text(".ai-me") == "Erkläre mir den Satz von Bolzano" and page.inner_text(".ai-md h3") == "Antwort 1"
            assert "1 Anfrage diesen Monat" in page.inner_text("#aiStatus") and page.input_value("#aiQ") == ""
            assert page.is_hidden("#aiHelp"), "Antwort schliesst die Hilfe"
            # Anschlussfrage im selben Gespraech: der Verlauf geht mit
            shot(page, "ki-gespraech")
            page.click("[data-fu]:has-text('Ein Beispiel dazu')")
            page.wait_for_function("document.querySelectorAll('.ai-md h3').length === 2", timeout=T)
            assert "Erkläre mir den Satz von Bolzano" in fake_ai[1] and "Antwort 1" in fake_ai[1]
            # neues Gespraech: Start, die letzte Frage steht unter "Zuletzt" und oeffnet wieder
            page.click("#aiNew")
            assert page.get_attribute("#aiRoot", "data-layout") == "start"
            page.wait_for_selector("#aiRecent:not([hidden]) .ai-rc", timeout=T)
            assert "Bolzano" in page.inner_text("#aiRecent") or "Beispiel" in page.inner_text("#aiRecent")
            page.click("#aiRecent .ai-rc >> nth=0")
            assert page.get_attribute("#aiRoot", "data-layout") == "chat" and page.locator(".ai-md").count() == 1
            # Dokument anhaengen (Vorgabe: das neueste des Moduls), "Erklaeren / PDF analysieren" fasst es zusammen
            page.click("#aiNew")
            shot(page, "ki-start")
            assert page.locator("#aiAttach .ai-chip.on").count() == 1 and "VL Eigenwerte.pdf" in page.inner_text("#aiAttach") or page.locator("#aiAttach .ai-chip").count() == 1
            page.click("[data-act=explain]")
            page.wait_for_function("document.querySelectorAll('.ai-md h3').length >= 1", timeout=T)
            assert "Zusammenfassung:" in page.inner_text(".ai-me >> nth=-1")
            assert not errors, errors
        finally:
            browser.close()


def test_ai_start_error_and_entry_points(served, monkeypatch):  # noqa: F811
    from app import ai
    monkeypatch.setattr(ai, "ask", lambda prompt, system: (_ for _ in ()).throw(ai.AIError("Keine KI verbunden.")))
    with _playwright() as p:
        browser, page, errors = open_page(served, "/ki", p)
        try:
            page.wait_for_selector("#aiRoot", timeout=T)
            page.fill("#aiQ", "Hallo?"); page.press("#aiQ", "Enter")
            page.wait_for_selector("#aiErr:not([hidden])", timeout=T)
            assert "Keine KI verbunden" in page.inner_text("#aiErr") and page.input_value("#aiQ") == "Hallo?"
            assert page.get_attribute("#aiRoot", "data-layout") == "start", "ohne Antwort bleibt es beim Start"
            # Einstiege: Tests-Seite hat den Knopf KI-Start, Karteikarten-Aktion fuehrt zum KI-Auftrag
            page.goto(f"{served}/#/exams")
            page.wait_for_selector("#exAi", timeout=T)
            assert page.get_attribute("#exAi", "href") == "#/ki"
            page.click("#exAi")
            page.wait_for_selector("#aiRoot", timeout=T)
            page.click("[data-act=cards]")
            page.wait_for_function("location.hash.startsWith('#/cards')", timeout=T)
            assert not errors, errors
        finally:
            browser.close()


def test_week_test_dialog_sends_the_chosen_options(served, doc):  # noqa: F811
    fid, mod = doc
    with _playwright() as p:
        browser, page, errors = open_page(served, "/exams", p)
        try:
            seen = []

            def fake(route):
                seen.append(json.loads(route.request.post_data))
                route.fulfill(status=200, content_type="application/json", body='{"started": "Test"}')
            page.route("**/api/tests/generate", fake)
            page.wait_for_selector("#exGen", timeout=T)
            page.click("#exGen")
            page.wait_for_selector("#wtForm", timeout=T)
            assert "Gemeinsamer Test möglich" in page.inner_text("#wtShare") and "15 Aufgaben · 4 leicht · 6 mittel · 5 schwer" in page.inner_text("#wtComp")
            page.select_option("#wtMod", str(mod))
            page.wait_for_function("document.querySelector('#wtMat') && !/geladen/.test(document.querySelector('#wtMat').textContent)", timeout=T)
            page.click("#wtCount [data-v='10']"); page.click("#wtLevel [data-v='schwer']")
            page.click("#wtTypes [data-v='calc']"); page.click("#wtTypes [data-v='short']")
            page.click("#wtDur [data-v='45']")
            shot(page, "wochentest-dialog")
            page.fill("#wtTopic", "  nur Kapitel 3  ")
            assert "10 Aufgaben · alle schwer" in page.inner_text("#wtComp") and "Eigener Test, nicht geteilt" in page.inner_text("#wtShare")
            assert "nur für dich" in page.inner_text("#wtNote")
            page.click("#wtTypes [data-v='mc']"); page.click("#wtTypes [data-v='tf']")      # nur Lückentext uebrig: die letzte Art bleibt an
            assert page.get_attribute("#wtTypes [data-v='cloze']", "aria-checked") == "true"
            page.click("#wtTypes [data-v='cloze']")
            assert page.get_attribute("#wtTypes [data-v='cloze']", "aria-checked") == "true", "mindestens eine Aufgabenart"
            page.click("#wtTypes [data-v='mc']")
            page.click("#wtGo")
            page.wait_for_selector("#wtForm", state="detached", timeout=T)
            assert seen == [{"module_id": mod, "duration_min": 45, "count": 10, "difficulty": "schwer", "types": ["mc", "cloze"], "topic": "nur Kapitel 3"}], seen
            page.wait_for_selector("#exPh", timeout=T)                  # Platzhalterkarte mit dem Stand des Auftrags
            assert "Wochentest wird erstellt" in page.inner_text("#exPh") and "Aufgaben werden erstellt … 10 Aufgaben" in page.inner_text("#exPhLine") and "Eigener Test, nicht geteilt" in page.inner_text("#exPh")
            # #/exams?neu=<Modul> oeffnet den Dialog mit vorgewaehltem Modul
            page.goto(f"{served}/#/exams?neu={mod}")
            page.reload()
            page.wait_for_selector("#wtForm", timeout=T)
            assert page.input_value("#wtMod") == str(mod)
            assert not errors, errors
        finally:
            browser.close()


def test_test_run_shows_true_false_and_cloze(served, doc):  # noqa: F811
    from app import db
    qs = [
        {"nr": 1, "type": "tf", "question": "Jede Matrix hat Eigenwerte.", "options": ["Wahr", "Falsch"], "answer": "Falsch", "points": 10, "difficulty": "leicht", "explanation": "Reelle Matrizen brauchen keine reellen Eigenwerte."},
        {"nr": 2, "type": "cloze", "question": "Das ___ Polynom liefert die Eigenwerte.", "blank": "charakteristische", "answer": "Das charakteristische Polynom liefert die Eigenwerte.", "points": 10, "difficulty": "mittel", "explanation": "Nullstellen von det(A − λI)."},
        {"nr": 3, "type": "mc", "question": "Welche?", "options": ["A", "B", "C"], "answer": "B", "points": 10, "difficulty": "schwer", "explanation": "Weil B."},
    ]
    with db.cursor() as conn:
        tid = conn.execute("INSERT INTO tests(subject, title, duration_min, questions, created_at, started_at) VALUES ('Editor KI Test', 'Wochentest Eigenwerte', 30, ?, '2026-11-05T09:00:00', '2026-11-05T09:00:00')",
                           (json.dumps(qs),)).lastrowid
        done = conn.execute("INSERT INTO tests(subject, title, duration_min, questions, created_at, started_at, submitted_at, answers, score, max_score, feedback) VALUES ('Editor KI Test', 'Fertig', 30, ?, '2026-11-05T09:00:00', '2026-11-05T09:00:00', '2026-11-05T09:20:00', ?, 10, 30, ?)",
                            (json.dumps(qs), json.dumps({"1": "Wahr", "2": "charakteristische", "3": "A"}),
                             json.dumps({"total": 10, "max": 30, "summary": "Ein Drittel.", "weak_topics": [], "per_question": [
                                 {"nr": 1, "points": 0, "max": 10, "feedback": "Falsch."}, {"nr": 2, "points": 10, "max": 10, "feedback": "Richtig."}, {"nr": 3, "points": 0, "max": 10, "feedback": "Leider nicht."}]}))).lastrowid
    try:
        with _playwright() as p:
            browser, page, errors = open_page(served, f"/exams/{tid}", p)
            try:
                page.wait_for_selector(".q", timeout=T)
                # Aufgabe 1: Wahr/Falsch als zwei grosse Flaechen, Antwort waehlen
                assert "Wahr / Falsch" in page.inner_text(".qh") and page.locator(".opt.big").count() == 2 and page.locator(".opt-two").count() == 1
                shot(page, "testlauf-wahrfalsch")
                page.click(".opt.big:has-text('Falsch')")
                page.click("#qNext")
                # Aufgabe 2: einzeiliges Feld fuer die Luecke
                assert "Lückentext" in page.inner_text(".qh") and page.locator("input#qa").count() == 1 and page.locator("textarea#qa").count() == 0
                page.fill("input#qa", "charakteristische")
                page.click("#qNext"); page.click("[data-q='0']")
                assert page.is_checked(".opt.big:has-text('Falsch') input"), "Antwort bleibt beim Zurueckblaettern"
                page.click("[data-q='1']")
                assert page.input_value("input#qa") == "charakteristische"
                # fertiger Test: Ergebnis, richtige Antwort der Luecke = das Wort, Erklaerung der KI
                shot(page, "testlauf-luecke")
                page.goto(f"{served}/#/exams/{done}")
                page.wait_for_selector(".tr-head", timeout=T)
                assert "33 %" in page.inner_text(".tr-head") and "1/3 richtig" in page.inner_text(".tr-head")
                page.click("[data-q='1']")
                fb = page.inner_text(".fb")
                assert "Musterlösung: charakteristische" in fb and "Erklärung: Nullstellen von det" in fb, fb
                page.click("[data-q='0']")
                assert "Erklärung: Reelle Matrizen" in page.inner_text(".fb") and page.locator("#qAsk").count() == 1 and "Frag die KI zu Aufgabe 1" in page.inner_text("#qAsk")
                assert not errors, errors
            finally:
                browser.close()
    finally:
        with db.cursor() as conn:
            conn.execute("DELETE FROM tests WHERE id IN (?, ?)", (tid, done))
