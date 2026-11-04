#!/usr/bin/env python3
"""Oeffentliche Website studinow.app als statische Seiten (site/) aus den Markdown-Dateien in docs/release bauen.

Die Markdown-Dateien sind die einzige Quelle (dieselben, die der Dienst unter /datenschutz usw. ausliefert, app/legal.py):
    STARTSEITE.md -> index.html            SUPPORT.md -> support.html
    DATENSCHUTZ.md -> datenschutz.html     NUTZUNGSBEDINGUNGEN.md -> nutzungsbedingungen.html
    IMPRESSUM.md -> impressum.html         KONTO-LOESCHEN.md -> konto-loeschen.html
    EINLADUNG.md -> i/index.html           (Einladungsseite hinter https://studinow.app/i/<CODE>, nicht in der Navigation)
dazu .well-known/apple-app-site-association (Universal Links /i/* fuer die iPad-App; Team-ID aus apps/apple/Config/Team.xcconfig,
sonst Platzhalter [[TEAMID]]), style.css (eine Datei, Farben der App aus app/static/style.css bzw. UFTheme.swift, dunkel nach Systemeinstellung
ohne Skript) und icon.svg (Kopie von app/static/icon.svg). Kein Skript, keine fremden Ressourcen, keine Schriften von
Dritten. Fusszeile und Beschreibung kommen aus docs/release/angaben.json.

Offene Platzhalter [[...]] bleiben wie im Dienst gelb markiert (zur Zeit nur der Hoster in der Datenschutzerklaerung).
Links auf https://studinow.app/<seite> werden zu <seite>.html, damit die Seiten auch lokal (python3 -m http.server)
und auf Vorschau-Adressen des Hosts funktionieren; auf dem Host zeigt /datenschutz dank "clean URLs" auf datenschutz.html.

Aufruf:  python tools/gen-site.py [--out ORDNER]      (Standard: site/ im Projekt; tests/test_site.py prueft den Stand)
"""
from __future__ import annotations

import argparse
import html
import json
import re
import sys
from pathlib import Path

import markdown

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "docs" / "release"
ICON = ROOT / "app" / "static" / "icon.svg"
DEFAULT_OUT = ROOT / "site"
DOMAIN = "studinow.app"

# (Markdown, Ausgabe, Name in der Navigation, Beschreibung fuer <meta name="description">)
PAGES = [
    ("STARTSEITE.md", "index.html", "Start",
     "StudiNow bringt Skripte, Termine, Stundenplan, Lernkalender und handschriftliche Notizen aufs iPad – ohne Tracking."),
    ("SUPPORT.md", "support.html", "Support",
     "Hilfe zu StudiNow: Anmeldung bei der Hochschule, Daten auf dem iPad, Konto löschen, Abo. Kontakt support@studinow.app."),
    ("DATENSCHUTZ.md", "datenschutz.html", "Datenschutz", "Datenschutzerklärung der StudiNow-Apps und des StudiNow-Dienstes."),
    ("NUTZUNGSBEDINGUNGEN.md", "nutzungsbedingungen.html", "Nutzungsbedingungen",
     "Nutzungsbedingungen für die StudiNow-Apps, die Web-Oberfläche und den StudiNow-Dienst."),
    ("IMPRESSUM.md", "impressum.html", "Impressum", "Impressum von StudiNow (IT solutions by Ahmad Fakih)."),
    ("KONTO-LOESCHEN.md", "konto-loeschen.html", "Konto löschen", "So löschst du dein StudiNow-Konto in der App oder per E-Mail."),
]
# Seiten ausserhalb der Navigation: (Markdown, Ausgabe in einem Unterordner, Titel-Rueckfall, Beschreibung)
EXTRA_PAGES = [
    ("EINLADUNG.md", "i/index.html", "Einladung",
     "Du bist zu StudiNow eingeladen: App laden, Konto anlegen, Einladung annehmen. Die einladende Person bekommt Angebotscodes."),
]
SLUGS = {out[:-5]: out for _, out, _, _ in PAGES if out != "index.html"}
AASA_PATH = ".well-known/apple-app-site-association"
TEAM_XCCONFIG = ROOT / "apps" / "apple" / "Config" / "Team.xcconfig"
BUNDLE_ID = "de.uniflow.ai"
PLACEHOLDER = re.compile(r"\[\[([^\]]+)\]\]")
SITE_LINK = re.compile(r'href="https://' + re.escape(DOMAIN) + r'(?:/([a-z-]+))?/?"')

