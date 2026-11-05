"""Tarifseite im echten Browser (05.11.2026, Paket D "Tarife, Probe, Einladungen"): drei Karten Free / Plus / Pro AI nach
der Entscheidung des Inhabers vom 04.11.2026.

- Eigener PC / Windows-App (Einzelplatz): keine Kaufwege; StudiNow Pro AI steht ohne Preis und ohne Knopf als "kommt mit
  dem StudiNow-Dienst" da (Microsoft-Store-Regeln, docs/release/MICROSOFT-STORE.md).
- Dienst mit Stripe: Kaufknoepfe nur an Plus und Pro AI, nie an Free; waehrend der Probe ist kein Tarif "Dein Tarif",
  die Karte "Pro AI" traegt "Probe läuft" und bleibt kaufbar; nach der Probe "Deine Probe ist vorbei" und Free als Stand.
- Nirgends Pro Connect, "1 Woche gratis" oder ein Einfuehrungsangebot.
Ohne Chromium wird uebersprungen (wie tests/test_pwa.py)."""
import re

import pytest
from test_pwa import _browser, served  # noqa: F401
from test_web_community_channel import _http, login, new_user
from test_web_hosted_e2e import PASSWORD, T, _playwright, served_hosted  # noqa: F401

VERBOTEN = re.compile(r"Pro Connect|Woche gratis|Einführungsangebot|Einfuehrungsangebot|Probe-Angebot", re.I)


def _cards(page):
    """Karten als Liste von {name, text, buttons, buy}."""
    return page.evaluate("""() => [...document.querySelectorAll('#view .plans .plan')].map(a => ({
        name: a.querySelector('h2').textContent.trim(), text: a.textContent.replace(/\\s+/g, ' ').trim(),
        buttons: [...a.querySelectorAll('button')].map(b => b.textContent.trim()),
        buy: a.querySelectorAll('[data-buy]').length, badges: [...a.querySelectorAll('.badge')].map(b => b.textContent.trim()) }))""")


def test_local_pro_ai_card_has_no_price_and_no_buy_path(served):  # noqa: F811
    """Einzelplatz (Windows-App): Pro AI "kommt mit dem StudiNow-Dienst", ohne 3,99 EUR und ohne Knopf; nirgends ein
    Kaufknopf, Stripe oder Link zu einem Bezahlsystem; Plus zeigt seinen Preis, aber auch keinen Knopf."""
    with _playwright() as p:
        browser = _browser(p)
        if browser is None:
            pytest.skip("kein Chromium fuer Playwright")
        try:
            errors = []
            page = browser.new_context(bypass_csp=True).new_page()
            page.on("pageerror", lambda e: errors.append(str(e)))
            page.goto(f"{served}/#/abo")
            page.wait_for_function("document.querySelectorAll('#view .plans .plan').length === 3", timeout=T)
            cards = _cards(page)
            assert [c["name"] for c in cards] == ["StudiNow Free", "StudiNow Plus", "StudiNow Pro AI"], "genau drei Karten"
            free, plus, pro = cards
            assert "0 €" in free["text"] and "1,99 €" in plus["text"]
            assert "kommt mit dem StudiNow-Dienst" in pro["text"] and "Braucht den StudiNow-Dienst" in pro["text"]
            assert "3,99" not in pro["text"] and "€" not in pro["text"], "Pro AI ohne Preis"
            assert all(c["buttons"] == [] and c["buy"] == 0 for c in cards), "im Einzelplatz kein Knopf an einer Karte"
            view = page.inner_text("#view")
            assert page.evaluate("document.querySelectorAll('#view [data-buy], #view [data-portal], #view a[href*=stripe]').length") == 0
            assert "Stripe" not in view and not VERBOTEN.search(view), view[:400]
            assert "Auf diesem PC kannst du nichts kaufen" in view and "kommt mit dem StudiNow-Dienst" in view
            assert "Dein Tarif" not in view, "Einzelplatz hat keinen Tarif"
            assert not errors, errors
        finally:
            browser.close()


@pytest.fixture
def with_stripe(monkeypatch):
    monkeypatch.setenv("LERNAPP_STRIPE_SECRET_KEY", "sk_test_x")
    monkeypatch.setenv("LERNAPP_STRIPE_WEBHOOK_SECRET", "whsec_test")
    monkeypatch.setenv("LERNAPP_STRIPE_PRICES", "plus=price_plus,pro_connect=price_pc,pro_ai=price_ai")
    monkeypatch.setenv("LERNAPP_PUBLIC_URL", "https://app.studinow.example")


