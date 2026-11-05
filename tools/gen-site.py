#!/usr/bin/env python3
"""Oeffentliche Website studinow.app als statische Seiten (site/) aus den Markdown-Dateien in docs/release bauen.

Die Markdown-Dateien sind die einzige Quelle (dieselben, die der Dienst unter /datenschutz usw. ausliefert, app/legal.py):
    STARTSEITE.md -> index.html            SUPPORT.md -> support.html
    DATENSCHUTZ.md -> datenschutz.html     NUTZUNGSBEDINGUNGEN.md -> nutzungsbedingungen.html
    IMPRESSUM.md -> impressum.html         KONTO-LOESCHEN.md -> konto-loeschen.html
    EINLADUNG.md -> i/index.html           (Einladungsseite hinter https://studinow.app/i/<CODE>, nicht in der Navigation)
dazu .well-known/apple-app-site-association (Universal Links /i/* fuer die iPad-App; Team-ID aus apps/apple/Config/Team.xcconfig,
sonst Platzhalter [[TEAMID]]), style.css (eine Datei, Farben der App aus app/static/style.css bzw. UFTheme.swift, dunkel nach Systemeinstellung
ohne Skript) und icon.svg (Kopie von app/static/icon.svg), dazu _redirects und _headers fuer Netlify und img/ (Bildschirmfotos
der Startseite aus docs/release/website-img/, Demo-Inhalte, je hell und dunkel, JPEG hoechstens 1400 px breit).
Die Startseite ist seit 05.11.2026 eine Lernplattform-Startseite (STARTSEITE.md ist HTML; :i-name: setzt ein Symbol aus ICONS ein,
HTML-Kommentare fallen weg); die anderen Seiten stehen als Text in einer Karte (main.doc). Kein Skript, keine fremden Ressourcen, keine Schriften von
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
IMG_SRC = SRC / "website-img"       # Bildschirmfotos der Startseite (Demo-Inhalte, JPEG <= 1400 px), kopiert nach site/img/
DEFAULT_OUT = ROOT / "site"
DOMAIN = "studinow.app"

# (Markdown, Ausgabe, Name in der Navigation, Beschreibung fuer <meta name="description">)
PAGES = [
    ("STARTSEITE.md", "index.html", "Start",
     "StudiNow holt Skripte, Termine und Nachrichten aus Stud.IP und QIS aufs iPad: Apple Pencil, KI-Hilfe fürs ganze "
     "Dokument, Wochentests und Karteikarten. Ohne Tracking."),
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
# Titel, die nicht aus der ersten Ueberschrift kommen (die Startseite beginnt mit HTML)
TITLES = {"index.html": "StudiNow – dein Studium an einem Ort"}
SLUGS = {out[:-5]: out for _, out, _, _ in PAGES if out != "index.html"}
AASA_PATH = ".well-known/apple-app-site-association"
NETLIFY_REDIRECTS = """https://studinow.ai/* https://studinow.app/:splat 301!
https://www.studinow.ai/* https://studinow.app/:splat 301!
https://www.studinow.app/* https://studinow.app/:splat 301!
/i/* /i/index.html 200
"""
NETLIFY_HEADERS = """/.well-known/apple-app-site-association
  Content-Type: application/json
"""
TEAM_XCCONFIG = ROOT / "apps" / "apple" / "Config" / "Team.xcconfig"
BUNDLE_ID = "de.uniflow.ai"
PLACEHOLDER = re.compile(r"\[\[([^\]]+)\]\]")
SITE_LINK = re.compile(r'href="https://' + re.escape(DOMAIN) + r'(?:/([a-z-]+))?/?"')

CSS = """\
/* StudiNow – Website. Farben wie die App (app/static/style.css, UFTheme.swift); dunkel nach Systemeinstellung.
   Startseite wie eine Lernplattform (05.11.2026): Einstieg auf Karopapier mit iPad-Rahmen, Vertrauensleiste, Funktionen
   mit Bildschirmfotos, Schritte, Tarife, Fragen (details/summary, ohne Skript), Fusszeile mit allen Seiten. */
