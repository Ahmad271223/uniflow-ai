"""Studora als App im Browser (app/static/sw.js, sw-policy.js, pwa.js): Auslieferung des Workers, gehosteter Modus,
und ein echter Browserlauf mit Playwright: Seite laden, Netz abschalten, neu laden, Oberflaeche und Startseite kommen
aus der Ablage, eine Aenderung ohne Netz scheitert mit Code `offline`. Ohne Chromium wird der Browserlauf uebersprungen."""
import re
import socket
import threading
import time
from pathlib import Path

import pytest
from conftest import asgi_call

STATIC = Path(__file__).resolve().parents[1] / "app" / "static"


def test_worker_is_served_fresh_and_declared(app):
    st, hdrs, body = asgi_call(app, "GET", "/sw.js")
    h = {k.decode().lower(): v.decode() for k, v in hdrs}
    assert st == 200 and "javascript" in h["content-type"] and "no-cache" in h["cache-control"]
    assert b'importScripts("sw-policy.js?v=' in body
    st, hdrs, body = asgi_call(app, "GET", "/sw-policy.js?v=1")
    assert st == 200 and b"StudoraSW" in body
    index = (STATIC / "index.html").read_text(encoding="utf-8")
    assert 'rel="manifest"' in index and 'apple-mobile-web-app-capable' in index
    assert re.search(r"<script(?![^>]*\bsrc=)", index) is None, "kein Inline-Skript (CSP)"
    assert re.search(r'from "\./pwa\.js\?v=\d+"', (STATIC / "app.js").read_text(encoding="utf-8"))
    policy_version = re.search(r'sw-policy\.js\?v=(\d+)', (STATIC / "sw.js").read_text(encoding="utf-8")).group(1)
    assert policy_version.isdigit()
    manifest = (STATIC / "manifest.webmanifest").read_text(encoding="utf-8")
    assert '"display": "standalone"' in manifest and '"start_url": "/"' in manifest


def test_hosted_mode_serves_worker_without_session(app, monkeypatch):
    from app import config
    monkeypatch.setattr(config, "MODE", "hosted")
    assert asgi_call(app, "GET", "/sw.js")[0] == 200
    assert asgi_call(app, "GET", "/sw-policy.js?v=1")[0] == 200
    st, hdrs, _ = asgi_call(app, "GET", "/")
    assert st == 302 and {k.decode().lower(): v.decode() for k, v in hdrs}.get("location") == "/login"


# ---------------------------------------------------------------- echter Browser

def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture
def served(app):
    import uvicorn
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
    yield f"http://127.0.0.1:{port}"
    server.should_exit = True
    t.join(5)


def _browser(p):
    args = ["--no-sandbox"]
    try:
        return p.chromium.launch(args=args)
    except Exception:  # noqa: BLE001
        for path in ("/opt/pw-browsers/chromium",):
            if Path(path).exists():
                try:
                    return p.chromium.launch(executable_path=path, args=args)
                except Exception:  # noqa: BLE001
                    pass
    return None


