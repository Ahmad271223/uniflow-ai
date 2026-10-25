"""Anmeldung ueber ein Apereo-CAS (z. B. Uni Hildesheim: https://www.uni-hildesheim.de/sso).

Ablauf: Dienst-URL ueber /login?service=... aufrufen. Ist die CAS-Sitzung noch gueltig, leitet das CAS sofort
zurueck. Sonst stehen Benutzer- und Passwortfeld auf der Seite; die App traegt die Zugangsdaten aus der lokalen
.env ein. Das Passwort verlaesst nur in Richtung des CAS-Servers den Rechner.
"""
from __future__ import annotations

from typing import Callable
from urllib.parse import quote, urlparse

USER_SELECTORS = ("input#username:visible", "input[name='username']:visible", "input[autocomplete='username']:visible")
PASS_SELECTORS = ("input#password:visible", "input[name='password']:visible", "input[type='password']:visible")
SUBMIT_SELECTORS = "button[name='submit']:visible, input[name='submit']:visible, button[type='submit']:visible, input[type='submit']:visible"
ERROR_SELECTORS = "#loginErrorsPanel, .login-error, .alert-danger, #msg.errors, .banner-danger"


class CasLoginError(RuntimeError):
    pass


def login_url(cas_base: str, service: str) -> str:
    return f"{cas_base.rstrip('/')}/login?service={quote(service, safe='')}"


def is_cas_page(url: str, cas_base: str) -> bool:
    """True, wenn die URL auf die CAS-Loginseite zeigt (dann fehlt noch die Anmeldung)."""
    u, c = urlparse(url or ""), urlparse(cas_base)
    host = lambda p: p.netloc.lower().removeprefix("www.")
    return host(u) == host(c) and u.path.rstrip("/").startswith(c.path.rstrip("/") + "/login")


def _first(page, selectors):
    for sel in selectors:
        loc = page.locator(sel)
        if loc.count() > 0:
            return loc.first
    return None


def login(page, entry_url: str, cas_base: str, user: str, password: str,
          is_logged_in: Callable[[], bool], log: Callable[[str], None] = print, timeout_ms: int = 45000) -> None:
    """Oeffnet entry_url (Dienst oder CAS-Link) und meldet sich am CAS an, falls noetig.
    is_logged_in() prueft danach den Dienst selbst (z. B. 'Abmelden'-Link oder Moodle-Sesskey)."""
    page.goto(entry_url, wait_until="domcontentloaded")
    page.wait_for_timeout(800)
    if not is_cas_page(page.url, cas_base) and is_logged_in():
        log("CAS: Sitzung war noch gueltig.")
        return
    if not user or not password:
        raise CasLoginError("Zugangsdaten fehlen. Bitte in der App unter Einstellungen > Zugang den UNI-Account eintragen.")
    pw_field = None
    for _ in range(int(timeout_ms / 500)):
        pw_field = _first(page, PASS_SELECTORS)
        if pw_field is not None:
            break
        page.wait_for_timeout(500)
    if pw_field is None:
        raise CasLoginError(f"CAS-Loginformular nicht gefunden (URL: {page.url})")
    user_field = _first(page, USER_SELECTORS)
    if user_field is None:
        raise CasLoginError("Benutzerfeld auf der CAS-Seite nicht gefunden")
    user_field.fill(user)
    pw_field.fill(password)
    btn = page.locator(SUBMIT_SELECTORS)
    if btn.count() > 0:
        btn.first.click()
    else:
        pw_field.press("Enter")
    page.wait_for_load_state("domcontentloaded")
    page.wait_for_timeout(1500)
    if is_cas_page(page.url, cas_base):
        err = page.locator(ERROR_SELECTORS)
        msg = err.first.inner_text().strip()[:200] if err.count() else "weiterhin auf der Loginseite"
        raise CasLoginError(f"CAS-Anmeldung fehlgeschlagen: {msg}")
    for _ in range(6):
        if is_logged_in():
            log("CAS: Anmeldung erfolgreich.")
            return
        page.wait_for_timeout(1000)
    raise CasLoginError(f"Nach der CAS-Anmeldung ist der Dienst nicht angemeldet (URL: {page.url})")