:root {
  color-scheme: light dark;
  --bg: #f6f7fb; --surface: #ffffff; --surface-2: #f1f3f9; --line: #e5e8f0; --line-strong: #d3d8e4;
  --text: #171a26; --text-2: #4b5168; --muted: #5f667d;
  --accent: #4f5bd5; --accent-strong: #3f4bc2; --accent-soft: #eceefc; --accent-text: #3a45b4;
  --ok: #1f9d5b; --warn: #8a4d03; --warn-soft: #fdf0dc; --on-fill: #ffffff;
  --hero: #eceefb; --grid: rgba(79, 91, 213, .11); --ink: #2a3a9c;
  --bezel: #1d2030; --shadow: 0 34px 60px -28px rgba(37, 45, 120, .45);
  --band: #3f4bc2; --band-text: #ffffff; --band-btn: #ffffff; --band-btn-text: #2f3aa6;
  --store: #171a26; --store-text: #ffffff;
  --r: 14px; --r-lg: 22px;
  --font: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  --display: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  --mono: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0f1117; --surface: #171a23; --surface-2: #1f2330; --line: #262b3a; --line-strong: #333a4d;
    --text: #e8eaf2; --text-2: #b3b9cc; --muted: #959cb2;
    --accent: #7b86f0; --accent-strong: #6a76e8; --accent-soft: #232848; --accent-text: #a9b1ff;
    --ok: #3fbf7c; --warn: #e9a04a; --warn-soft: #3a2a14; --on-fill: #0f1117;
    --hero: #131729; --grid: rgba(123, 134, 240, .09); --ink: #a9b1ff;
    --bezel: #2a2f40; --shadow: 0 34px 60px -28px rgba(0, 0, 0, .8);
    --band: #262c6b; --band-text: #ffffff; --band-btn: #e8eaf2; --band-btn-text: #262c6b;
    --store: #e8eaf2; --store-text: #0f1117;
  }
}
* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; scroll-padding-top: 5rem; }
@media (prefers-reduced-motion: no-preference) { html { scroll-behavior: smooth; } }
body { margin: 0; font: 17px/1.6 var(--font); color: var(--text); background: var(--bg); min-height: 100vh; }
a { color: var(--accent-text); text-decoration: underline; text-decoration-thickness: 1px; text-underline-offset: .18em; }
a:hover { text-decoration-thickness: 2px; }
:focus-visible { outline: 3px solid var(--accent); outline-offset: 3px; border-radius: 6px; }
h1, h2, h3 { font-family: var(--display); line-height: 1.2; letter-spacing: -.015em; font-weight: 700; color: var(--text); }
h1 { font-size: 2.1rem; margin: 0 0 1rem; letter-spacing: -.025em; }
h2 { font-size: 1.35rem; margin: 2.2rem 0 .6rem; }
h3 { font-size: 1.08rem; margin: 1.5rem 0 .4rem; }
p, li { color: var(--text); }
ul, ol { padding-left: 1.4rem; }
li { margin: .25rem 0; }
img { max-width: 100%; height: auto; }
code { font-family: var(--mono); font-size: .88em; background: var(--surface-2); padding: .05rem .35rem; border-radius: 4px; overflow-wrap: anywhere; }
table { border-collapse: collapse; width: 100%; font-size: .92rem; margin: 1rem 0; display: block; overflow-x: auto; }
th, td { border: 1px solid var(--line); padding: .5rem .65rem; text-align: left; vertical-align: top; }
th { background: var(--surface-2); }
hr { border: 0; border-top: 1px solid var(--line); margin: 2rem 0; }
mark.todo { background: var(--warn-soft); color: var(--warn); padding: 0 .25rem; border-radius: 3px; }
.ico { width: 1.25em; height: 1.25em; flex: none; fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; }
.wrap { width: min(1160px, 100% - 32px); margin-inline: auto; }
.skip { position: absolute; left: -9999px; top: .5rem; z-index: 20; padding: .6rem 1rem; background: var(--surface); color: var(--text); border-radius: 8px; }
.skip:focus { left: 16px; }