def test_offline_reload_comes_from_the_worker(served):
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        pytest.skip("Playwright fehlt")
    with sync_playwright() as p:
        browser = _browser(p)
        if browser is None:
            pytest.skip("kein Chromium fuer Playwright")
        try:
            context = browser.new_context(bypass_csp=True)      # Playwright wertet Ausdruecke per eval aus; die CSP prueft test_worker_is_served_fresh_and_declared
            page = context.new_page()
            page.goto(served + "/#/dashboard")
            page.wait_for_function("navigator.serviceWorker && navigator.serviceWorker.controller !== null", timeout=20000)
            # erster Lauf unter dem Worker: alles geht durch ihn und landet in der Ablage
            page.reload()
            page.wait_for_function("document.querySelector('#view') && /Guten/.test(document.querySelector('#view').textContent)", timeout=20000)
            page.wait_for_function("""async () => (await caches.has('studora-shell-v1')) && (await (await caches.open('studora-api-v1')).keys()).some(r => r.url.includes('/api/dashboard'))""", timeout=20000)
            assert page.evaluate("fetch('/api/dashboard').then(r => r.headers.get('X-Studora-Offline'))") is None, "mit Netz nichts aus der Ablage"
            context.set_offline(True)
            page.reload()
            page.wait_for_function("document.querySelector('#view') && /Guten/.test(document.querySelector('#view').textContent)", timeout=20000)
            text = page.text_content("#view")
            assert "Server nicht erreichbar" not in text and "Guten" in text
            assert page.evaluate("fetch('/api/dashboard').then(r => r.headers.get('X-Studora-Offline'))") == "1"
            assert "Offline" in (page.text_content("#syncChip") or "")
            write = page.evaluate("fetch('/api/settings', {method: 'PUT', headers: {'Content-Type': 'application/json'}, body: '{}'}).then(async r => [r.status, (await r.json()).code])")
            assert write == [503, "offline"]
            # Konto nie aus der Ablage: ohne Netz ein echter Fehler, keine alte Antwort
            assert page.evaluate("fetch('/api/account/info').then(() => 'ok', () => 'fehler')") == "fehler"
            context.set_offline(False)
            page.reload()
            page.wait_for_function("document.querySelector('#view') && /Guten/.test(document.querySelector('#view').textContent)", timeout=20000)
            assert page.evaluate("fetch('/api/dashboard').then(r => r.headers.get('X-Studora-Offline'))") is None
        finally:
            browser.close()


def _notebook(app, file_id: str):
    """Eigenes Notizbuch wie POST /api/notebooks (lokaler Modus: direkt in die Datenbank), Notizen auf Version 1."""
    import json
    from app import db
    db.init_db()
    with db.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, active, created_at) VALUES ('__user__', 'Eigene Dokumente', 'sonstiges', 1, ?)", (db.now_iso(),))
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, size, author, chdate, download_url, first_seen, status, seen_by_user, kind, title) "
                     "VALUES (?, '__user__', 'Offline-Heft', 0, 'Ich', 0, '', ?, 'gelesen', 1, 'notebook', 'Offline-Heft')", (file_id, db.now_iso()))
        model = {"version": 2, "zoom": 1.2, "pages": {"b1": {"objects": []}}, "pageOrder": [{"key": "b1", "type": "blank", "w": 595, "h": 842}], "bookmarks": [], "outline": []}
        conn.execute("INSERT OR REPLACE INTO annotations(file_id, data, updated_at, version) VALUES (?,?,?,1)", (file_id, json.dumps(model), db.now_iso()))


def _http(base: str, method: str, path: str, body: dict | None = None):
    """Aufruf ueber das Netz an den laufenden Server (asgi_call geht nicht, solange Playwright seine Schleife haelt)."""
    import json
    from urllib.request import Request, urlopen
    data = json.dumps(body).encode() if body is not None else None
    with urlopen(Request(base + path, data=data, method=method, headers={"Content-Type": "application/json", "Host": "test"}), timeout=10) as r:
        return r.status, json.loads(r.read() or b"null")


