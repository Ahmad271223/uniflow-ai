"""Rechtsseiten aus docs/release: /datenschutz, /nutzungsbedingungen, /impressum, /konto-loeschen als HTML mit CSP,
ohne Sitzung (auch gehostet), Platzhalter markiert, Tabellen gerendert, Links auf der Anmeldeseite und im Konto-Menue."""
import re
from pathlib import Path

import pytest
from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]


def _h(headers, name):
    return [v.decode() for k, v in headers if k == name.encode()]


@pytest.mark.parametrize("page", ["datenschutz", "nutzungsbedingungen", "impressum", "konto-loeschen"])
def test_legal_page_renders_markdown_with_csp(app, page):
    from app import legal
    st, h, body = asgi_call(app, "GET", f"/{page}")
    assert st == 200 and _h(h, "content-type")[0].startswith("text/html")
    assert "script-src 'self'" in _h(h, "content-security-policy")[0] and "no-cache" in _h(h, "cache-control")[0]
    html = body.decode("utf-8")
    md = (legal.legal_dir() / legal.PAGES[page][0]).read_text(encoding="utf-8")
    title = legal.title_of(md, "")
    assert f"<title>{title} – UniFlow</title>" in html and f"<h1>{title}</h1>" in html
    assert re.findall(r"<script[^>]*src=\"/theme.js", html) and "<script>" not in html, "kein Inline-Skript"
    for other in legal.PAGES:
        assert f'href="/{other}"' in html, "Navigation zu allen Rechtsseiten"
    assert '<a href="/">Zur App</a>' in html
    assert "[[" not in re.sub(r"<mark class=\"todo\"[^>]*>\[\[[^\]]+\]\]</mark>", "", html), "jeder Platzhalter markiert"
    assert "noch auszufüllen" in html


def test_tables_lists_and_escaping(app):
    st, _, body = asgi_call(app, "GET", "/nutzungsbedingungen")
    article = body.decode("utf-8").split("<article>")[1].split("</article>")[0]
    assert "<table>" in article and "<th>Funktion</th>" in article and "<li>" in article
    assert "<strong>" in article and "<code>" in article
    assert "**" not in article and "|---|" not in article and (chr(10) + "# ") not in article, "Markdown vollstaendig gerendert"
    assert "&amp;" in article or "&" not in article.replace("&lt;", "").replace("&gt;", "").replace("&amp;", "").replace("&quot;", "")


def test_pages_are_public_in_hosted_mode_and_link_to_login(app, monkeypatch):
    from app import config
    monkeypatch.setattr(config, "MODE", "hosted")
    st, h, body = asgi_call(app, "GET", "/impressum")
    assert st == 200 and '<a href="/login">Anmelden</a>' in body.decode("utf-8")
    assert asgi_call(app, "GET", "/")[0] == 302, "Startseite bleibt geschuetzt"


def test_missing_file_gives_404_not_500(app, monkeypatch, tmp_path):
    monkeypatch.setenv("LERNAPP_LEGAL_DIR", str(tmp_path))
    st, h, body = asgi_call(app, "GET", "/datenschutz")
    assert st == 404 and b"Seite nicht vorhanden" in body and _h(h, "content-type")[0].startswith("text/html")
    assert asgi_call(app, "GET", "/agb")[0] == 404, "nur die vier bekannten Seiten"


def test_login_page_and_account_menu_link_to_the_pages():
    login = (ROOT / "app" / "static" / "login.html").read_text(encoding="utf-8")
    for p in ("/datenschutz", "/nutzungsbedingungen", "/impressum"):
        assert f'href="{p}"' in login
    assert "stimmst du den" in login and "Nutzungsbedingungen</a> zu" in login, "Einwilligung beim Konto anlegen"
    app_js = (ROOT / "app" / "static" / "app.js").read_text(encoding="utf-8")
    for p in ("/datenschutz", "/nutzungsbedingungen", "/impressum", "/konto-loeschen"):
        assert f'href="{p}"' in app_js
    spec = (ROOT / "apps" / "windows" / "backend" / "uniflow-backend.spec").read_text(encoding="utf-8")
    assert '"docs/release"' in spec, "Windows-Paket nimmt die Rechtsseiten mit"