/* Kopf */
.header { background: var(--surface); border-bottom: 1px solid var(--line); position: sticky; top: 0; z-index: 10; }
.header-inner { display: flex; align-items: center; gap: .5rem 1.6rem; min-height: 64px; }
.brand { display: inline-flex; align-items: center; gap: .6rem; color: var(--text); font-family: var(--display); font-weight: 800; font-size: 1.12rem; letter-spacing: -.01em; text-decoration: none; }
.brand img { width: 32px; height: 32px; border-radius: 9px; display: block; }
.nav { display: flex; gap: .2rem; margin-left: auto; }
.nav a { padding: .45rem .75rem; border-radius: 8px; color: var(--text-2); font-weight: 550; font-size: .95rem; text-decoration: none; }
.nav a:hover { background: var(--surface-2); color: var(--text); }
.nav a[aria-current="page"] { background: var(--accent-soft); color: var(--accent-text); }

/* Knoepfe */
.btn { display: inline-flex; align-items: center; justify-content: center; gap: .55rem; padding: .85rem 1.35rem; border-radius: 12px; border: 2px solid transparent;
  font-weight: 700; font-size: 1rem; line-height: 1.2; text-decoration: none; }
.btn:hover { text-decoration: none; }
.btn-store { background: var(--store); color: var(--store-text); }
.btn-store:hover { box-shadow: 0 0 0 4px var(--accent-soft), 0 0 0 5px var(--accent); }
.btn-ghost { background: var(--surface); color: var(--text); border-color: var(--line-strong); }
.btn-ghost:hover { border-color: var(--accent); color: var(--accent-text); }
.btn-small { padding: .5rem .95rem; font-size: .92rem; border-radius: 10px; background: var(--accent); color: var(--on-fill); }
.btn-small:hover { background: var(--accent-strong); }
.btn-invert { background: var(--band-btn); color: var(--band-btn-text); }
.btn-invert:hover { background: var(--band-btn); color: var(--band-btn-text); box-shadow: 0 0 0 3px rgba(255, 255, 255, .35); }
.cta { display: flex; flex-wrap: wrap; align-items: center; gap: .75rem; margin: 2rem 0 1rem; }
.note { color: var(--muted); font-size: .92rem; margin: 0; }
.note strong { color: var(--text-2); }
.fine { color: var(--muted); font-size: .88rem; max-width: 46rem; }

/* Startseite */
main.home h2 { font-size: clamp(1.75rem, 1.2rem + 2vw, 2.6rem); line-height: 1.1; letter-spacing: -.028em; font-weight: 800; margin: 0 0 .9rem; }
main.home h3 { margin: .9rem 0 .35rem; font-size: 1.1rem; }
.hero { background-color: var(--hero);
  background-image: linear-gradient(var(--grid) 1px, transparent 1px), linear-gradient(90deg, var(--grid) 1px, transparent 1px);
  background-size: 22px 22px; background-position: -1px -1px; border-bottom: 1px solid var(--line); }
.hero-grid { display: grid; grid-template-columns: minmax(0, 5fr) minmax(0, 7fr); gap: 3.5rem; align-items: center; padding: 5rem 0 4.5rem; }
.hero h1 { font-size: clamp(2.6rem, 1.2rem + 4.4vw, 4.4rem); line-height: 1.02; letter-spacing: -.045em; font-weight: 850; margin: 0 0 1.4rem; max-width: 9.5em; }
.lead { font-size: 1.2rem; line-height: 1.55; color: var(--text-2); max-width: 32rem; margin: 0; }
.hero-shot { margin: 0; }
.device { background: var(--bezel); border-radius: 28px; padding: 11px; box-shadow: var(--shadow); }
.device img { display: block; width: 100%; height: auto; border-radius: 18px; }
.hero-shot figcaption { display: flex; align-items: flex-end; gap: .4rem; margin: .9rem 0 0 1.2rem; color: var(--ink); font-size: .95rem; font-weight: 600; }
.scribble { width: 54px; height: 34px; flex: none; fill: none; stroke: var(--ink); stroke-width: 2.4; stroke-linecap: round; stroke-linejoin: round; transform: translateY(-.35rem) scaleY(-1); }