def test_hosted_trial_then_free_cards_and_buy_buttons(served_hosted, with_stripe):  # noqa: F811
    """Dienst mit Stripe: Probe-Konto sieht "Probe läuft" statt "Dein Tarif" und kann Plus UND Pro AI abschliessen
    (Pro Connect nie); nach der Probe ist Free "Dein Tarif", die Aufforderung steht da, die Knoepfe bleiben."""
    from app import accounts
    base = served_hosted
    st, d = _http(base, "POST", "/api/account/register", {"email": "probe@example.org", "password": PASSWORD, "university": "luh"})
    assert st == 201, d
    probe_user, probe_tok = d["user"], d["token"]
    with _playwright() as p:
        browser = _browser(p)
        if browser is None:
            pytest.skip("kein Chromium fuer Playwright")
        try:
            errors = []
            ctx = browser.new_context(bypass_csp=True)
            login(ctx, base, probe_tok)
            page = ctx.new_page()
            page.on("pageerror", lambda e: errors.append(str(e)))
            page.goto(f"{base}/#/abo")
            page.wait_for_function("document.querySelectorAll('#view .plans .plan').length === 3", timeout=T)
            cards = _cards(page)
            assert [c["name"] for c in cards] == ["StudiNow Free", "StudiNow Plus", "StudiNow Pro AI"]
            free, plus, pro = cards
            assert "1,99 €" in plus["text"] and "3,99 €" in pro["text"] and "kommt mit dem StudiNow-Dienst" not in pro["text"]
            assert free["buy"] == 0 and plus["buy"] == 1 and pro["buy"] == 1, "Kaufen: Plus und Pro AI, nie Free"
            assert "Probe läuft" in pro["badges"] and "Dein Tarif" not in sum((c["badges"] for c in cards), [])
            view = page.inner_text("#view")
            assert "Probe: alles wie StudiNow Pro AI" in view and "ohne Zahlungsdaten" in view and "nie von selbst kostenpflichtig" in view
            assert page.evaluate("document.querySelector('#view .sub').textContent.trim()") == "Probe: alles wie StudiNow Pro AI"
            assert not VERBOTEN.search(view), view[:400]
            ctx.close()

            # Probe vorbei, nichts gewaehlt: Free ist der Stand, die Aufforderung steht da
            accounts.mark_email_verified(probe_user["id"])
            assert accounts.end_trial(probe_user["id"])
            ctx = browser.new_context(bypass_csp=True)
            login(ctx, base, probe_tok)
            page = ctx.new_page()
            page.on("pageerror", lambda e: errors.append(str(e)))
            page.goto(f"{base}/#/abo")
            page.wait_for_function("document.querySelectorAll('#view .plans .plan').length === 3", timeout=T)
            cards = _cards(page)
            free, plus, pro = cards
            assert "Dein Tarif" in free["badges"] and plus["buy"] == 1 and pro["buy"] == 1 and free["buy"] == 0
            view = page.inner_text("#view")
            assert "Dein Tarif: StudiNow Free" in view and "Deine Probe ist vorbei" in view and "Bei Free bleiben" in view
            assert not VERBOTEN.search(view), view[:400]
            assert not errors, errors
        finally:
            browser.close()


def test_hosted_without_stripe_has_no_buy_button_and_never_pro_connect(served_hosted):  # noqa: F811
    """Dienst ohne Stripe: kein Kaufknopf im Web, nur der Hinweis auf die Apple-App (kein erfundener Kaufweg)."""
    base = served_hosted
    _, tok = new_user(base, "plus-ohne-stripe@example.org")
    with _playwright() as p:
        browser = _browser(p)
        if browser is None:
            pytest.skip("kein Chromium fuer Playwright")
        try:
            ctx = browser.new_context(bypass_csp=True)
            login(ctx, base, tok)
            page = ctx.new_page()
            page.goto(f"{base}/#/abo")
            page.wait_for_function("document.querySelectorAll('#view .plans .plan').length === 3", timeout=T)
            cards = _cards(page)
            assert all(c["buy"] == 0 for c in cards)
            assert "Dein Tarif" in cards[1]["badges"], "Plus ist der gekaufte Stand"
            assert cards[2]["buttons"] == ["In der Apple-App abschließen"]
            assert not VERBOTEN.search(page.inner_text("#view"))
        finally:
            browser.close()
