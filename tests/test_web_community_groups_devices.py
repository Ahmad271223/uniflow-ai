"""Lerngruppe auf einem zweiten Geraet (Befund 5.4 in docs/paritaet/COMMUNITY-UND-ABGLEICH-2026-11-09.md, 12.11.2026).

Der Beitrittscode liegt nie beim Dienst, nur in dem Browser bzw. der Windows-App, die beigetreten ist. Bisher fehlte die
Gruppe auf jedem weiteren Geraet desselben Kontos ganz. Jetzt erscheint sie dort mit "Code hier einmal eingeben"; ein
falscher Code wird abgewiesen, der richtige schaltet sie frei. Echter Browser, Dienst im Modus hosted; ohne Chromium
uebersprungen."""
import pytest
from test_pwa import _browser
from test_web_community_channel import login, new_user, wait_text
from test_web_hosted_e2e import T, _playwright, served_hosted  # noqa: F401


def test_group_from_another_device_asks_for_the_code_once(served_hosted):  # noqa: F811
    base = served_hosted
    _, token = new_user(base, "gruppe@example.org")
    with _playwright() as p:
        browser = _browser(p)
        if browser is None:
            pytest.skip("kein Chromium fuer Playwright")
        try:
            errors = []
            # Geraet 1 legt die Lerngruppe an (der Code bleibt in seinem Speicher)
            one = browser.new_context(bypass_csp=True)
            login(one, base, token)
            a = one.new_page()
            a.on("pageerror", lambda e: errors.append(str(e)))
            a.goto(f"{base}/#/community")
            a.wait_for_selector("#grpNew", timeout=T)
            a.fill("#grpName", "Mathe-Runde")
            a.click("#grpNew")
            wait_text(a, "#spacesCard", "Mathe-Runde")
            code = a.evaluate("JSON.parse(localStorage.getItem('community-groups'))[0].code")
            assert len(code) == 8, code
            assert a.locator("[data-punlock]").count() == 0, "auf dem Geraet mit Code nichts freizuschalten"

            # Geraet 2: gleiches Konto, leerer Speicher
            two = browser.new_context(bypass_csp=True)
            login(two, base, token)
            b = two.new_page()
            b.on("pageerror", lambda e: errors.append(str(e)))
            b.goto(f"{base}/#/community")
            wait_text(b, "#spacesCard", "auf einem anderen Gerät beigetreten")
            assert "Mathe-Runde" in b.inner_text("#spacesCard")
            assert b.locator("[data-open]").count() == 0, "ohne Code laesst sich die Gruppe hier noch nicht oeffnen"
            wrong = "ZZZZZZZZ" if code != "ZZZZZZZZ" else "YYYYYYYY"
            b.fill("[data-pcode]", wrong)
            b.click("[data-punlock]")
            b.wait_for_function("() => /gehört nicht zu dieser Lerngruppe/.test(document.body.textContent)", timeout=T)
            assert b.evaluate("localStorage.getItem('community-groups')") in (None, "[]")
            b.fill("[data-pcode]", code.lower())          # Kleinschreibung wie beim Abtippen
            b.click("[data-punlock]")
            b.wait_for_selector("[data-open]", timeout=T)
            assert b.locator("[data-punlock]").count() == 0
            assert f"Code {code}" in b.inner_text("#spacesCard")
            assert b.evaluate("JSON.parse(localStorage.getItem('community-groups'))[0].code") == code
            assert not errors, errors
        finally:
            browser.close()