.trust { background: var(--surface); border-bottom: 1px solid var(--line); }
.trust-list { list-style: none; padding: 1.6rem 0; margin-block: 0; display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 1.25rem 2rem; }
.trust-list li { display: flex; gap: .8rem; align-items: flex-start; margin: 0; font-size: .93rem; line-height: 1.5; color: var(--text-2); }
.trust-list li strong { display: block; color: var(--text); }
.trust-list .ico { width: 2.4rem; height: 2.4rem; padding: .5rem; border-radius: 50%; background: var(--accent-soft); color: var(--accent-text); }

.section { padding: 5.5rem 0; }
.tint { background: var(--surface); border-block: 1px solid var(--line); }
.section-head { max-width: 42rem; margin-bottom: 2.75rem; }
.section-head p { color: var(--text-2); font-size: 1.1rem; margin: 0; }
.systems { list-style: none; padding: 0; margin: 1.4rem 0 0; display: flex; flex-wrap: wrap; gap: .5rem; }
.systems li { margin: 0; padding: .35rem .9rem; border: 1.5px solid var(--line-strong); border-radius: 999px; font-weight: 700; font-size: .92rem; background: var(--surface); }
.tiles { list-style: none; padding: 0; margin: 0; display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 2.6rem 2.2rem; }
.tiles li { margin: 0; padding-top: 1.2rem; border-top: 2px solid var(--line-strong); }
.tiles .ico { width: 1.6rem; height: 1.6rem; color: var(--accent-text); }
.tiles p { color: var(--text-2); margin: 0; font-size: .97rem; }

.feature-grid { display: grid; grid-template-columns: minmax(0, 5fr) minmax(0, 7fr); gap: 4rem; align-items: center; }
.feature.alt .feature-text { order: 2; }
.feature-text > p { color: var(--text-2); font-size: 1.08rem; }
.feature .shot { margin: 0; }
.checks { list-style: none; padding: 0; margin: 1.3rem 0; }
.checks li { position: relative; padding-left: 1.9rem; margin: .55rem 0; }
.checks li::before { content: ""; position: absolute; left: .35rem; top: .3em; width: .42rem; height: .78rem; border: solid var(--ok); border-width: 0 2.5px 2.5px 0; transform: rotate(45deg); }

.steps { list-style: none; padding: 0; margin: 0; display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 2.5rem; counter-reset: step; }
.steps li { margin: 0; position: relative; padding-top: 4.4rem; counter-increment: step; }
.steps li::before { content: counter(step); position: absolute; top: 0; left: 0; width: 3.1rem; height: 3.1rem; border-radius: 50%; display: grid; place-items: center;
  background: var(--accent); color: var(--on-fill); font-family: var(--display); font-weight: 800; font-size: 1.3rem; }
.steps li::after { content: ""; position: absolute; top: 1.55rem; left: 4rem; right: -1.5rem; border-top: 2px dashed var(--line-strong); }
.steps li:last-child::after { display: none; }
.steps h3 { margin-top: 0; }
.steps p { color: var(--text-2); margin: 0; }

.plans { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 1.5rem; align-items: start; margin-bottom: 1.5rem; }
.plan { background: var(--bg); border: 1px solid var(--line-strong); border-radius: var(--r-lg); padding: 1.8rem 1.7rem 1.4rem; }
.plan-top { border: 2px solid var(--accent); box-shadow: 0 24px 48px -30px var(--accent); }
.plan h3 { margin: 0; font-size: 1.15rem; }
.price { margin: .8rem 0 .2rem; color: var(--muted); }
.amount { font-family: var(--display); font-size: 2.6rem; font-weight: 850; letter-spacing: -.03em; color: var(--text); line-height: 1; }
.tagline { color: var(--text-2); font-size: .95rem; min-height: 3em; margin: .6rem 0 0; }
.plan .checks { border-top: 1px solid var(--line); padding-top: 1rem; font-size: .97rem; }

