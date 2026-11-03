"""Community-Seite im echten Browser (03.11.2026): Kanal nach Lehrwoche mit Karten, Liste, Person und Pfeile, Diskussion,
Korrektur vorschlagen im Editor, Hinweis und Abzeichen beim Ersteller, Loesung daneben ansehen. Zwei Konten im Dienst
(LERNAPP_MODE=hosted), eine PDF mit gleichem Fingerabdruck bei beiden. Ohne Chromium wird uebersprungen."""
import base64
import hashlib
import io
import os

import pytest
from test_pwa import _browser
from test_web_hosted_e2e import T, _http, _playwright, served_hosted  # noqa: F401

MODULE = "Programmieren I"
PASSWORD = "sehr-geheim-123"
EDITOR_READY = "window.__app && __app.state.editors.length === 1 && !!__app.state.editors[0].model && !__app.state.editors[0].destroyed && !!__app.state.editors[0].community"


def make_pdf(pages=2) -> bytes:
    from pypdf import PdfWriter
    w = PdfWriter()
    for _ in range(pages):
        w.add_blank_page(595, 842)
    buf = io.BytesIO()
    w.write(buf)
    return buf.getvalue()


def new_user(base, email):
    from app import accounts
    st, d = _http(base, "POST", "/api/account/register", {"email": email, "password": PASSWORD, "university": "luh"})
    assert st == 201, d
    uid = d["user"]["id"]
    accounts.end_trial(uid)
    accounts.mark_email_verified(uid)
    accounts.set_plan(uid, "plus")
    return d["user"], d["token"]


def seed(user, pdf: bytes, path):
    """Modul 'Programmieren I' mit einem Uebungsblatt (PDF mit Fingerabdruck) im Konto, wie nach einem Hochschul-Abgleich."""
    from app import config, db
    path.write_bytes(pdf)
    tok = config.set_user_context(user["id"], "luh")
    try:
        db.init_db()
        with db.cursor() as conn:
            mid = conn.execute("INSERT INTO modules(name, semester, color) VALUES (?, '', '#175ee8')", (MODULE,)).lastrowid
            conn.execute("INSERT OR REPLACE INTO courses(id, title, kind, active, module_id, created_at) VALUES ('c1', ?, 'vorlesung', 1, ?, '2026-10-26')", (MODULE, mid))
            conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, size, mime, author, chdate, download_url, local_path, first_seen, status, seen_by_user, content_sha256) "
                         "VALUES ('f1', 'c1', 'Blatt 1.pdf', ?, 'application/pdf', 'Dozent', 1761900000, 'https://studip.example/f1', ?, ?, 'gelesen', 1, ?)",
                         (len(pdf), str(path), db.now_iso(), hashlib.sha256(pdf).hexdigest()))
    finally:
        config.reset_user_context(tok)


def solution_package(fp: str, key_secret: bytes, sid="6f1c1c0e-0000-4000-8000-0000000000aa", name="Erika", color="#1f6fe0"):
    """Echtes Gemeinschaftspaket (Referenz app/solution_format.py): eine Seite mit einem Strich."""
    from app import solution_format as sf
    stroke = {"id": "s1", "type": "stroke", "tool": "pen", "color": color, "width": 2.2, "opacity": 1, "points": [50, 60, 200, 90, 300, 400], "x": 0, "y": 0, "rotation": 0, "scaleX": 1, "scaleY": 1}
    content = {"format": sf.CONTENT_FORMAT, "formatVersion": 1, "solutionId": sid, "createdAt": "2026-11-02T10:00:00Z", "title": "Blatt 1", "displayName": name,
               "document": {"sha256": fp, "pageCount": 2},
               "pages": [{"key": "p1", "kind": "pdf", "pdfIndex": 1, "width": 595, "height": 842, "rotation": 0, "extraRotation": 0, "objects": [stroke]}],
               "images": {}, "missingImages": []}
    return sid, sf.seal(content, None, b"\x01" * 32, b"\x02" * 12, secret=key_secret)


