"""Konto löschen im Web (Dienst) im echten Browser (app/static/account-delete.js, 13.11.2026): Avatar -> "Konto
löschen" -> Rueckfrage mit Erklaerung, Bestaetigung noetig, falsches Passwort zeigt einen Hinweis statt zur Anmeldung
umzuleiten, mit dem richtigen Passwort ist das Konto gesperrt und der Browser abgemeldet. Gleicher Dialog wie in der
Windows-App (dort ueber POST /api/app-account/delete, tests/test_konto_loeschen_pc.py). Ohne Chromium uebersprungen."""
import re

from test_pwa import _browser
from test_web_hosted_e2e import PASSWORD, T, _cookie, _http, _playwright, _register_in_form, _skip_first_start, served_hosted  # noqa: F401


def test_delete_account_in_the_web(served_hosted):
    import pytest
    from app import accounts
    base = served_hosted
    email = "loeschen@example.org"
    with _playwright() as p:
        browser = _browser(p)
        if browser is None:
            pytest.skip("kein Chromium fuer Playwright")
        try:
            ctx = browser.new_context(bypass_csp=True, viewport={"width": 1280, "height": 900})
            page = ctx.new_page()
            errors = []
            page.on("pageerror", lambda e: errors.append(str(e)))
            _register_in_form(page, base, email)
            cookie = _cookie(ctx)
            _skip_first_start(page, base, cookie, email)
            page.click("#avatar")
            page.wait_for_selector("#accDelete", timeout=T)
            page.click("#accDelete")
            page.wait_for_selector("#adOk", timeout=T)
            text = page.text_content("#overlay")
            assert "sofort gesperrt" in text and "30 Tagen" in text and "nicht rückgängig" in text
            assert "Abo mit Karte" in text and "beenden wir dabei sofort" in text and "Apple" in text, "ehrlicher Hinweis aufs Abo"
            assert page.is_disabled("#adOk"), "erst nach Bestaetigung"
            page.check("#adSure")
            # falsches Passwort: Hinweis im Fenster, keine Umleitung zur Anmeldung, nichts geloescht
            page.fill("#adPw", "falsches-passwort-1")
            page.click("#adOk")
            page.wait_for_selector("#adMsg:not([hidden])", timeout=T)
            assert "Passwort" in page.text_content("#adMsg")
            assert not page.url.rstrip("/").endswith("/login")
            assert _http(base, "GET", "/api/account/me", cookie=cookie)[0] == 200
            # richtiges Passwort
            page.fill("#adPw", PASSWORD)
            page.click("#adOk")
            page.wait_for_selector("#adDone", timeout=T)
            assert "gelöscht" in page.text_content("#overlay")
            page.click("#adDone")
            page.wait_for_url(re.compile(r"/login"), timeout=T)
            assert _http(base, "GET", "/api/account/me", cookie=cookie)[0] == 401
            with accounts.cursor() as conn:
                assert conn.execute("SELECT COUNT(*) FROM users WHERE status='deleted'").fetchone()[0] == 1
            assert errors == [], errors
        finally:
            browser.close()