.faq-grid { display: grid; grid-template-columns: minmax(0, 4fr) minmax(0, 7fr); gap: 3rem; align-items: start; }
.faq-list details { border-bottom: 1px solid var(--line-strong); }
.faq-list details:first-child { border-top: 1px solid var(--line-strong); }
.faq-list summary { cursor: pointer; list-style: none; position: relative; padding: 1.15rem 2.6rem 1.15rem 0; font-weight: 700; font-size: 1.06rem; }
.faq-list summary::-webkit-details-marker { display: none; }
.faq-list summary::after { content: "+"; position: absolute; right: .4rem; top: .85rem; font-size: 1.5rem; font-weight: 400; color: var(--accent-text); }
.faq-list details[open] summary::after { content: "\\2013"; }
.faq-list details p { margin: 0 0 1.25rem; color: var(--text-2); max-width: 40rem; }

.closing { background: var(--band); color: var(--band-text); }
.closing-inner { padding: 4.5rem 0; text-align: center; }
main.home .closing h2 { color: var(--band-text); margin: 0 auto; max-width: 18em; }
.closing .cta { justify-content: center; }
.closing .note { color: var(--band-text); opacity: .9; }

/* Textseiten (Rechtliches, Support, Einladung) */
main.doc { padding: 3rem 0 4.5rem; }
.prose { width: min(52rem, 100% - 32px); margin-inline: auto; background: var(--surface); border: 1px solid var(--line); border-radius: var(--r-lg);
  padding: 2.6rem clamp(1.2rem, 5vw, 3.2rem) 2.4rem; overflow-wrap: break-word; }
.prose > h1:first-child { margin-top: 0; font-size: clamp(1.9rem, 1.4rem + 1.8vw, 2.6rem); font-weight: 800; letter-spacing: -.03em; }
.prose h2 { padding-top: .2rem; }

/* Fuss */
.footer { background: var(--surface); border-top: 1px solid var(--line); color: var(--muted); font-size: .93rem; }
.footer-grid { display: grid; grid-template-columns: minmax(0, 2fr) repeat(3, minmax(0, 1fr)); gap: 2rem; padding: 3.2rem 0 2rem; }
.footer-about p { color: var(--muted); max-width: 22rem; margin: .8rem 0 0; }
.footer-col p { margin: 0 0 .7rem; color: var(--text); font-weight: 700; }
.footer-col ul { list-style: none; padding: 0; margin: 0; }
.footer-col li { margin: .45rem 0; }
.footer a { color: var(--text-2); text-decoration: none; }
.footer a:hover { color: var(--accent-text); text-decoration: underline; }
.footer a[aria-current="page"] { color: var(--accent-text); font-weight: 650; }
.footer .brand { color: var(--text); }
.footer .brand:hover { color: var(--text); text-decoration: none; }
.footer-bottom { border-top: 1px solid var(--line); padding: 1.2rem 0 2rem; display: flex; flex-wrap: wrap; gap: .4rem 1.5rem; justify-content: space-between; }

