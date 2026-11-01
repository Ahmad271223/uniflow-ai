"""Der gehostete Dienst (LERNAPP_MODE=hosted) zum ersten Mal im echten Browser, Ende-zu-Ende mit zwei Geraeten (zwei
Browser-Kontexte) und einem Konto: Anmeldeseite, Konto anlegen, Probe-Hinweis und Tarifseite, Hochschul-Zugang nur mit
Zustimmung, Notizen von Geraet A auf Geraet B, Abmelden (Ablage des Workers liefert keine Kontodaten mehr), zweites
Konto sieht nichts vom ersten. Ohne Chromium wird uebersprungen (wie tests/test_pwa.py)."""
import json
import re
import shutil
import socket
import threading
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import pytest
from test_pwa import _browser, _free_port

PASSWORD = "sehr-geheim-123"
T = 20000                                   # grosszuegige Wartezeit im Browser (ms)
EDITOR_READY = "window.__app && __app.state.editors.length === 1 && !!__app.state.editors[0].model && !__app.state.editors[0].destroyed"
DASHBOARD = "document.querySelector('#view') && /Guten/.test(document.querySelector('#view').textContent)"


@pytest.fixture
def served_hosted(app, monkeypatch):
    """Wie `served` in test_pwa.py, aber als Dienst: MODE=hosted, keine Hintergrundauftraege, Konto-, Community- und
    Bibliotheksdatenbank sowie die Kontoordner leer (wie `hosted` in test_subscriptions.py); danach alles zurueck."""
    import uvicorn
    from app import accounts, community, config, test_library, vault
    from app import server as srv
    monkeypatch.setattr(config, "MODE", "hosted")
    monkeypatch.setenv("LERNAPP_JOBS", "off")
    monkeypatch.setenv("LERNAPP_MAIL", "off")
    dbs = (accounts.db_path(), community.db_path(), test_library.db_path())

    def wipe():
        for p in dbs:
            for suffix in ("", "-wal", "-shm"):
                p.with_name(p.name + suffix).unlink(missing_ok=True)
        shutil.rmtree(config.BASE_DATA_DIR / "users", ignore_errors=True)
        srv._user_dbs_ready.clear()
    wipe()
    vault.key_file().unlink(missing_ok=True)
    vault.reset_master()
    port = _free_port()
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning"))
    t = threading.Thread(target=server.run, daemon=True)
    t.start()
    for _ in range(100):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                break
        except OSError:
            time.sleep(0.1)
    else:
        pytest.fail("Server nicht gestartet")
    try:
        yield f"http://127.0.0.1:{port}"
    finally:
        server.should_exit = True
        t.join(5)
        wipe()
        vault.reset_master()


# ---------------------------------------------------------------- Helfer

def _http(base, method, path, body=None, cookie=None):
    """Aufruf ueber das Netz an den laufenden Server, wahlweise mit dem Sitzungs-Cookie eines Browsers; 4xx als Antwort."""
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json", "Host": "test"}
    if cookie:
        headers["Cookie"] = f"uniflow_session={cookie}"
    try:
        with urlopen(Request(base + path, data=data, method=method, headers=headers), timeout=10) as r:
            return r.status, json.loads(r.read() or b"null")
    except HTTPError as e:
        raw = e.read()
        return e.code, (json.loads(raw) if raw else None)


def _cookie(context):
    c = [c["value"] for c in context.cookies() if c["name"] == "uniflow_session"]
    assert c, "kein Sitzungs-Cookie uniflow_session im Browser"
    return c[0]


def _login_page_ready(page):
    page.wait_for_function("document.querySelectorAll('#uniSelect option').length > 0", timeout=T)   # login.js hat /api/account/info gelesen und die Formulare verdrahtet


def _register_in_form(page, base, email):
    page.goto(base + "/login")
    _login_page_ready(page)
    page.click('#tabs button[data-tab="register"]')
    page.wait_for_selector("#register.active", timeout=T)
    page.fill('#register input[name="email"]', email)
    page.select_option("#uniSelect", "luh")
    page.fill('#register input[name="password"]', PASSWORD)
    page.fill('#register input[name="password2"]', PASSWORD)
    page.click('#register button[type="submit"]')
    _expect_app(page, base, email)


def _login_in_form(page, base, email):
    page.goto(base + "/login")
    _login_page_ready(page)
    assert page.is_visible("#login"), "Reiter Anmelden nicht sichtbar"
    page.fill('#login input[name="email"]', email)
    page.fill('#login input[name="password"]', PASSWORD)
    page.click('#login button[type="submit"]')
    _expect_app(page, base, email)