CSS = """\
/* StudiNow – Website. Farben wie die App (app/static/style.css, UFTheme.swift); dunkel nach Systemeinstellung. */
:root {
  color-scheme: light dark;
  --bg: #f6f7fb; --surface: #ffffff; --surface-2: #f1f3f9; --line: #e5e8f0; --line-strong: #d3d8e4;
  --text: #171a26; --text-2: #4b5168; --muted: #5f667d;
  --accent: #4f5bd5; --accent-strong: #3f4bc2; --accent-soft: #eceefc; --accent-text: #3a45b4;
  --warn: #8a4d03; --warn-soft: #fdf0dc; --on-fill: #ffffff;
  --r: 14px; --r-sm: 8px;
  --font: Inter, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", sans-serif;
  --mono: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0f1117; --surface: #171a23; --surface-2: #1f2330; --line: #262b3a; --line-strong: #333a4d;
    --text: #e8eaf2; --text-2: #b3b9cc; --muted: #8b93a9;
    --accent: #7b86f0; --accent-strong: #6a76e8; --accent-soft: #232848; --accent-text: #a9b1ff;
    --warn: #e9a04a; --warn-soft: #3a2a14; --on-fill: #0f1117;
  }
}
* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
body { margin: 0; font: 16px/1.6 var(--font); color: var(--text); background: var(--bg); min-height: 100vh; }
a { color: var(--accent-text); text-decoration: none; }
a:hover, a:focus-visible { text-decoration: underline; }
h1, h2, h3 { line-height: 1.25; font-weight: 650; letter-spacing: -.01em; }
h1 { font-size: 1.9rem; margin: .4rem 0 1rem; }
h2 { font-size: 1.25rem; margin: 2rem 0 .6rem; }
h3 { font-size: 1.05rem; margin: 1.4rem 0 .4rem; }
p, li { color: var(--text); }
ul, ol { padding-left: 1.4rem; }
li { margin: .25rem 0; }
code { font-family: var(--mono); font-size: .9em; background: var(--surface-2); padding: .05rem .35rem; border-radius: 4px; overflow-wrap: anywhere; }
table { border-collapse: collapse; width: 100%; font-size: .92rem; margin: .8rem 0; display: block; overflow-x: auto; }
th, td { border: 1px solid var(--line); padding: .45rem .6rem; text-align: left; vertical-align: top; }
th { background: var(--surface-2); }
hr { border: 0; border-top: 1px solid var(--line); margin: 2rem 0; }
mark.todo { background: var(--warn-soft); color: var(--warn); padding: 0 .25rem; border-radius: 3px; }

.header { background: var(--surface); border-bottom: 1px solid var(--line); }
.header .inner { max-width: 960px; margin: 0 auto; padding: .8rem 16px; display: flex; flex-wrap: wrap; align-items: center; gap: .5rem 1.4rem; }
.brand { display: flex; align-items: center; gap: .6rem; color: var(--text); font-weight: 700; font-size: 1.05rem; }
.brand img { width: 30px; height: 30px; border-radius: 9px; display: block; }
.nav { display: flex; flex-wrap: wrap; gap: .1rem .3rem; margin-left: auto; }
.nav a { padding: .35rem .65rem; border-radius: var(--r-sm); color: var(--text-2); font-weight: 500; font-size: .95rem; }
.nav a:hover { background: var(--surface-2); color: var(--text); text-decoration: none; }
.nav a.active { background: var(--accent-soft); color: var(--accent-text); }

main { max-width: 860px; margin: 0 auto; padding: 1.4rem 16px 3rem; }
main.home { max-width: 960px; }
main.home > h1 { font-size: 2.3rem; margin-top: 1.2rem; max-width: 20em; }
main.home > h1 + p { font-size: 1.15rem; color: var(--text-2); max-width: 38em; }
.cta { display: flex; flex-wrap: wrap; align-items: center; gap: .6rem 1rem; margin: 1.4rem 0 2rem; }
.badge { display: inline-flex; align-items: center; gap: .5rem; padding: .7rem 1.3rem; border-radius: 999px; background: var(--accent); color: var(--on-fill); font-weight: 650; }
.badge:hover { background: var(--accent-strong); text-decoration: none; }
.muted { color: var(--muted); font-size: .92rem; }
.shots { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 1rem; margin: 0 0 1.5rem; }
.shots figure { margin: 0; }
.shots .shot { aspect-ratio: 3 / 4; border: 2px dashed var(--line-strong); border-radius: var(--r); background: var(--surface); }
.shots figcaption { color: var(--muted); font-size: .9rem; margin-top: .4rem; text-align: center; }

.footer { border-top: 1px solid var(--line); color: var(--muted); font-size: .9rem; }
.footer .inner { max-width: 960px; margin: 0 auto; padding: 1.2rem 16px 2rem; display: flex; flex-wrap: wrap; gap: .3rem 1.2rem; }
.footer a { color: var(--text-2); }
@media (max-width: 600px) {
  body { font-size: 15.5px; }
  h1 { font-size: 1.6rem; }
  main.home > h1 { font-size: 1.9rem; }
  .nav { margin-left: 0; }
}
"""

TEMPLATE = """\
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="{description}">
<link rel="icon" href="{root}icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="{root}style.css">
</head>
<body>
<header class="header"><div class="inner">
<a class="brand" href="{root}index.html"><img src="{root}icon.svg" alt="" width="30" height="30">StudiNow</a>
<nav class="nav" aria-label="Seiten">{nav}</nav>
</div></header>
<main{main_class}>
{body}
</main>
<footer class="footer"><div class="inner">
<span>© {year} {owner}</span>
<a href="{root}impressum.html">Impressum</a>
<a href="{root}datenschutz.html">Datenschutz</a>
<a href="{root}nutzungsbedingungen.html">Nutzungsbedingungen</a>
<a href="{root}support.html">Support</a>
</div></footer>
</body>
</html>
"""