def test_offline_notes_are_queued_and_sent_when_back_online(app, served):
    """Notizen ohne Netz (Stufe B.2): der Editor speichert in die Warteschlange (notes-queue.js), zeigt "Offline …",
    beim erneuten Oeffnen ohne Netz gilt der lokale Stand; nach dem Schliessen sendet pwa.js beim online-Ereignis nach,
    ein inzwischen geaenderter Serverstand (409) wird mit merge.js zusammengefuehrt."""
    import json
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        pytest.skip("Playwright fehlt")
    fid = "offline-heft-1"
    _notebook(app, fid)
    queue_url = "/" + re.search(r'from "\./(notes-queue\.js\?v=\d+)"', (STATIC / "pwa.js").read_text(encoding="utf-8")).group(1)
    with sync_playwright() as p:
        browser = _browser(p)
        if browser is None:
            pytest.skip("kein Chromium fuer Playwright")
        try:
            context = browser.new_context(bypass_csp=True)
            page = context.new_page()
            page.goto(served + "/#/dashboard")
            page.wait_for_function("navigator.serviceWorker && navigator.serviceWorker.controller !== null", timeout=20000)
            page.reload()
            page.wait_for_function("document.querySelector('#view') && /Guten/.test(document.querySelector('#view').textContent)", timeout=20000)
            editor_ready = "window.__app && __app.state.editors.length === 1 && !!__app.state.editors[0].model && !__app.state.editors[0].destroyed"
            page.evaluate(f"location.hash = '#/doc/{fid}'")
            page.wait_for_function(editor_ready, timeout=30000)
            assert page.evaluate("__app.state.editors[0].model.pages.b1.objects.length") == 0
            # Netz weg, dann schreiben: der Editor versucht zu speichern, scheitert am Worker (503 offline) und meldet es
            context.set_offline(True)
            page.evaluate("""() => { const ed = __app.state.editors[0]; ed.model.pages.b1.objects.push({ id: 'q1', type: 'text', text: 'offline geschrieben', x: 40, y: 40 }); ed.markDirty(); }""")
            page.wait_for_function("/Offline – Notizen werden gesendet/.test(document.querySelector('.ed-status')?.textContent || '')", timeout=20000)
            page.wait_for_function(f"import('{queue_url}').then(m => m.notesQueue.pending()).then(p => p.length === 1 && p[0].fileId === '{fid}' && p[0].version === 1)", timeout=10000)
            # Editor schliessen (Uebersicht): der Eintrag bleibt in der Warteschlange, der Server weiss nichts davon
            page.evaluate("location.hash = '#/dashboard'")
            page.wait_for_function("window.__app && __app.state.editors.length === 0 && /Guten/.test(document.querySelector('#view')?.textContent || '')", timeout=20000)
            assert "q1" not in json.dumps(_http(served, "GET", f"/api/files/{fid}/annotations")[1])
            # Datei ohne Netz erneut oeffnen: der lokale Stand (neuer als der Server) wird angezeigt, nicht ueberschrieben
            page.evaluate(f"location.hash = '#/doc/{fid}'")
            page.wait_for_function(editor_ready, timeout=30000)
            assert page.evaluate("__app.state.editors[0].model.pages.b1.objects.map(o => o.id)") == ["q1"]
            page.evaluate("location.hash = '#/dashboard'")
            page.wait_for_function("window.__app && __app.state.editors.length === 0", timeout=20000)
            page.wait_for_function(f"import('{queue_url}').then(m => !m.notesQueue.isHeld('{fid}'))", timeout=10000)
            # Inzwischen hat ein anderes Geraet gespeichert (Version 2): das Nachsenden muss zusammenfuehren
            other = {"version": 2, "zoom": 1.2, "pages": {"b1": {"objects": [{"id": "s2", "type": "text", "text": "anderes Gerät", "x": 10, "y": 10}]}},
                     "pageOrder": [{"key": "b1", "type": "blank", "w": 595, "h": 842}], "bookmarks": [], "outline": []}
            st, body = _http(served, "PUT", f"/api/files/{fid}/annotations?base_version=1", other)
            assert st == 200 and body["version"] == 2, body
            # Netz wieder da: pwa.js sendet beim online-Ereignis nach (kein Editor offen); der Server ist die Wahrheit,
            # nicht der Browser (der Worker kann kurz nach dem Umschalten noch die abgelegte Antwort liefern)
            context.set_offline(False)
            deadline = time.time() + 8
            while time.time() < deadline and _http(served, "GET", f"/api/files/{fid}/annotations")[1]["version"] < 3:
                time.sleep(0.2)
            if _http(served, "GET", f"/api/files/{fid}/annotations")[1]["version"] < 3:
                page.evaluate("window.dispatchEvent(new Event('online'))")      # falls Chromium das Ereignis bei set_offline nicht meldet
                deadline = time.time() + 15
                while time.time() < deadline and _http(served, "GET", f"/api/files/{fid}/annotations")[1]["version"] < 3:
                    time.sleep(0.2)
            notes = _http(served, "GET", f"/api/files/{fid}/annotations")[1]
            ids = sorted(o["id"] for o in notes["data"]["pages"]["b1"]["objects"])
            assert ids == ["q1", "s2"], notes
            assert notes["version"] == 3
            page.wait_for_function(f"import('{queue_url}').then(m => m.notesQueue.count()).then(n => n === 0)", timeout=10000)
            page.wait_for_function("/nachgesendet/.test(document.querySelector('#toastEl')?.textContent || '')", timeout=10000)
        finally:
            browser.close()