def shot(page, name):
    """Bildschirmfoto fuer die Sichtpruefung (nur mit CC_SHOTS=<Ordner>)."""
    if os.environ.get("CC_SHOTS"):
        page.screenshot(path=os.path.join(os.environ["CC_SHOTS"], name + ".png"), full_page=True)


def login(ctx, base, token):
    ctx.add_cookies([{"name": "uniflow_session", "value": token, "url": base}])


@pytest.fixture
def world(served_hosted, tmp_path):  # noqa: F811
    from app import solution_format as sf
    from app.studip_sync import classify
    base = served_hosted
    pdf = make_pdf()
    fp = hashlib.sha256(pdf).hexdigest()
    autor, ta = new_user(base, "autor@example.org")
    leser, tl = new_user(base, "leser@example.org")
    seed(autor, pdf, tmp_path / "autor.pdf")
    seed(leser, pdf, tmp_path / "leser.pdf")
    module = classify(MODULE)[0]
    key = sf.community_module_key("luh", module)
    secret = sf.community_secret("module", "luh", sf.normalized_course_name(module))
    # der Autor meldet seinen Kurs, tritt bei und teilt (wie die Seite es im Browser taete)
    assert _http(base, "POST", "/api/community/claims", {"fingerprints": [fp], "course_keys": [key]}, cookie=ta)[0] == 200
    assert _http(base, "POST", f"/api/community/communities/{key}/join", {"kind": "course"}, cookie=ta)[0] == 200
    sid, pkg = solution_package(fp, secret)
    st, d = _http(base, "POST", "/api/community/solutions", {"package": pkg, "title": "Blatt 1", "community_key": key}, cookie=ta)
    assert st == 201, d
    # eine zweite Person (Ben) teilt zu demselben Blatt: Karte "2 Personen", Pfeile im Leser
    ben, tb = new_user(base, "ben@example.org")
    assert _http(base, "POST", "/api/community/claims", {"fingerprints": [], "course_keys": [key]}, cookie=tb)[0] == 200
    assert _http(base, "POST", f"/api/community/communities/{key}/join", {"kind": "course"}, cookie=tb)[0] == 200
    _, pkg2 = solution_package(fp, secret, sid="6f1c1c0e-0000-4000-8000-0000000000bb", name="Ben", color="#1f9d5b")
    assert _http(base, "POST", "/api/community/solutions", {"package": pkg2, "title": "Blatt 1", "community_key": key}, cookie=tb)[0] == 201
    return type("W", (), dict(base=base, key=key, sid=sid, fp=fp, ta=ta, tl=tl, tb=tb, autor=autor, leser=leser))


def wait_text(page, sel, pattern, timeout=T):
    page.wait_for_function("([s, p]) => { const e = document.querySelector(s); return !!e && new RegExp(p).test(e.textContent); }", arg=[sel, pattern], timeout=timeout)


