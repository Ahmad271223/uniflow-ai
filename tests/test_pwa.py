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
