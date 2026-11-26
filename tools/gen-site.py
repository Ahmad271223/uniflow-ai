#!/usr/bin/env python3
"""Oeffentliche Website studinow.app als statische Seiten (site/) aus den Markdown-Dateien in docs/release bauen.

Die Markdown-Dateien sind die einzige Quelle (dieselben, die der Dienst unter /datenschutz usw. ausliefert, app/legal.py):
    STARTSEITE.md -> index.html            SUPPORT.md -> support.html
    DATENSCHUTZ.md -> datenschutz.html     NUTZUNGSBEDINGUNGEN.md -> nutzungsbedingungen.html
    IMPRESSUM.md -> impressum.html         KONTO-LOESCHEN.md -> konto-loeschen.html
    EINLADUNG.md -> i/index.html           (Einladungsseite hinter https://studinow.app/i/<CODE>, nicht in der Navigation)
dazu .well-known/apple-app-site-association und dieselbe Datei an der Wurzel (Universal Links /i/* fuer die iPad-App; Team-ID aus apps/apple/Config/Team.xcconfig,
sonst Platzhalter [[TEAMID]]), style.css (eine Datei, Farben der App aus app/static/style.css bzw. UFTheme.swift, dunkel nach Systemeinstellung
ohne Skript), icon.svg (Kopie von app/static/icon.svg) und vorschau.jpg (Bild fuer geteilte Links, docs/release/website-vorschau/), dazu _redirects und _headers fuer Netlify und img/ (Bildschirmfotos
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
LOGO_SRC = SRC / "website-logo"    # Logo ab 06.11.2026 (logo.png, apple-touch-icon.png, favicon.png), aus dem App-Icon;
                                   # seit 26.11.2026 favicon.png 96 px (vorher 64) und favicon.ico (16/32/48), beide aus logo.png
PREVIEW = SRC / "website-vorschau" / "vorschau.jpg"   # Vorschaubild fuer geteilte Links (og:image), 1200 x 630, seit 24.11.2026
IMG_SRC = SRC / "website-img"       # Bildschirmfotos der Startseite (Demo-Inhalte, JPEG <= 1400 px), kopiert nach site/img/
DEFAULT_OUT = ROOT / "site"
DOMAIN = "studinow.app"

# (Markdown, Ausgabe, Name in der Navigation, Beschreibung fuer <meta name="description">)
PAGES = [
    ("STARTSEITE.md", "index.html", "Start",
     "StudiNow ist ein Lernmanagementsystem für Hochschulen in ganz Deutschland – zum Start mit voller Anbindung an die "
     "Leibniz Universität Hannover und die Universität Hildesheim. Skripte, Termine und Nachrichten aufs iPad und iPhone: Apple Pencil, KI-Hilfe, Wochentests, "
     "Karteikarten und Mensa. Ohne Tracking."),
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
# Kopie an der Wurzel (05.11.2026): beim Hochladen per Drag-and-drop aus dem Finder fehlt der versteckte Ordner
# .well-known (404 auf Netlify); die Umschreibung in _redirects liefert dann die Kopie unter derselben Adresse aus
AASA_ROOT = "apple-app-site-association"
NETLIFY_REDIRECTS = """https://studinow.ai/* https://studinow.app/:splat 301!
https://www.studinow.ai/* https://studinow.app/:splat 301!
https://www.studinow.app/* https://studinow.app/:splat 301!
/.well-known/apple-app-site-association /apple-app-site-association 200
/i/* /i/index.html 200
"""
NETLIFY_HEADERS = """/.well-known/apple-app-site-association
  Content-Type: application/json
/apple-app-site-association
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
.eyebrow { display: inline-block; margin: 0 0 1rem; padding: .3rem .85rem; border-radius: 999px; background: var(--surface); border: 1.5px solid var(--line-strong);
  color: var(--accent-text); font-weight: 700; font-size: .92rem; letter-spacing: .01em; }
.unis { display: flex; gap: .6rem; align-items: flex-start; margin: 1.3rem 0 0; max-width: 32rem; color: var(--text-2); font-size: .97rem; line-height: 1.5; }
.unis .ico { width: 1.5rem; height: 1.5rem; margin-top: .05rem; color: var(--accent-text); }
.unis strong { color: var(--text); }
.unis + .unis { margin-top: .75rem; }
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
.systems li.soon { border-style: dashed; font-weight: 500; color: var(--muted); }
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

.feature + .steps-band { border-top: 1px solid var(--line); }
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

/* Spielerische Effekte (24.11.2026, Wunsch des Inhabers: "bisschen spielerischer", Vorbild Lernplattformen). Alles ohne
   Skript: Zettel am iPad, Laufband, Karteikarte zum Umdrehen und Testfrage (details/summary), Kleinigkeiten beim
   Draufzeigen. Bewegung nur, wenn das System sie nicht abgeschaltet hat (prefers-reduced-motion); Effekte beim Scrollen
   nur, wo der Browser animation-timeline kennt, sonst steht alles einfach da. */
