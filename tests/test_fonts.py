"""Schrift Inter wird selbst ausgeliefert (app/static/fonts): keine Anfrage an Google Fonts, CSP ohne fremde Hosts,
Schriftdateien echt (WOFF2) und mit Lizenz, HTML-Seiten binden nur die eigene inter.css ein."""
import re
from pathlib import Path

from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
STATIC = ROOT / "app" / "static"
PAGES = ("index.html", "login.html")
FONTS = ("InterVariable.woff2", "InterVariable-Italic.woff2")


def _h(headers, name):
    return [v.decode() for k, v in headers if k == name.encode()]


def test_pages_load_only_the_local_font_stylesheet():
    for page in PAGES:
        html = (STATIC / page).read_text(encoding="utf-8")
        assert "googleapis" not in html and "gstatic" not in html and "preconnect" not in html, page
        assert 'href="fonts/inter.css' in html, page
        # keine fremden Adressen in Stylesheets oder Skripten der Seite
        for url in re.findall(r'(?:href|src)="([^"]+)"', html):
            assert not url.startswith(("http:", "https:", "//")), (page, url)


def test_font_files_are_real_woff2_with_licence_and_css_declares_both_styles():
    for f in FONTS:
        data = (STATIC / "fonts" / f).read_bytes()
        assert data[:4] == b"wOF2" and len(data) > 100_000, f
    lic = (STATIC / "fonts" / "LICENSE-Inter.txt").read_text(encoding="utf-8")
    assert "SIL Open Font License" in lic and "Inter" in lic
    css = (STATIC / "fonts" / "inter.css").read_text(encoding="utf-8")
    assert css.count("@font-face") == 2 and 'font-family: "Inter"' in css and "font-weight: 100 900" in css
    assert "font-style: normal" in css and "font-style: italic" in css and "font-display: swap" in css
    for f in FONTS:
        assert f'url("{f}")' in css
    assert "http" not in css


def test_server_serves_font_css_and_woff2_with_proper_types(app):
    st, h, body = asgi_call(app, "GET", "/fonts/inter.css")
    assert st == 200 and _h(h, "content-type")[0].startswith("text/css") and b"InterVariable.woff2" in body
    assert "no-cache" in _h(h, "cache-control")[0]          # CSS wie alle Oberflaechendateien
    st, h, body = asgi_call(app, "GET", "/fonts/InterVariable.woff2")
    assert st == 200 and body[:4] == b"wOF2"
    assert _h(h, "content-type")[0] in ("font/woff2", "application/font-woff2", "application/octet-stream")
    assert _h(h, "etag"), "Schriftdateien duerfen der Browser zwischenspeichern (ETag)"


def test_csp_allows_no_external_hosts(app):
    from app.server import UI_CSP
    assert "http" not in UI_CSP and "googleapis" not in UI_CSP and "gstatic" not in UI_CSP
    assert "font-src 'self' data:" in UI_CSP and "style-src 'self' 'unsafe-inline'" in UI_CSP
    st, h, _ = asgi_call(app, "GET", "/")
    assert st == 200 and _h(h, "content-security-policy") == [UI_CSP]


def test_no_google_fonts_reference_anywhere_in_the_shipped_code():
    """Weder Backend noch Oberflaeche noch Windows-Fenster nennen Google Fonts (Backups und Doku ausgenommen)."""
    hits = []
    for base in (ROOT / "app", ROOT / "apps" / "windows" / "src-tauri", ROOT / "apps" / "windows" / "dist"):
        for p in base.rglob("*"):
            if p.suffix in (".py", ".js", ".html", ".css", ".json", ".rs") and "target" not in p.parts and "dist" not in p.parts[-3:-1]:
                try:
                    text = p.read_text(encoding="utf-8")
                except (UnicodeDecodeError, OSError):
                    continue
                if "fonts.googleapis.com" in text or "fonts.gstatic.com" in text:
                    hits.append(str(p.relative_to(ROOT)))
    assert not hits, hits