def test_channel_cards_people_reader_and_discussion(world):
    w = world
    with _playwright() as p:
        browser = _browser(p)
        if browser is None:
            pytest.skip("kein Chromium fuer Playwright")
        try:
            ctx = browser.new_context(bypass_csp=True)
            login(ctx, w.base, w.tl)
            page = ctx.new_page()
            errors = []
            page.on("pageerror", lambda e: errors.append(str(e)))
            page.goto(f"{w.base}/#/community?space={w.key}")
            # Kopf mit Modulname, ohne Beitritt: Hinweis und Knopf "Beitreten"
            wait_text(page, ".cc-head h1", MODULE)
            wait_text(page, "#ccPanel", "Tritt der Community bei")
            page.click("#ccJoin")
            # beigetreten: Reiter Diskussion (Fragen) und Dokumente (2)
            page.wait_for_selector(".cc-tab:has-text('Dokumente (2)')", timeout=T)
            page.click(".cc-tab:has-text('Dokumente (2)')")
            # Karte je Blatt in der Woche des Moduls, mit Art-Etikett, Titel und "2 Personen"
            page.wait_for_selector(".cc-card", timeout=T)
            card = page.locator(".cc-card", has_text="Blatt 1")
            assert card.count() == 1, page.inner_text("#ccPanel")
            txt = card.inner_text()
            assert "2 Personen" in txt and ("Übung" in txt or "Vorlesung" in txt), txt
            assert page.locator(".cc-week").count() >= 1
            shot(page, "dokumente-wochen")
            # Liste mit Sortierung
            page.click("[data-layout=list]")
            page.wait_for_selector(".cc-li", timeout=T)
            assert "2 Personen" in page.inner_text(".cc-li") and page.locator(".cc-li .cc-av").count() == 2
            page.click("[data-sort=newest]")
            page.click("[data-layout=weeks]")
            page.wait_for_selector(".cc-card", timeout=T)
            # Karte -> wer hat geteilt -> Person -> Notizen als Seite
            page.click(".cc-card:has-text('Blatt 1')")
            page.wait_for_selector(".cc-person", timeout=T)
            assert page.locator(".cc-person").count() == 2 and "Erika" in page.inner_text(".cc-people") and "Ben" in page.inner_text(".cc-people")
            page.click(".cc-person:has-text('Erika')")
            page.wait_for_selector(".cc-pages canvas", timeout=T)
            shot(page, "leser")
            # Pfeile: zur naechsten und zurueck (Ben liegt vor oder hinter Erika, an den Enden Stopp)
            first = page.inner_text(".cc-rtitle")
            assert "Erika" in first and " von 2" in first
            step = "[data-next]" if page.is_enabled("[data-next]") else "[data-prev]"
            page.click(step)
            wait_text(page, ".cc-rtitle", "Ben")
            page.wait_for_selector(".cc-pages canvas", timeout=T)
            assert page.is_disabled(step), "an den Enden Stopp"
            page.keyboard.press("ArrowLeft" if step == "[data-next]" else "ArrowRight")           # Tasten wie die Pfeile
            wait_text(page, ".cc-rtitle", "Erika")
            page.wait_for_selector(".cc-pages canvas", timeout=T)
            assert page.evaluate("""() => { const c = document.querySelector('.cc-pages canvas'); const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
                                          for (let i = 0; i < d.length; i += 4) if (d[i] < 120 && d[i + 2] > 150) return true; return false; }"""), "Erikas blauer Strich"
            # Notizen sind wirklich gezeichnet (nicht nur weisse Flaeche)
            assert page.evaluate("""() => { const c = document.querySelector('.cc-pages canvas'); const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
                                          for (let i = 0; i < d.length; i += 4) if (d[i] < 200) return true; return false; }""")
            # Diskussion der Person: Kommentar schreiben
            page.click("[data-rtab=talk]")
            page.wait_for_selector("#ccCt", timeout=T)
            page.fill("#ccCt", "Danke für die Lösung!")
            page.click("#ccCs")
            page.wait_for_selector(".com-c-text:has-text('Danke für die Lösung!')", timeout=T)
            assert "Diskussion (1)" in page.inner_text("#ccTalkTab")
            # Korrektur vorschlagen ist da (eigene PDF vorhanden), Liken geht
            page.wait_for_selector("[data-a=correct]:not([disabled])", timeout=T)
            page.click("[data-a=like]")
            page.wait_for_function("document.querySelector('[data-a=like]').textContent.includes('1')", timeout=T)
            # Zurueck zur Seite, Diskussion: Frage stellen, liken (nicht die eigene), Filter
            page.click("[data-leave]")
            page.click(".cc-tab:has-text('Diskussion')")
            page.wait_for_selector("#ccQa details.cc-ask", timeout=T)
            page.click("#ccQa details.cc-ask summary")
            page.fill("#ccQt", "Wie geht Aufgabe 2?")
            page.click("#ccQs")
            page.wait_for_selector(".cc-post:has-text('Wie geht Aufgabe 2?')", timeout=T)
            assert page.is_disabled(".cc-post [data-like]"), "die eigene Frage lässt sich nicht liken"
            page.click("[data-filter=unanswered]")
            page.wait_for_selector(".cc-post:has-text('Wie geht Aufgabe 2?')", timeout=T)
            shot(page, "diskussion")
            assert not errors, errors
        finally:
            browser.close()