:root { --marker: #ffd84a; --no: #c2413b; --news: #fff3c4; --pop: cubic-bezier(.34, 1.56, .64, 1); }
@media (prefers-color-scheme: dark) { :root { --marker: #d6ae2b; --no: #f0827c; --news: #2b2710; } }

/* Hinweis ganz oben (24.11.2026): eine Zeile, der ganze Text klappt beim Antippen auf (details/summary). Ohne Skript kann
   sich die Seite nicht merken, ob jemand schon da war; darum ein schmaler Streifen statt eines Fensters beim ersten Besuch. */
.news { background: var(--news); border-bottom: 1px solid var(--line); font-size: .97rem; }
.news summary { list-style: none; cursor: pointer; }
.news summary::-webkit-details-marker { display: none; }
.news-head { display: flex; flex-wrap: wrap; align-items: baseline; gap: .25rem .7rem; padding: .7rem 0; color: var(--text); font-weight: 600; }
.news-tag { padding: .08rem .6rem; border-radius: 999px; background: var(--text); color: var(--surface); font-size: .8rem; font-weight: 700; }
.news-more { margin-left: auto; font-weight: 700; color: var(--accent-text); text-decoration: underline; text-underline-offset: .18em; white-space: nowrap; }
.news .news-close, .news[open] .news-open { display: none; }
.news[open] .news-close { display: inline; }
.news-body { padding: 0 0 1rem; }
.news-body p { margin: 0; max-width: 48rem; color: var(--text-2); }

.btn { transition: translate .18s var(--pop), scale .18s var(--pop), box-shadow .18s ease, background-color .18s ease, border-color .18s ease; }
.btn:hover { translate: 0 -2px; }
.btn:active { translate: 0 0; scale: .97; }
.btn .ico { transition: translate .25s var(--pop); }
.btn-store:hover .ico { translate: 0 3px; }
.brand img { transition: rotate .3s var(--pop), scale .3s var(--pop); }
.brand:hover img { rotate: -8deg; scale: 1.08; }
.trust-list .ico, .tiles .ico { transition: translate .3s var(--pop), rotate .3s var(--pop), scale .3s var(--pop); }
.trust-list li:hover .ico, .tiles li:hover .ico { translate: 0 -3px; rotate: -6deg; scale: 1.08; }
.tiles li { transition: border-color .2s ease; }
.tiles li:hover { border-top-color: var(--accent); }
.systems li { transition: translate .2s var(--pop), rotate .2s var(--pop); }
.systems li:not(.soon):hover { translate: 0 -2px; rotate: -2deg; }

/* Einstieg wie ein Schreibtisch (24.11.2026; der Inhaber zeigte eine Notiz-App als Anregung, "nicht 1 zu 1, mach was
   Eigenes"): eine handgeschriebene Zeile mit Textmarker, am iPad eine Karteikarte mit Bueroklammer, ein Mensa-Bon und die
   drei Knoepfe der KI-Hilfe aus der App, dazu Kritzeleien in Fuellerblau wie am Heftrand. Alles Demo und fuer
   Vorleseprogramme ausgeblendet. Handschrift nur aus Schriften, die auf dem Geraet schon da sind (keine von Dritten). */
:root { --hand: "Bradley Hand", "Noteworthy", "Segoe Print", "Ink Free", "Comic Sans MS", cursive; --marker-soft: rgba(255, 216, 74, .78); --paper: #fffdf6; --paper-ink: #1d2030; }
@media (prefers-color-scheme: dark) { :root { --marker-soft: rgba(214, 174, 43, .38); --paper: #f3f0e6; } }
.hero { overflow-x: clip; }
.hero-grid { position: relative; }
.hand-line { margin: -.25rem 0 1.4rem; font-family: var(--hand); font-weight: 700; font-size: clamp(1.5rem, 1rem + 1.7vw, 2.15rem); line-height: 1.2; color: var(--ink); rotate: -1.5deg; transform-origin: 0 50%; }
.hand-line span { padding: 0 .45rem; margin: 0 -.45rem; border-radius: 4px; background: linear-gradient(var(--marker-soft), var(--marker-soft)) 0 55% / 100% 72% no-repeat; }
.hero-shot { position: relative; }
.hero-shot .device { position: relative; }
.hero-shot figcaption { margin-top: 2.2rem; }
.desk { position: absolute; inset: 0; z-index: 2; pointer-events: none; }
.desk p { margin: 0; }
.desk p, .desk span, .desk strong, .desk b { color: var(--paper-ink); }
/* Karteikarte: liniert mit roter Kopflinie, eine zweite dahinter, Bueroklammer oben */
.idx { position: absolute; left: -7%; top: -12%; width: 11.2rem; min-height: 7.3rem; padding: 1.72rem 1rem .7rem; border-radius: 7px; rotate: -5deg; --d: .5s;
  font-family: var(--hand); font-weight: 700; font-size: 1.4rem; line-height: 1.5rem;
  background: linear-gradient(#e2574c, #e2574c) 0 1.56rem / 100% 2px no-repeat, repeating-linear-gradient(transparent 0 1.42rem, #b9c6ee 1.42rem 1.5rem) 0 1.66rem, var(--paper);
  box-shadow: 6px 6px 0 -1px var(--paper), 6px 6px 0 0 #cfd5ea, 0 22px 24px -14px rgba(20, 24, 60, .6), 0 0 0 1px #cfd5ea; }
.idx span { display: block; white-space: nowrap; }
.idx sub { font-size: .6em; }
.idx::before, .idx::after { content: ""; position: absolute; border: 2.5px solid #7d86ad; border-radius: 999px; rotate: 9deg; }
.idx::before { right: 1.3rem; top: -.9rem; width: .9rem; height: 2.5rem; }
.idx::after { right: 1.52rem; top: -.5rem; width: .46rem; height: 1.7rem; border-top-color: transparent; }
/* Mensa-Bon mit Zackenkante unten (der Schatten sitzt aussen, die Kante schneidet innen) */
.bon { position: absolute; right: -5%; bottom: 13%; width: 9rem; rotate: 4deg; --d: .8s; filter: drop-shadow(0 12px 9px rgba(20, 24, 60, .34)); }
.bon p { padding: .75rem .8rem 1.25rem; background: var(--paper); font-family: var(--mono); font-size: .78rem; line-height: 1.5;
  -webkit-mask: conic-gradient(from -45deg at bottom, #0000, #000 1deg 89deg, #0000 90deg) 50% / .7rem 100%;
  mask: conic-gradient(from -45deg at bottom, #0000, #000 1deg 89deg, #0000 90deg) 50% / .7rem 100%; }
.bon strong { display: block; margin-bottom: .35rem; padding-bottom: .3rem; border-bottom: 1.5px dashed var(--paper-ink); font-size: .84rem; }
.bon span { display: flex; justify-content: space-between; gap: .5rem; white-space: nowrap; }
/* Die drei Knoepfe der KI-Hilfe, Farben wie in der App */
.acts { position: absolute; left: 50%; bottom: -1.6rem; transform: translateX(-50%); display: flex; gap: .4rem; padding: .45rem; border-radius: 16px; --d: 1.1s;
  background: var(--surface); border: 1.5px solid var(--line-strong); box-shadow: 0 16px 26px -14px rgba(20, 24, 60, .55); white-space: nowrap; }
.desk .act { display: flex; align-items: center; gap: .35rem; padding: .32rem .7rem; border-radius: 10px; border: 1.5px solid var(--c); font-size: .85rem; font-weight: 700;
  color: var(--text); background: color-mix(in srgb, var(--c) 11%, var(--surface)); }
.act .ico { width: 1.05rem; height: 1.05rem; color: var(--c); }
.act-1 { --c: var(--ok); } .act-2 { --c: #d9822b; } .act-3 { --c: var(--accent); }
/* Kritzeleien wie mit dem Fueller am Heftrand */
.doodle { position: absolute; z-index: 1; fill: none; stroke: var(--c, var(--ink)); stroke-width: 3; stroke-linecap: round; stroke-linejoin: round; pointer-events: none; }
.doodle-check { width: 2.5rem; height: 2.5rem; left: 100%; top: .1rem; margin-left: .5rem; rotate: 5deg; }
.doodle-sum { width: 3.2rem; height: 3.6rem; right: -.6rem; top: 1.3rem; rotate: 6deg; }
.doodle-curl { --c: #8b5cf6; width: 3.6rem; height: 2.4rem; left: 37%; bottom: 2rem; rotate: -8deg; }

/* Laufband unter dem Einstieg: was alles drin ist (zweite Haelfte ist die Wiederholung fuer die Endlosschleife) */
.ticker { overflow: hidden; background: var(--band); padding: .85rem 0; }
.ticker-track { list-style: none; margin: 0; padding: 0; display: flex; gap: 2.4rem; width: max-content; }
.ticker-track li { margin: 0; display: flex; align-items: center; gap: .55rem; font-weight: 700; font-size: 1rem; color: var(--band-text); white-space: nowrap; }
.ticker-track .ico { width: 1.3rem; height: 1.3rem; opacity: .85; }

/* Bildschirmfotos liegen leicht schraeg wie Blaetter auf dem Tisch und richten sich beim Draufzeigen auf */
.feature { overflow-x: clip; }
.feature .device { rotate: 1.2deg; transition: rotate .45s var(--pop), translate .45s var(--pop), scale .45s var(--pop); }
.feature.alt .device { rotate: -1.2deg; }
.feature .device:hover { rotate: 0deg; translate: 0 -6px; scale: 1.015; }

/* Zum Ausprobieren: Karteikarte und Testfrage, beides details/summary */
.try { background-color: var(--hero);
  background-image: linear-gradient(var(--grid) 1px, transparent 1px), linear-gradient(90deg, var(--grid) 1px, transparent 1px);
  background-size: 22px 22px; background-position: -1px -1px; border-bottom: 1px solid var(--line); }
.try-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 2.2rem; align-items: start; max-width: 62rem; }
.try-label { margin: 0; font-size: .88rem; font-weight: 700; color: var(--accent-text); }
.flip { position: relative; min-height: 18rem; border-radius: var(--r-lg); background: var(--surface); border: 2px solid var(--line-strong);
  box-shadow: 0 9px 0 -4px var(--surface), 0 9px 0 -2px var(--line-strong), 0 18px 0 -8px var(--surface), 0 18px 0 -6px var(--line-strong); }
.flip summary { list-style: none; cursor: pointer; display: flex; flex-direction: column; justify-content: center; gap: .7rem; min-height: 18rem; padding: 2rem; border-radius: inherit; }
.flip summary::-webkit-details-marker { display: none; }
.flip-q { font-family: var(--display); font-size: clamp(1.5rem, 1.1rem + 1.6vw, 2.1rem); font-weight: 800; letter-spacing: -.025em; line-height: 1.12; }
.flip-hint { display: flex; align-items: center; gap: .4rem; font-size: .9rem; color: var(--muted); }
.flip-hint .ico { width: 1.1rem; height: 1.1rem; }
.flip[open] { background: var(--accent); border-color: var(--accent); }
.flip[open] summary { position: absolute; inset: 0; min-height: 0; }
.flip[open] summary > * { visibility: hidden; }
.flip-back { min-height: 18rem; padding: 2rem; display: flex; flex-direction: column; justify-content: center; gap: .5rem; }
.flip-back p { margin: 0; color: var(--on-fill); }
.flip-back .try-label { opacity: .85; }
.flip-back .flip-a { font-family: var(--display); font-size: 3.6rem; font-weight: 850; letter-spacing: -.03em; line-height: 1; }
.quiz { background: var(--surface); border: 2px solid var(--line-strong); border-radius: var(--r-lg); padding: 1.8rem 1.8rem 1.6rem; min-height: 18rem; }
.quiz-q { font-family: var(--display); font-size: 1.4rem; font-weight: 800; letter-spacing: -.02em; line-height: 1.2; margin: .5rem 0 1.1rem; }
.opt { position: relative; margin-top: .6rem; border: 2px solid var(--line-strong); border-radius: 14px; background: var(--bg); transition: border-color .2s ease, background-color .2s ease; }
.opt summary { list-style: none; cursor: pointer; position: relative; padding: .8rem 1rem .8rem 3rem; border-radius: 12px; font-weight: 700; font-size: 1.05rem; }
.opt summary::-webkit-details-marker { display: none; }
.opt summary::before { content: ""; position: absolute; left: 1rem; top: 50%; width: 1.25rem; height: 1.25rem; margin-top: -.625rem; border-radius: 50%;
  border: 2px solid var(--line-strong); background: var(--surface); }
.opt:not([open]) summary:hover { background: var(--accent-soft); }
.opt p { margin: 0; padding: 0 1rem .9rem 3rem; font-size: .95rem; color: var(--text-2); }
.opt.yes[open] { border-color: var(--ok); background: color-mix(in srgb, var(--ok) 12%, var(--surface)); }
.opt.no[open] { border-color: var(--no); background: color-mix(in srgb, var(--no) 10%, var(--surface)); }
.opt.yes[open] summary::before { border-color: var(--ok); background: var(--ok); box-shadow: inset 0 0 0 3px var(--surface); }
.opt.no[open] summary::before { border-color: var(--no); background: var(--no); box-shadow: inset 0 0 0 3px var(--surface); }

.plan { transition: translate .3s var(--pop), rotate .3s var(--pop), box-shadow .3s ease; }
.plan:hover { translate: 0 -6px; rotate: -.5deg; }
.plan-top:hover { rotate: .5deg; }
.faq-list summary { transition: color .15s ease; }
.faq-list summary:hover { color: var(--accent-text); }
.faq-list summary::after { transition: rotate .3s var(--pop); }
.faq-list details[open] summary::after { rotate: 180deg; }

/* Abschluss mit Wellenkante */
.closing { --w: 20px; padding-top: calc(var(--w) * 1.4);
  -webkit-mask: radial-gradient(calc(var(--w) * 1.28) at 50% calc(1.8 * var(--w)), #000 99%, #0000 101%) calc(50% - 2 * var(--w)) 0 / calc(4 * var(--w)) 100%,
    radial-gradient(calc(var(--w) * 1.28) at 50% calc(-.8 * var(--w)), #0000 99%, #000 101%) 50% var(--w) / calc(4 * var(--w)) 100% repeat-x;
  mask: radial-gradient(calc(var(--w) * 1.28) at 50% calc(1.8 * var(--w)), #000 99%, #0000 101%) calc(50% - 2 * var(--w)) 0 / calc(4 * var(--w)) 100%,
    radial-gradient(calc(var(--w) * 1.28) at 50% calc(-.8 * var(--w)), #0000 99%, #000 101%) 50% var(--w) / calc(4 * var(--w)) 100% repeat-x; }

@keyframes schweben { 0%, 100% { translate: 0 0; } 50% { translate: 0 -10px; } }
@keyframes aufkleben { from { opacity: 0; scale: .4; } to { opacity: 1; scale: 1; } }
@keyframes wippen { 0%, 100% { translate: 0 0; } 50% { translate: 0 -7px; } }
@keyframes zeichnen { from { stroke-dashoffset: 130; } to { stroke-dashoffset: 0; } }
@keyframes zeichnen-lang { from { stroke-dashoffset: 220; } to { stroke-dashoffset: 0; } }
@keyframes anstreichen { from { background-size: 0% 72%; } to { background-size: 100% 72%; } }
@keyframes laufband { to { transform: translateX(calc(-50% - 1.2rem)); } }
@keyframes umdrehen { from { transform: perspective(900px) rotateY(-90deg); } to { transform: perspective(900px) rotateY(0deg); } }
@keyframes wackeln { 20%, 60% { translate: -6px 0; } 40%, 80% { translate: 6px 0; } }
@keyframes huepfen { 0% { scale: .96; } 60% { scale: 1.03; } 100% { scale: 1; } }
@keyframes konfetti { from { transform: scale(.2); opacity: 1; } to { transform: scale(1.7) rotate(30deg); opacity: 0; } }
@keyframes hinlegen { from { opacity: .15; transform: translate(60px, 40px) rotate(5deg) scale(.94); } to { opacity: 1; transform: none; } }
@keyframes hinlegen-links { from { opacity: .15; transform: translate(-60px, 40px) rotate(-5deg) scale(.94); } to { opacity: 1; transform: none; } }
@keyframes plopp { from { scale: .3; opacity: 0; } 70% { scale: 1.15; opacity: 1; } to { scale: 1; opacity: 1; } }
@keyframes hochkommen { from { opacity: .25; transform: translateY(40px); } to { opacity: 1; transform: none; } }
@keyframes fortschritt { from { transform: scaleX(0); } to { transform: scaleX(1); } }

@media (prefers-reduced-motion: no-preference) {
  .hero-shot .device { animation: schweben 7s ease-in-out infinite; }
  .idx, .bon, .acts { animation: aufkleben .6s var(--pop) var(--d, .5s) both, wippen 5.5s ease-in-out calc(var(--d, .5s) + .6s) infinite; }
  .hand-line span { animation: anstreichen .7s ease-out .5s both; }
  .doodle { stroke-dasharray: 220; animation: zeichnen-lang 1.1s ease-out var(--dd, 1.2s) both; }
  .doodle-check { --dd: 1.6s; } .doodle-curl { --dd: 1.9s; }
  .scribble { stroke-dasharray: 130; animation: zeichnen 1s ease-out 1.2s both; }
  .ticker-track { animation: laufband 48s linear infinite; }
  .ticker:hover .ticker-track { animation-play-state: paused; }
  .flip[open] { animation: umdrehen .55s var(--pop); }
  .opt.no[open] { animation: wackeln .4s ease; }
  .opt.yes[open] { animation: huepfen .5s var(--pop); }
  .opt.yes[open]::after { content: ""; position: absolute; right: 3.2rem; top: 1.5rem; width: 8px; height: 8px; border-radius: 2px; pointer-events: none;
    box-shadow: -28px -22px 0 var(--accent), 26px -26px 0 var(--marker), -8px -38px 0 var(--ok), 36px -2px 0 #8b5cf6, -38px 4px 0 var(--marker), 12px 30px 0 var(--accent), -20px 28px 0 var(--ok);
    animation: konfetti .9s ease-out both; }
  @supports (interpolate-size: allow-keywords) {
    .faq-list details, .opt { interpolate-size: allow-keywords; }
    .faq-list details::details-content, .opt::details-content { block-size: 0; overflow: clip; transition: block-size .3s ease, content-visibility .3s allow-discrete; }
    .faq-list details[open]::details-content, .opt[open]::details-content { block-size: auto; }
  }
  @supports (animation-timeline: view()) {
    .feature .shot { animation: hinlegen linear both; animation-timeline: view(); animation-range: entry 0% cover 38%; }
    .feature.alt .shot { animation-name: hinlegen-links; }
    .steps li::before { animation: plopp linear both; animation-timeline: view(); animation-range: entry 30% cover 32%; }
    .plan { animation: hochkommen linear both; animation-timeline: view(); animation-range: entry 0% cover 26%; }
    .header::after { content: ""; position: absolute; left: 0; right: 0; bottom: -3px; height: 3px; background: var(--marker); transform-origin: 0 50%;
      animation: fortschritt linear both; animation-timeline: scroll(root); }
  }
}
@media (max-width: 960px) {
  .try-grid { grid-template-columns: minmax(0, 1fr); max-width: 34rem; }
  .hero-shot { margin-top: 4rem; }
  .idx { left: -2%; top: -7%; }
  .bon { right: -2%; }
  .doodle-curl { display: none; }
  .doodle-sum { right: 0; top: .8rem; width: 2.6rem; height: 3rem; }
}
@media (max-width: 720px) {
  .header::after { display: none; }
}
@media (max-width: 600px) {
  .idx { width: 7.9rem; min-height: 5.2rem; padding: 1.24rem .7rem .5rem; font-size: 1rem; line-height: 1.07rem; top: -17%;
    background: linear-gradient(#e2574c, #e2574c) 0 1.12rem / 100% 2px no-repeat, repeating-linear-gradient(transparent 0 1rem, #b9c6ee 1rem 1.07rem) 0 1.21rem, var(--paper); }
  .idx::before { right: .9rem; top: -.7rem; width: .7rem; height: 1.9rem; border-width: 2px; }
  .idx::after { right: 1.06rem; top: -.4rem; width: .38rem; height: 1.3rem; border-width: 2px; }
  .doodle-check { width: 1.8rem; height: 1.8rem; }
  .bon { width: 6.9rem; bottom: 7%; }
  .bon p { padding: .5rem .55rem 1rem; font-size: .62rem; }
  .bon strong { font-size: .68rem; }
  .acts { bottom: -1.3rem; gap: .25rem; padding: .3rem; border-radius: 12px; }
  .desk .act { padding: .22rem .45rem; font-size: .68rem; border-radius: 8px; gap: .25rem; }
  .act .ico { width: .85rem; height: .85rem; }
  .ticker-track { gap: 1.8rem; }
  .ticker-track li { font-size: .92rem; }
  .flip, .flip summary, .flip-back, .quiz { min-height: 15rem; }
  .flip summary, .flip-back, .quiz { padding: 1.4rem; }
}
/* Neu in StudiNow (26.11.2026, Auftrag des Inhabers): links die Version im App Store, rechts gestrichelt das, was in Arbeit ist */
.updates { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 1.5rem; align-items: start; }
.update { background: var(--bg); border: 1px solid var(--line-strong); border-radius: var(--r-lg); padding: 1.7rem 1.7rem 1.2rem; }
.update-next { background: transparent; border: 2px dashed var(--line-strong); }
.update-tag { display: inline-flex; align-items: center; gap: .45rem; margin: 0; padding: .22rem .8rem; border-radius: 999px;
  border: 1.5px dashed var(--line-strong); color: var(--muted); font-size: .82rem; font-weight: 700; }
.update-live { border: 0; background: var(--accent-soft); color: var(--accent-text); }
.update-live::before { content: ""; width: .5rem; height: .5rem; border-radius: 50%; background: var(--ok); }
main.home .update h3 { margin: .85rem 0 .1rem; font-size: 1.45rem; letter-spacing: -.02em; }
.update .when { margin: 0; color: var(--muted); font-size: .92rem; }
.update h4 { margin: 1.5rem 0 0; padding-top: 1rem; border-top: 1px solid var(--line); font-family: var(--display);
  font-size: .8rem; font-weight: 700; letter-spacing: .07em; text-transform: uppercase; color: var(--muted); }
.update .checks { margin: .7rem 0 0; font-size: .97rem; }
.update .checks strong { color: var(--text); }
.update .checks li { color: var(--text-2); }
.planned li::before { left: .2rem; top: .42em; width: .7rem; height: .7rem; border: 2px solid var(--accent); border-radius: 50%; transform: none; }
.update .fine { margin: 1.4rem 0 0; }
@media (max-width: 860px) { .updates { grid-template-columns: minmax(0, 1fr); } }
@media (max-width: 600px) { .update { padding: 1.4rem 1.2rem 1rem; } }
"""

TEMPLATE = """\
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="{description}">
{social}<meta name="color-scheme" content="light dark">
<link rel="icon" href="{root}favicon.ico" sizes="48x48">
<link rel="icon" href="{root}favicon.png" type="image/png">
<link rel="apple-touch-icon" href="{root}apple-touch-icon.png">
<link rel="stylesheet" href="{root}style.css">
</head>
<body>
<a class="skip" href="#inhalt">Zum Inhalt springen</a>
<header class="header"><div class="wrap header-inner">
<a class="brand" href="{root}index.html"><img src="{root}logo.png" alt="" width="32" height="32">StudiNow</a>
<nav class="nav" aria-label="Hauptnavigation">{nav}</nav>
<a class="btn btn-small" href="{root}index.html#laden">App laden</a>
</div></header>
<main id="inhalt" class="{main_class}">
{body}
</main>
<footer class="footer">
<div class="wrap footer-grid">
<div class="footer-about">
<a class="brand" href="{root}index.html"><img src="{root}logo.png" alt="" width="32" height="32">StudiNow</a>
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
    ("Produkt", [("Startseite", "index.html"), ("Funktionen", "index.html#funktionen"), ("Neu in StudiNow", "index.html#neu"), ("So geht’s", "index.html#so-gehts"),
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
    "check": '<circle cx="12" cy="12" r="9"/><path d="M8 12.5l2.8 2.8L16 9.5"/>',
    "utensils": '<path d="M6 3v6a3 3 0 0 0 6 0V3M9 3v18M18 21V3c-2.5 1.5-3.5 5-3.5 9H18"/>',
    "cards": '<rect x="3" y="7" width="14" height="12" rx="2"/><path d="M7 4h12a2 2 0 0 1 2 2v10"/>',
    "pen": '<path d="M4 20l1-4L16.5 4.5a2.1 2.1 0 0 1 3 3L8 19z"/><path d="M14.5 6.5l3 3"/>',
    "sparkle": '<path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8zM19 16v4M17 18h4"/>',
    "book": '<path d="M5 4h11a3 3 0 0 1 3 3v13H8a3 3 0 0 1-3-3zM5 17a3 3 0 0 1 3-3h11"/>',
    "flip": '<path d="M4 12a8 8 0 0 1 14-5.3L20 9M20 4v5h-5M20 12a8 8 0 0 1-14 5.3L4 15M4 20v-5h5"/>',
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


# Kurzer Text fuer die Link-Vorschau der Startseite (die lange Beschreibung schneiden WhatsApp und iMessage ab)
SOCIAL_DESCRIPTION = {"index.html": "Skripte, Stundenplan, Mensa und Karteikarten auf iPad und iPhone. 7 Tage alles testen, ohne Zahlungsdaten."}
SOCIAL_IMAGE_PAGES = ("index.html", "i/index.html")   # nur dort passt die Einladungskarte als Bild
SOCIAL_IMAGE_ALT = "Einladungskarte von StudiNow: Du bist eingeladen. Dein Studium, alles an einem Ort. 7 Tage alles frei testen."


def social_meta(out_name: str, full_title: str, description: str) -> str:
    """Angaben fuer die Link-Vorschau in WhatsApp, iMessage usw. (Open Graph). Seit 24.11.2026 (Okay des Inhabers): Wer
    studinow.app oder einen Einladungslink teilt, sieht die Einladungskarte vorschau.jpg; die Vorschau ist antippbar und
    fuehrt auf die Seite. Adressen muessen hier vollstaendig sein (https://studinow.app/...), sonst laden die Dienste nichts.
    Die Einladungsseite bekommt keine eigene Adresse (og:url), damit der geteilte Link mit dem Code erhalten bleibt."""
    e = html.escape
    tags = [("og:site_name", "StudiNow"), ("og:type", "website"), ("og:locale", "de_DE"), ("og:title", full_title),
            ("og:description", SOCIAL_DESCRIPTION.get(out_name, description))]
    if "/" not in out_name:
        tags.append(("og:url", f"https://{DOMAIN}/" + ("" if out_name == "index.html" else out_name[:-5])))
    with_image = out_name in SOCIAL_IMAGE_PAGES
    if with_image:
        tags += [("og:image", f"https://{DOMAIN}/{PREVIEW.name}"), ("og:image:type", "image/jpeg"), ("og:image:width", "1200"),
                 ("og:image:height", "630"), ("og:image:alt", SOCIAL_IMAGE_ALT)]
    lines = [f'<meta property="{k}" content="{e(v)}">' for k, v in tags]
    lines.append(f'<meta name="twitter:card" content="{"summary_large_image" if with_image else "summary"}">')
    return "\n".join(lines) + "\n"


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
    return TEMPLATE.format(title=html.escape(full_title), description=html.escape(description),
                           social=social_meta(out_name, full_title, description), nav=nav, root=root,
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
    for logo in sorted(p for p in LOGO_SRC.iterdir() if p.suffix in (".png", ".ico")):
        files[logo.name] = logo.read_bytes()
    files[PREVIEW.name] = PREVIEW.read_bytes()
    for img in sorted(IMG_SRC.glob("*.jpg")):
        files[f"img/{img.name}"] = img.read_bytes()
    files[AASA_PATH] = apple_app_site_association()
    files[AASA_ROOT] = files[AASA_PATH]
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