def _expect_app(page, base, email):
    page.wait_for_url(re.compile(re.escape(base) + r"/(#.*)?$"), timeout=T)
    page.wait_for_function(DASHBOARD, timeout=T)
    assert "Server nicht erreichbar" not in page.text_content("#view")
    page.wait_for_function(f"document.querySelector('#avatar')?.textContent === {json.dumps(email[:2].upper())}", timeout=T)
    page.wait_for_function("navigator.serviceWorker && navigator.serviceWorker.controller !== null", timeout=T)


def _goto_hash(page, h, ready, timeout=T):
    page.evaluate(f"location.hash = {json.dumps(h)}")
    page.wait_for_function(ready, timeout=timeout)


def _toast(page):
    return (page.text_content("#toastEl") or "") if page.query_selector("#toastEl") else ""


def _notebook_in_account(base, cookie, file_id):
    """Eigenes Notizbuch in der Datenbank des Kontos (wie _notebook in test_pwa.py, aber im Kontext des Nutzers wie
    add_file in test_subscriptions.py); Notizen auf Version 1."""
    from app import config, db
    st, me = _http(base, "GET", "/api/account/me", cookie=cookie)
    assert st == 200, me
    tok = config.set_user_context(me["user"]["id"], me["user"]["university"])
    try:
        db.init_db()
        with db.cursor() as conn:
            conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, active, created_at) VALUES ('__user__', 'Eigene Dokumente', 'sonstiges', 1, ?)", (db.now_iso(),))
            conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, size, author, chdate, download_url, first_seen, status, seen_by_user, kind, title) "
                         "VALUES (?, '__user__', 'Zwei Geräte', 0, 'Ich', 0, '', ?, 'gelesen', 1, 'notebook', 'Zwei Geräte')", (file_id, db.now_iso()))
            model = {"version": 2, "zoom": 1.2, "pages": {"b1": {"objects": []}}, "pageOrder": [{"key": "b1", "type": "blank", "w": 595, "h": 842}], "bookmarks": [], "outline": []}
            conn.execute("INSERT OR REPLACE INTO annotations(file_id, data, updated_at, version) VALUES (?,?,?,1)", (file_id, json.dumps(model), db.now_iso()))
    finally:
        config.reset_user_context(tok)
    return me["user"]


def _playwright():
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        pytest.skip("Playwright fehlt")
    return sync_playwright()


# ---------------------------------------------------------------- Tests

def test_register_trial_plans_and_credentials_consent(served_hosted):
    """Geraet A: / leitet zur Anmeldung, Konto im Formular anlegen, Oberflaeche mit Konto; Tarifseite mit Probe-Hinweis
    (7 Tage) und ohne Stripe-Knoepfe; Hochschul-Zugang nur mit Haekchen (Zustimmung)."""
    from app import plans
    base, email = served_hosted, "geraet-a@example.org"
    with _playwright() as p:
        browser = _browser(p)
        if browser is None:
            pytest.skip("kein Chromium fuer Playwright")
        try:
            ctx = browser.new_context(bypass_csp=True)      # Playwright wertet Ausdruecke per eval aus; die CSP prueft test_pwa.py
            page = ctx.new_page()
            # 1. ohne Sitzung: / -> /login
            page.goto(base + "/")
            assert page.url.split("?")[0].rstrip("/").endswith("/login"), f"ohne Sitzung nicht zur Anmeldeseite: {page.url}"
            assert "Anmelden" in (page.text_content("body") or "")
            _register_in_form(page, base, email)
            cookie = _cookie(ctx)
            st, me = _http(base, "GET", "/api/account/me", cookie=cookie)
            assert st == 200 and me["user"]["email"] == email, me
            # Uebersicht zeigt derzeit keinen Probe-Hinweis (nur #/abo und das Kontomenue nennen den Tarif), siehe Bericht
            # Tarifseite: Probe 7 Tage, Tarif Pro AI, kein Stripe (nur Apple-App)
            _goto_hash(page, "#/abo", "document.querySelector('#view') && /Dein Tarif/.test(document.querySelector('#view').textContent)")
            text = page.text_content("#view")
            m = re.search(r"Probe: noch (\d+) Tage?", text)
            assert m, f"kein Probe-Hinweis auf der Tarifseite: {text[:300]}"
            assert m.group(1) == "7" and "7 Tage" in text, m.group(0)
            name = plans.PLANS[plans.TRIAL["plan"]]["name"]
            assert f"Dein Tarif: {name}" in text, text[:300]
            buttons = page.evaluate("[...document.querySelectorAll('#view button')].map(b => b.textContent.trim())")
            assert "Abschließen" not in buttons, f"Stripe-Knoepfe ohne Stripe: {buttons}"
            assert page.evaluate("document.querySelectorAll('#view [data-buy]').length") == 0
            assert buttons.count("In der Apple-App abschließen") >= 1, buttons
            assert page.evaluate("[...document.querySelectorAll('#view .badge')].some(b => b.textContent.trim() === 'Dein Tarif')")
            # 2. Einstellungen -> Zugang: ohne Haekchen nichts gespeichert, mit Haekchen gespeichert und "Zugestimmt am"
            _goto_hash(page, "#/settings?tab=account", "!!document.querySelector('#saveCred') && !!document.querySelector('#credConsent')")
            assert not page.is_checked("#credConsent"), "Zustimmung darf nicht vorangekreuzt sein"
            assert page.evaluate("document.querySelector('#view').textContent.includes('Zugestimmt am')") is False
            page.fill("#credUser", "ab1234")
            page.fill("#credPass", "webs-so-geheim")
            page.click("#saveCred")
            page.wait_for_function("/zustimmen/i.test(document.querySelector('#toastEl')?.textContent || '')", timeout=T)
            st, cred = _http(base, "GET", "/api/credentials", cookie=cookie)
            assert st == 200 and cred == {"user": "", "password_set": False, "consent_at": None}, f"ohne Haekchen gespeichert: {cred}"
            st, err = _http(base, "PUT", "/api/credentials", {"user": "ab1234", "password": "x"}, cookie=cookie)     # der Server verlangt die Zustimmung ebenso
            assert (st, err and err.get("code")) == (400, "consent_required"), (st, err)
            page.check("#credConsent")
            page.click("#saveCred")
            page.wait_for_function("/Zugang gespeichert/.test(document.querySelector('#toastEl')?.textContent || '')", timeout=T)
            page.wait_for_function("document.querySelector('#view')?.textContent.includes('Zugestimmt am')", timeout=T)
            st, cred = _http(base, "GET", "/api/credentials", cookie=cookie)
            assert st == 200 and cred["user"] == "ab1234" and cred["password_set"] is True and cred["consent_at"], cred
            assert page.input_value("#credUser") == "ab1234" and page.is_checked("#credConsent")
            assert page.evaluate("[...document.querySelectorAll('#view .badge')].some(b => b.textContent.trim() === 'gespeichert')")
        finally:
            browser.close()