def _mouse_stroke(page, canvas_sel, dx=60, dy=80):
    box = page.locator(canvas_sel).first.bounding_box()
    x, y = box["x"] + 80, box["y"] + 120
    page.mouse.move(x, y)
    page.mouse.down()
    for i in range(1, 8):
        page.mouse.move(x + dx * i / 7, y + dy * i / 7)
    page.mouse.up()
    return box


def test_correction_in_the_editor_hint_badge_and_side_by_side(world):
    """Korrektur vorschlagen (Leser) -> Dienst (Chiffrat aus dem Browser, in Python lesbar) -> Hinweis, Abzeichen und
    Ansehen beim Ersteller -> Loesung daneben ansehen."""
    from app import community_corrections as cc
    from app import solution_format as sf
    from app.studip_sync import classify
    w = world
    module = classify(MODULE)[0]
    secret = sf.community_secret("module", "luh", sf.normalized_course_name(module))
    assert _http(w.base, "POST", "/api/community/claims", {"fingerprints": [w.fp], "course_keys": [w.key]}, cookie=w.tl)[0] == 200
    assert _http(w.base, "POST", f"/api/community/communities/{w.key}/join", {"kind": "course"}, cookie=w.tl)[0] == 200
    with _playwright() as p:
        browser = _browser(p)
        if browser is None:
            pytest.skip("kein Chromium fuer Playwright")
        try:
            # ---- Leser: von der Community-Seite in den Editor, markieren, Randnotiz, Text, Schicken
            lctx = browser.new_context(bypass_csp=True)
            login(lctx, w.base, w.tl)
            page = lctx.new_page()
            errors = []
            page.on("pageerror", lambda e: errors.append(str(e)))
            page.goto(f"{w.base}/#/community?space={w.key}&tab=docs")
            page.wait_for_selector(".cc-card", timeout=T)
            page.click(".cc-card:has-text('Blatt 1')")
            page.click(".cc-person:has-text('Erika')")
            page.wait_for_selector("[data-a=correct]:not([disabled])", timeout=T)
            page.click("[data-a=correct]")
            page.wait_for_function(EDITOR_READY, timeout=T)
            page.wait_for_selector(".ed-corr", timeout=T)
            wait_text(page, ".ed-com", "Korrektur vorschlagen")
            assert page.locator(".ed-corr").count() == 2, "eine Ebene je PDF-Seite"
            assert page.is_disabled("[data-corr=send]"), "leere Korrektur laesst sich nicht schicken"
            _mouse_stroke(page, ".ed-corr")
            wait_text(page, ".cc-sum", "1 Markierung · 0 Randnotizen")
            page.click("[data-corr=note]")
            page.once("dialog", lambda d: d.accept("Hier fehlt ein Minus"))
            box = page.locator(".ed-corr").first.bounding_box()
            page.mouse.click(box["x"] + box["width"] * 0.4, box["y"] + box["height"] * 0.5)
            wait_text(page, ".cc-sum", "1 Markierung · 1 Randnotiz")
            assert page.locator(".ed-cmark.corr.mine").count() == 1
            page.fill("textarea[data-corr=note]", "Aufgabe 2b: Vorzeichen")
            shot(page, "korrektur-schreiben")
            # Entwurf bleibt erhalten (localStorage), solange nichts geschickt ist
            assert page.evaluate("Object.keys(localStorage).some(k => k.startsWith('cc-draft:'))")
            page.click("[data-corr=send]")
            wait_text(page, ".com-toast", "Deine Korrektur ist unterwegs")
            assert not page.evaluate("Object.keys(localStorage).some(k => k.startsWith('cc-draft:'))"), "nach dem Schicken kein Entwurf mehr"
            assert page.locator(".ed-corr").count() == 0, "Korrektur-Modus beendet"
            # beim Dienst: ein offener Hinweis; das im Browser erzeugte Chiffrat liest die Python-Referenz
            inbox = _http(w.base, "GET", "/api/community/corrections/inbox", cookie=w.ta)[1]
            assert inbox["open"] == 1 and len(inbox["items"]) == 1
            full = _http(w.base, "GET", f"/api/community/corrections/{inbox['items'][0]['id']}", cookie=w.ta)[1]
            opened = cc.open_payload(full["payload"], full["id"], w.sid, secret)
            assert opened["note"] == "Aufgabe 2b: Vorzeichen" and len(opened["pages"]) == 1
            pg = opened["pages"][0]
            assert pg["pdfIndex"] == 1 and (pg["width"], pg["height"]) == (595, 842) and len(pg["strokes"]) == 1 and len(pg["notes"]) == 1
            assert pg["notes"][0]["text"] == "Hier fehlt ein Minus" and 0.35 < pg["notes"][0]["x"] < 0.45
            # Leser sieht die eigene Korrektur unter der Diskussion der Loesung
            page.goto(f"{w.base}/#/community?space={w.key}&tab=docs")
            page.wait_for_selector(".cc-card", timeout=T)
            page.click(".cc-card:has-text('Blatt 1')")
            page.click(".cc-person:has-text('Erika')")
            page.click("[data-rtab=talk]")
            wait_text(page, "#ccRPane", "Korrekturvorschläge \\(1\\)")
            assert "deine" in page.inner_text(".cc-corr") and page.locator("[data-cdelete]").count() == 1
            assert not errors, errors

            # ---- Ersteller: Hinweis auf der Uebersicht, Abzeichen am Menuepunkt, Oeffnen = gesehen
            actx = browser.new_context(bypass_csp=True)
            login(actx, w.base, w.ta)
            a = actx.new_page()
            aerr = []
            a.on("pageerror", lambda e: aerr.append(str(e)))
            a.goto(f"{w.base}/#/dashboard")
            a.wait_for_selector(".cc-inbox", timeout=T)
            assert "Deine Lösung „Blatt 1“ hat einen Korrekturhinweis von Studi-" in a.inner_text(".cc-inbox")
            a.evaluate("window.dispatchEvent(new Event('cc:changed'))")
            wait_text(a, "#nav a[data-route=community] .cc-count", "^1$")
            shot(a, "uebersicht-hinweis")
            a.click("[data-iopen]")
            a.wait_for_function(EDITOR_READY, timeout=T)
            a.wait_for_function("__app.state.editors[0].community.viewing && __app.state.editors[0].community.viewing.c", timeout=T)
            wait_text(a, ".ed-com", "Korrekturvorschlag von")
            assert a.locator(".ed-cmark.corr").count() == 1, "Randnotiz als Marker auf der Seite"
            assert _http(w.base, "GET", "/api/community/corrections/inbox?count_only=true", cookie=w.ta)[1] == {"open": 0, "seen": 1}, "Oeffnen = gesehen"
            a.evaluate("window.dispatchEvent(new Event('cc:changed'))")
            a.wait_for_function("!document.querySelector('#nav a[data-route=community] .cc-count')", timeout=T)
            # Loesung daneben ansehen (nur ansehen, eigene PDF darunter)
            a.click(f"[data-cc-side='{w.sid}']")
            a.wait_for_selector(".ed-solside:not([hidden]) canvas", timeout=T)
            assert "nur ansehen" in a.inner_text(".ed-solside")
            a.wait_for_function("""() => { const c = document.querySelector('.ed-solside canvas'); if (!c || !c.width) return false; const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
                                         for (let i = 0; i < d.length; i += 4) if (d[i] < 120 && d[i + 2] > 150) return true; return false; }""", timeout=T)
            shot(a, "daneben")
            a.click(".ed-solside [data-ss=x]")
            assert a.is_hidden(".ed-solside")
            assert not aerr, aerr
        finally:
            browser.close()