def owner_and_year() -> tuple[str, str]:
    """Name fuer die Fusszeile (ohne Klammerzusatz) und Jahr aus docs/release/angaben.json."""
    data = json.loads((SRC / "angaben.json").read_text(encoding="utf-8"))
    name = re.sub(r"\s*\(.*\)\s*$", "", data["name"]).strip()
    year = (data.get("datum") or "")[-4:] or "2026"
    return name, year


def title_of(text: str, fallback: str) -> str:
    for line in text.splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return fallback


def render_markdown(text: str, root: str = "") -> str:
    body = markdown.markdown(text, extensions=["tables", "sane_lists"], output_format="html")
    body = PLACEHOLDER.sub(lambda m: f'<mark class="todo" title="noch auszufüllen">[[{m.group(1)}]]</mark>', body)
    return SITE_LINK.sub(lambda m: _relative_link(m, root), body)


def _relative_link(m: re.Match, root: str = "") -> str:
    """Links auf die eigenen Seiten relativ, damit sie auch ohne Host-Regeln funktionieren; andere bleiben.
    `root` ("../") fuer Seiten in einem Unterordner."""
    slug = m.group(1) or ""
    if not slug:
        return f'href="{root}index.html"'
    return f'href="{root}{SLUGS[slug]}"' if slug in SLUGS else m.group(0)


def render_page(src_name: str, out_name: str, nav_name: str, description: str, owner: str, year: str) -> str:
    text = (SRC / src_name).read_text(encoding="utf-8")
    title = title_of(text, nav_name)
    full_title = title if title.startswith("StudiNow") else f"{title} – StudiNow"
    root = "../" * out_name.count("/")
    nav = "".join(f'<a href="{root}{o}"{" class=\"active\"" if o == out_name else ""}>{html.escape(n)}</a>' for _, o, n, _ in PAGES)
    main_class = ' class="home"' if out_name in ("index.html", "i/index.html") else ""
    return TEMPLATE.format(title=html.escape(full_title), description=html.escape(description), nav=nav, root=root,
                           main_class=main_class, body=render_markdown(text, root), owner=html.escape(owner), year=year)


def team_id() -> str:
    """Team-ID des Apple Developer Program aus apps/apple/Config/Team.xcconfig (nicht eingecheckt); sonst Platzhalter."""
    try:
        for line in TEAM_XCCONFIG.read_text(encoding="utf-8").splitlines():
            m = re.match(r"\s*DEVELOPMENT_TEAM\s*=\s*([A-Z0-9]{10})\s*$", line)
            if m:
                return m.group(1)
    except OSError:
        pass
    return "[[TEAMID]]"


def apple_app_site_association(team: str | None = None) -> str:
    """Universal Links fuer https://studinow.app/i/<CODE> (Einladungen, docs/EINLADUNGEN.md): die iPad-App oeffnet den Link,
    wenn sie installiert ist (Associated Domains applinks:studinow.app in UniFlow.entitlements). Beide Schreibweisen
    (appID/paths fuer aeltere Systeme, appIDs/components ab iOS 13). Der Host muss die Datei ohne Weiterleitung und als
    application/json ausliefern."""
    app_id = f"{team or team_id()}.{BUNDLE_ID}"
    doc = {"applinks": {"apps": [], "details": [
        {"appID": app_id, "paths": ["/i/*"]},
        {"appIDs": [app_id], "components": [{"/": "/i/*", "comment": "Einladungslink"}]},
    ]}, "webcredentials": {"apps": [app_id]}}
    return json.dumps(doc, indent=1, ensure_ascii=False) + "\n"


def build() -> dict[str, str | bytes]:
    """Alle Dateien der Website: Name -> Inhalt."""
    owner, year = owner_and_year()
    files: dict[str, str | bytes] = {"style.css": CSS, "icon.svg": ICON.read_bytes()}
    for src_name, out_name, nav_name, description in PAGES + EXTRA_PAGES:
        files[out_name] = render_page(src_name, out_name, nav_name, description, owner, year)
    files[AASA_PATH] = apple_app_site_association()
    return files


def write(out: Path) -> list[str]:
    out.mkdir(parents=True, exist_ok=True)
    names = []
    for name, content in build().items():
        p = out / name
        p.parent.mkdir(parents=True, exist_ok=True)                  # i/, .well-known/
        if isinstance(content, bytes):
            p.write_bytes(content)
        else:
            p.write_text(content, encoding="utf-8")
        names.append(name)
    return names


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Website studinow.app aus docs/release/*.md bauen.")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT, help="Zielordner (Standard: site/)")
    args = ap.parse_args(argv)
    names = write(args.out)
    open_marks = {n: len(PLACEHOLDER.findall(Path(args.out, n).read_text(encoding="utf-8"))) for n in names if n.endswith(".html")}
    print(f"{len(names)} Dateien nach {args.out}: " + ", ".join(names))
    for n, k in open_marks.items():
        if k:
            print(f"  {n}: {k} Platzhalter offen (gelb markiert)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