def test_two_devices_notes_logout_and_second_account(served_hosted):
    """Geraet A und B am selben Konto: Notiz aus A erscheint in B; Abmelden in A: / fuehrt zur Anmeldung und der Service
    Worker liefert keine Kontodaten mehr; zweites Konto in B sieht die Datei des ersten nicht."""
    base, email, email2, fid = served_hosted, "zwei-geraete@example.org", "zweites-konto@example.org", "heft-zwei-geraete"
    with _playwright() as p:
        browser = _browser(p)
        if browser is None:
            pytest.skip("kein Chromium fuer Playwright")
        try:
            ctx_a = browser.new_context(bypass_csp=True)
            a = ctx_a.new_page()
            _register_in_form(a, base, email)
            cookie_a = _cookie(ctx_a)
            # 3. Geraet B: zweiter Kontext, gleiches Konto per Login
            ctx_b = browser.new_context(bypass_csp=True)
            b = ctx_b.new_page()
            _login_in_form(b, base, email)
            cookie_b = _cookie(ctx_b)
            assert cookie_b != cookie_a, "zwei Geraete muessen zwei Sitzungen haben"
            st, me = _http(base, "GET", "/api/account/me", cookie=cookie_b)
            assert st == 200 and len(me["sessions"]) == 2 and sum(s["current"] for s in me["sessions"]) == 1, me
            _notebook_in_account(base, cookie_a, fid)
            st, files = _http(base, "GET", "/api/files", cookie=cookie_b)
            assert st == 200 and [f["id"] for f in files] == [fid], files
            # A oeffnet das Heft, schreibt ein Objekt, der Editor speichert (Version 2)
            _goto_hash(a, f"#/doc/{fid}", EDITOR_READY, timeout=30000)
            assert a.evaluate("__app.state.editors[0].model.pages.b1.objects.length") == 0
            assert a.evaluate("__app.state.editors[0].version") == 1
            a.evaluate("""() => { const ed = __app.state.editors[0]; ed.model.pages.b1.objects.push({ id: 'a1', type: 'text', text: 'von Gerät A', x: 40, y: 40 }); ed.markDirty(); }""")
            a.wait_for_function("__app.state.editors[0].version >= 2 && !__app.state.editors[0].dirty && !__app.state.editors[0].saving", timeout=T)
            assert a.text_content(".ed-status") == "Gespeichert", a.text_content(".ed-status")
            st, notes = _http(base, "GET", f"/api/files/{fid}/annotations", cookie=cookie_b)
            assert st == 200 and notes["version"] == 2, notes
            assert [o["id"] for o in notes["data"]["pages"]["b1"]["objects"]] == ["a1"], notes["data"]
            # B oeffnet dasselbe Heft und sieht das Objekt
            _goto_hash(b, f"#/doc/{fid}", EDITOR_READY, timeout=30000)
            assert b.evaluate("__app.state.editors[0].model.pages.b1.objects.map(o => [o.id, o.text])") == [["a1", "von Gerät A"]]
            assert b.evaluate("__app.state.editors[0].version") == 2
            assert "nachgesendet" not in _toast(b), "B hatte nichts nachzusenden"
            # 4. Abmelden in A (Avatar -> Abmelden); vorher liegt die Dateiliste in der Ablage des Workers
            _goto_hash(a, "#/files", "window.__app && __app.state.editors.length === 0 && /Zwei Geräte/.test(document.querySelector('#view')?.textContent || '')")
            a.wait_for_function("caches.open('studora-api-v1').then(c => c.keys()).then(k => k.some(r => /\\/api\\/files(\\?|$)/.test(r.url)))", timeout=T)
            a.click("#avatar")
            a.wait_for_selector("#accLogout", timeout=T)
            assert email in (a.text_content("#overlay") or "")
            a.click("#accLogout")
            a.wait_for_url(re.compile(r"/login$"), timeout=T)
            assert not [c for c in ctx_a.cookies() if c["name"] == "uniflow_session"], "Sitzungs-Cookie nach dem Abmelden noch da"
            st, _ = _http(base, "GET", "/api/account/me", cookie=cookie_a)
            assert st == 401, "alte Sitzung von A gilt auf dem Server noch"
            a.goto(base + "/")
            assert a.url.split("?")[0].rstrip("/").endswith("/login"), f"nach dem Abmelden nicht zur Anmeldeseite: {a.url}"
            a.wait_for_function("navigator.serviceWorker && navigator.serviceWorker.controller !== null", timeout=T)
            a.wait_for_function("caches.open('studora-api-v1').then(c => c.keys()).then(k => k.length === 0)", timeout=T)
            r = a.evaluate("fetch('/api/files').then(async r => [r.status, r.headers.get('X-Studora-Offline'), await r.text()])")
            assert r[0] == 401 and r[1] is None, f"Worker liefert nach dem Abmelden Kontodaten: {r}"
            assert fid not in r[2] and json.loads(r[2]).get("code") == "unauthenticated", r[2]
            r = a.evaluate(f"fetch('/api/files/{fid}/annotations').then(async r => [r.status, r.headers.get('X-Studora-Offline'), await r.text()])")
            assert r[0] == 401 and r[1] is None and "a1" not in r[2], r
            # B ist weiter angemeldet (eigene Sitzung)
            st, me = _http(base, "GET", "/api/account/me", cookie=cookie_b)
            assert st == 200 and len(me["sessions"]) == 1, me
            # 5. zweites Konto in B: abmelden, im Formular anlegen, nichts vom ersten Konto sichtbar
            _goto_hash(b, "#/dashboard", "window.__app && __app.state.editors.length === 0 && " + DASHBOARD)
            assert b.evaluate("fetch('/api/account/logout', {method: 'POST'}).then(r => r.status)") == 200
            _register_in_form(b, base, email2)
            cookie_b2 = _cookie(ctx_b)
            assert cookie_b2 != cookie_b
            r = b.evaluate("fetch('/api/files').then(async r => [r.status, r.headers.get('X-Studora-Offline'), await r.json()])")
            assert r[0] == 200 and r[1] is None and r[2] == [], f"zweites Konto sieht fremde Dateien: {r}"
            st, files = _http(base, "GET", "/api/files", cookie=cookie_b2)
            assert (st, files) == (200, []), files
            st, _ = _http(base, "GET", f"/api/files/{fid}/annotations", cookie=cookie_b2)
            assert st == 404, f"Notizen des ersten Kontos fuer das zweite erreichbar: {st}"
            b.wait_for_function("caches.open('studora-api-v1').then(c => c.keys()).then(k => !k.some(r => r.url.includes('/annotations')))", timeout=T)
            _goto_hash(b, "#/files", "document.querySelector('#view') && !/skeleton/.test(document.querySelector('#view').innerHTML)")
            assert "Zwei Geräte" not in (b.text_content("#view") or "")
            # das erste Konto hat seine Datei noch
            _login_in_form(a, base, email)
            st, files = _http(base, "GET", "/api/files", cookie=_cookie(ctx_a))
            assert st == 200 and [f["id"] for f in files] == [fid], files
        finally:
            browser.close()