@media (max-width: 960px) {
  .hero-grid, .feature-grid, .faq-grid { grid-template-columns: minmax(0, 1fr); gap: 2.5rem; }
  .hero-grid { padding: 3.5rem 0 3rem; }
  .feature.alt .feature-text { order: 0; }
  .trust-list, .tiles { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .plans { grid-template-columns: minmax(0, 1fr); max-width: 30rem; }
  .footer-grid { grid-template-columns: repeat(3, minmax(0, 1fr)); }
  .footer-about { grid-column: 1 / -1; }
}
@media (max-width: 720px) {
  .header { position: static; }
  .header-inner { flex-wrap: wrap; padding: .6rem 0; }
  .header .btn-small { margin-left: auto; }
  .nav { order: 3; width: 100%; margin: 0 -.75rem; overflow-x: auto; }
  .steps { grid-template-columns: minmax(0, 1fr); gap: 2rem; }
  .steps li { padding: .3rem 0 0 4.2rem; min-height: 3.1rem; }
  .steps li::after { display: none; }
}
@media (max-width: 600px) {
  body { font-size: 16px; }
  h1 { font-size: 1.7rem; }
  .section { padding: 3.75rem 0; }
  .lead { font-size: 1.08rem; }
  .trust-list, .tiles { grid-template-columns: minmax(0, 1fr); }
  .tiles { gap: 1.6rem; }
  .tiles li { display: grid; grid-template-columns: 1.6rem minmax(0, 1fr); gap: 0 .8rem; padding-top: 1rem; }
  .tiles li > * { grid-column: 2; }
  .tiles li > .ico { grid-column: 1; grid-row: 1 / span 2; margin-top: .1rem; }
  main.home .tiles h3 { margin-top: 0; }
  .device { border-radius: 16px; padding: 6px; }
  .device img { border-radius: 11px; }
  .hero-shot figcaption { margin-left: .2rem; font-size: .88rem; }
  .cta .btn { flex: 1 1 100%; }
  .footer-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  main.doc { padding: 1.25rem 0 3rem; }
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
<meta name="color-scheme" content="light dark">
<link rel="icon" href="{root}icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="{root}style.css">
</head>
<body>
<a class="skip" href="#inhalt">Zum Inhalt springen</a>
<header class="header"><div class="wrap header-inner">
<a class="brand" href="{root}index.html"><img src="{root}icon.svg" alt="" width="32" height="32">StudiNow</a>
<nav class="nav" aria-label="Hauptnavigation">{nav}</nav>
<a class="btn btn-small" href="{root}index.html#laden">App laden</a>
</div></header>
<main id="inhalt" class="{main_class}">
{body}
</main>
<footer class="footer">
<div class="wrap footer-grid">
<div class="footer-about">
<a class="brand" href="{root}index.html"><img src="{root}icon.svg" alt="" width="32" height="32">StudiNow</a>
<p>Die Lern-App für Studierende: Unterlagen, Termine und Lernen an einem Ort. Ein unabhängiges Angebot, nicht mit den Hochschulen verbunden.</p>
</div>
{footer_cols}
</div>
<div class="wrap footer-bottom"><span>© {year} {owner}</span><span>Kein Tracking, keine Werbung</span></div>
</footer>
</body>
</html>
"""

# Kopfnavigation (Name, Ziel relativ zur Wurzel); Seiten in der Fusszeile: Spalte -> [(Name, Ziel)]
HEADER_NAV = [("Funktionen", "index.html#funktionen"), ("Preise", "index.html#preise"), ("Fragen", "index.html#fragen"),
              ("Support", "support.html")]
FOOTER_COLS = [
    ("Produkt", [("Startseite", "index.html"), ("Funktionen", "index.html#funktionen"), ("So geht’s", "index.html#so-gehts"),
                 ("Preise", "index.html#preise")]),
    ("Hilfe", [("Support", "support.html"), ("Häufige Fragen", "index.html#fragen"), ("Konto löschen", "konto-loeschen.html"),
               ("support@studinow.app", "mailto:support@studinow.app")]),
    ("Rechtliches", [("Impressum", "impressum.html"), ("Datenschutz", "datenschutz.html"),
                     ("Nutzungsbedingungen", "nutzungsbedingungen.html")]),
]

# Symbole fuer :i-name: in den Markdown-Quellen (eingebettetes SVG, Strich in currentColor, ohne fremde Ressourcen)
ICONS = {
    "download": '<path d="M12 3v12M7 10l5 5 5-5M5 21h14"/>',
    "lock": '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
    "tablet": '<rect x="4" y="2" width="16" height="20" rx="2.5"/><path d="M11 18h2"/>',
    "eye-off": '<path d="M3 3l18 18M10.6 6.1A10 10 0 0 1 12 6c5 0 9 6 9 6a17 17 0 0 1-2.6 3.2M6.6 6.6C4.3 8.1 3 12 3 12s4 6 9 6a9.6 9.6 0 0 0 5.4-1.6M9.9 9.9a3 3 0 0 0 4.2 4.2"/>',
    "cap": '<path d="M2 9l10-5 10 5-10 5z"/><path d="M6 11v5c0 1.5 2.7 3 6 3s6-1.5 6-3v-5M22 9v6"/>',
    "folder": '<path d="M3 6a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
    "mail": '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3 7l9 6 9-6"/>',
    "upload": '<path d="M12 16V4M7 9l5-5 5 5M5 20h14"/>',
    "calendar": '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4M8 14h2M14 14h2M8 17h2"/>',
    "route": '<circle cx="6" cy="19" r="2"/><circle cx="18" cy="5" r="2"/><path d="M8 19h8a3 3 0 0 0 0-6H8a3 3 0 0 1 0-6h8"/>',
    "clock": '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
}
ICON_TOKEN = re.compile(r":i-([a-z-]+):")
COMMENT = re.compile(r"<!--.*?-->\s*", re.S)


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


def icon(name: str) -> str:
    return f'<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false">{ICONS[name]}</svg>'


def render_markdown(text: str, root: str = "") -> str:
    text = COMMENT.sub("", text)
    text = ICON_TOKEN.sub(lambda m: icon(m.group(1)), text)
    body = markdown.markdown(text, extensions=["tables", "sane_lists"], output_format="html")
    body = PLACEHOLDER.sub(lambda m: f'<mark class="todo" title="noch auszufüllen">[[{m.group(1)}]]</mark>', body)
    body = re.sub(r'(src|srcset)="img/', lambda m: f'{m.group(1)}="{root}img/', body)
    return SITE_LINK.sub(lambda m: _relative_link(m, root), body)


def _relative_link(m: re.Match, root: str = "") -> str:
    """Links auf die eigenen Seiten relativ, damit sie auch ohne Host-Regeln funktionieren; andere bleiben.
    `root` ("../") fuer Seiten in einem Unterordner."""
    slug = m.group(1) or ""
    if not slug:
        return f'href="{root}index.html"'
    return f'href="{root}{SLUGS[slug]}"' if slug in SLUGS else m.group(0)


def _link(name: str, target: str, out_name: str, root: str) -> str:
    href = target if target.startswith("mailto:") else root + target
    current = ' aria-current="page"' if target == out_name else ""
    return f'<a href="{html.escape(href)}"{current}>{html.escape(name)}</a>'


def render_page(src_name: str, out_name: str, nav_name: str, description: str, owner: str, year: str) -> str:
    text = (SRC / src_name).read_text(encoding="utf-8")
    title = TITLES.get(out_name) or title_of(text, nav_name)
    full_title = title if title.startswith("StudiNow") else f"{title} – StudiNow"
    root = "../" * out_name.count("/")
    nav = "".join(_link(n, t, out_name, root) for n, t in HEADER_NAV)
    cols = "\n".join(f'<nav class="footer-col" aria-label="{c}"><p>{c}</p><ul>'
                     + "".join(f"<li>{_link(n, t, out_name, root)}</li>" for n, t in links) + "</ul></nav>"
                     for c, links in FOOTER_COLS)
    body = render_markdown(text, root)
    if out_name == "index.html":
        main_class = "home"
    else:
        main_class = "doc invite" if out_name == "i/index.html" else "doc"
        body = f'<article class="prose">\n{body}\n</article>'
    return TEMPLATE.format(title=html.escape(full_title), description=html.escape(description), nav=nav, root=root,
                           main_class=main_class, body=body, footer_cols=cols, owner=html.escape(owner), year=year)


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
    for img in sorted(IMG_SRC.glob("*.jpg")):
        files[f"img/{img.name}"] = img.read_bytes()
    files[AASA_PATH] = apple_app_site_association()
    # Netlify (05.11.2026): Einladungslinks /i/<CODE> zeigen die Einladungsseite, studinow.ai leitet dauerhaft auf
    # studinow.app um, die Apple-Datei geht als JSON raus (Universal Links)
    files["_redirects"] = NETLIFY_REDIRECTS
    files["_headers"] = NETLIFY_HEADERS
    return files


def write(out: Path) -> list[str]:
    out.mkdir(parents=True, exist_ok=True)
    files = build()
    for old in (out / "img").glob("*"):                           # Bilder, die es in website-img nicht mehr gibt
        if f"img/{old.name}" not in files:
            old.unlink()
    names = []
    for name, content in files.items():
        p = out / name
        p.parent.mkdir(parents=True, exist_ok=True)                  # i/, img/, .well-known/
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
