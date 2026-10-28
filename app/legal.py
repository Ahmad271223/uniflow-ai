"""Oeffentliche Rechtsseiten (/datenschutz, /nutzungsbedingungen, /impressum, /konto-loeschen) aus den Markdown-Dateien
in docs/release. Die Dateien sind die einzige Quelle: Aenderungen dort sind sofort online. Platzhalter [[...]] bleiben
sichtbar markiert, bis der Inhaber sie ersetzt. Ohne Sitzung erreichbar (auch im gehosteten Modus), kein Inline-Skript,
gleiche CSP wie die App; im Windows-Paket liegen die Dateien unter docs/release neben app/static."""
from __future__ import annotations

import html
import os
import re
from pathlib import Path

import markdown

from . import config

PAGES = {                                              # Pfad -> (Datei, Name in der Navigation)
    "datenschutz": ("DATENSCHUTZ.md", "Datenschutz"),
    "nutzungsbedingungen": ("NUTZUNGSBEDINGUNGEN.md", "Nutzungsbedingungen"),
    "impressum": ("IMPRESSUM.md", "Impressum"),
    "konto-loeschen": ("KONTO-LOESCHEN.md", "Konto löschen"),
}
_PLACEHOLDER = re.compile(r"\[\[([^\]]+)\]\]")

STYLE = """
.legal { max-width: 860px; margin: 0 auto; padding: 1.2rem 1rem 3rem; }
.legal header { display: flex; flex-wrap: wrap; align-items: center; gap: .6rem 1.4rem; padding: .4rem 0 1rem; border-bottom: 1px solid var(--line); margin-bottom: 1.2rem; }
.legal header .brand { padding: 0; }
.legal nav { display: flex; flex-wrap: wrap; gap: .2rem 1rem; }
.legal nav a { color: var(--accent-text); text-decoration: none; } .legal nav a:hover { text-decoration: underline; } .legal nav a.active { font-weight: 650; }
.legal article h1 { font-size: 1.5rem; margin: .6rem 0 1rem; } .legal article h2 { margin: 1.7rem 0 .5rem; } .legal article h3 { margin: 1.2rem 0 .4rem; }
.legal article p, .legal article li { line-height: 1.6; } .legal article ul, .legal article ol { padding-left: 1.4rem; }
.legal article table { border-collapse: collapse; width: 100%; font-size: .9rem; margin: .8rem 0; display: block; overflow-x: auto; }
.legal article th, .legal article td { border: 1px solid var(--line); padding: .4rem .6rem; text-align: left; vertical-align: top; }
.legal article code { background: var(--surface-2); padding: .05rem .3rem; border-radius: 4px; font-size: .9em; }
.legal article a { color: var(--accent-text); }
.legal mark.todo { background: var(--warn-soft); color: var(--warn); padding: 0 .2rem; border-radius: 3px; }
.legal footer { margin-top: 2rem; padding-top: 1rem; border-top: 1px solid var(--line); }
"""

TEMPLATE = """<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} – Studora</title>
<meta name="robots" content="noindex">
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/fonts/inter.css?v=29">
<link rel="stylesheet" href="/style.css?v=29">
<style>{style}</style>
<script src="/theme.js?v=29"></script>
</head>
<body class="legal">
<header><div class="brand"><div class="logo">S</div><span>Studora</span></div><nav>{nav}</nav></header>
<article>{body}</article>
<footer class="muted small">{foot}</footer>
</body>
</html>
"""


def legal_dir() -> Path:
    """Ordner mit den Markdown-Dateien: LERNAPP_LEGAL_DIR oder docs/release im Projekt bzw. im Windows-Paket."""
    env = (os.environ.get("LERNAPP_LEGAL_DIR") or "").strip()
    return Path(env) if env else config.ROOT / "docs" / "release"


def source(page: str) -> Path | None:
    if page not in PAGES:
        return None
    p = legal_dir() / PAGES[page][0]
    return p if p.is_file() else None


def title_of(text: str, fallback: str) -> str:
    for line in text.splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return fallback


def render_markdown(text: str) -> str:
    body = markdown.markdown(text, extensions=["tables", "sane_lists"], output_format="html")
    return _PLACEHOLDER.sub(lambda m: f'<mark class="todo" title="noch auszufüllen">[[{m.group(1)}]]</mark>', body)


def render(page: str, hosted: bool) -> tuple[str, str] | None:
    """(Titel, fertige HTML-Seite) oder None, wenn es die Seite oder Datei nicht gibt."""
    src = source(page)
    if not src:
        return None
    text = src.read_text(encoding="utf-8")
    title = title_of(text, PAGES[page][1])
    nav = "".join(f'<a href="/{k}"{" class=\"active\"" if k == page else ""}>{html.escape(n)}</a>' for k, (_, n) in PAGES.items())
    nav += '<a href="/login">Anmelden</a>' if hosted else '<a href="/">Zur App</a>'
    foot = ("Fragen zu diesen Texten: siehe Impressum. Die markierten Stellen sind noch auszufüllen."
            if _PLACEHOLDER.search(text) else "Fragen zu diesen Texten: siehe Impressum.")
    doc = TEMPLATE.format(title=html.escape(title), style=STYLE, nav=nav, body=render_markdown(text), foot=foot)
    return title, doc
