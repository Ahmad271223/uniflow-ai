"""Website studinow.app (site/, gebaut von tools/gen-site.py aus docs/release/*.md): sechs Seiten mit den Firmenangaben,
keine offenen Platzhalter ausser dem Hoster, keine fremden Ressourcen und kein Skript, hell/dunkel per CSS, Navigation
zu allen Seiten, erreichbar ueber einen einfachen statischen Server; site/ entspricht dem Stand der Texte.
Seit 05.11.2026 ist die Startseite eine Lernplattform-Startseite (Wunsch des Inhabers) mit Bildschirmfotos aus
docs/release/website-img/ (Demo-Inhalte, hell und dunkel), Tarifen und Fragen ohne Skript."""
import re
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "tools" / "gen-site.py"
SITE = ROOT / "site"
PAGES = ("index.html", "support.html", "datenschutz.html", "nutzungsbedingungen.html", "impressum.html", "konto-loeschen.html")
# Kopie der Apple-Datei an der Wurzel: Drag-and-drop aus dem Finder laesst den versteckten Ordner .well-known weg (05.11.2026)
AASA_ROOT = "apple-app-site-association"
FILES = PAGES + ("style.css", "icon.svg", "logo.png", "favicon.png", "apple-touch-icon.png", "_redirects", "_headers", AASA_ROOT)
IMG_SRC = ROOT / "docs" / "release" / "website-img"
IMAGES = tuple(f"img/{p.name}" for p in sorted(IMG_SRC.glob("*.jpg")))
# ausserhalb der Navigation: Einladungsseite hinter https://studinow.app/i/<CODE>, Bilder der Startseite und Universal Links
AASA = ".well-known/apple-app-site-association"
NESTED = ("i/index.html",) + IMAGES + (AASA,)
TEAM_ID = re.compile(r"(?:\b[A-Z0-9]{10}|\[\[TEAMID\]\])\.de\.uniflow\.ai\b")
COMPANY = ("IT solutions by Ahmad Fakih", "Ahmad Fakih", "Baldurstraße 5", "30657 Hannover", "support@studinow.app")
OPEN_ALLOWED: set[str] = set()                    # Hosting entschieden (08.11.2026): Hetzner, Nürnberg (EU)
PLACEHOLDER = re.compile(r"\[\[([^\]]+)\]\]")


@pytest.fixture(scope="module")
def generated(tmp_path_factory) -> Path:
    out = tmp_path_factory.mktemp("site")
    p = subprocess.run([sys.executable, str(TOOL), "--out", str(out)], capture_output=True, text=True, encoding="utf-8",
                       cwd=ROOT, timeout=60)
    assert p.returncode == 0, p.stdout + p.stderr
    assert f"{16 + len(IMAGES)} Dateien" in p.stdout and "Platzhalter offen" not in p.stdout   # Hosting seit 08.11.2026 eingetragen
    return out


def page(name: str) -> str:
    return (SITE / name).read_text(encoding="utf-8")


def test_site_matches_the_generator_output(generated):
    """site/ ist eingecheckt; nach jeder Aenderung an docs/release neu erzeugen (python tools/gen-site.py)."""
    assert sorted(p.name for p in SITE.iterdir() if p.is_file()) == sorted(FILES)
    assert sorted(p.relative_to(SITE).as_posix() for p in SITE.rglob("*") if p.is_file()) == sorted(FILES + NESTED)
    for name in FILES + NESTED[:-1]:
        if name == AASA_ROOT:
            continue
        assert (SITE / name).read_bytes() == (generated / name).read_bytes(), f"{name}: tools/gen-site.py ausfuehren"
    # die Team-ID kommt aus der nicht eingecheckten Team.xcconfig: ohne sie steht der Platzhalter im Erzeugten
    for aasa in (AASA, AASA_ROOT):
        assert TEAM_ID.sub("TEAM.de.uniflow.ai", page(aasa)) == TEAM_ID.sub("TEAM.de.uniflow.ai", (generated / aasa).read_text(encoding="utf-8"))
    assert page(AASA_ROOT) == page(AASA), "Kopie an der Wurzel gleich der Datei in .well-known"


@pytest.mark.parametrize("name", PAGES)
def test_pages_are_german_self_contained_and_without_scripts(name):
    html = page(name)
    assert html.startswith("<!doctype html>\n<html lang=\"de\">") and '<meta charset="utf-8">' in html
    assert 'name="viewport"' in html and '<link rel="stylesheet" href="style.css">' in html and 'href="favicon.png"' in html and 'src="logo.png"' in html
    assert "<script" not in html, "kein Skript"
    assert not re.search(r'<(link|script|img|iframe)[^>]*(src|href)="(https?:)?//', html), "keine fremden Ressourcen"
    assert "– StudiNow</title>" in html or "<title>StudiNow" in html
    for other in PAGES:
        assert f'href="{other}"' in html, f"{name}: Navigation zu {other}"
    assert f'<a href="{name}" aria-current="page">' in html, "aktuelle Seite markiert"
    assert '<a class="skip" href="#inhalt">' in html and '<main id="inhalt"' in html, "Sprungmarke zum Inhalt"
    assert '<nav class="nav" aria-label="Hauptnavigation">' in html and '<footer class="footer">' in html
    assert re.search(r"<img(?![^>]*\balt=)", html) is None, "jedes Bild hat einen Alternativtext"
    assert "Studora" not in html and "UniFlow" not in html, "alter Produktname"
    assert "© 2026 IT solutions by Ahmad Fakih" in html


def test_only_the_hoster_placeholders_are_open():
    for name in PAGES:
        html = page(name)
        found = set(PLACEHOLDER.findall(html))
        assert found <= OPEN_ALLOWED, (name, found - OPEN_ALLOWED)
        assert not found and "todo" not in html, name


def test_impressum_has_the_sole_trader_data():
    html = page("impressum.html")
    for s in COMPANY + ("Einzelunternehmen, Inhaber: Ahmad Fakih", "Deutschland", "USt-IdNr. nach § 27a UStG: DE462836430",
                        "Verantwortlich für den Inhalt nach § 18 Abs. 2 MStV", "Ahmad Fakih, Anschrift wie oben", "§ 36 VSBG"):
        assert s in html, s
    assert "Variante" not in html and "Telefon" not in html and "Kleinunternehmer" not in html
    assert 'href="datenschutz.html"' in html and 'href="konto-loeschen.html"' in html


def test_privacy_terms_and_deletion_name_the_controller_and_the_site():
    # die Markdown-Quellen sind hart umbrochen; Zeilenumbrueche zaehlen wie Leerzeichen
    ds, nb, kl = (re.sub(r"\s+", " ", page(n)) for n in ("datenschutz.html", "nutzungsbedingungen.html", "konto-loeschen.html"))
    for s in COMPANY:
        assert s in ds and s in nb, s
    assert "Landesbeauftragte für den Datenschutz Niedersachsen" in ds and "https://studinow.app/datenschutz" in ds
    assert "OpenAI" in ds and "Datenschutzbeauftragten gibt es nicht" in ds and "Falls doch benannt" not in ds
    assert "Anbieter ist IT solutions by Ahmad Fakih" in nb and "Anwaltlich prüfen" not in nb
    assert "support@studinow.app" in kl and "innerhalb von 7 Tagen" in kl and "30 Tage" in kl


def test_support_page_answers_the_three_questions():
    html = page("support.html")
    assert "support@studinow.app" in html
    for h in ("Wie melde ich mich bei meiner Uni an?", "Wo liegen meine Daten?", "Wie lösche ich mein Konto?"):
        assert f"<h3>{h}</h3>" in html, h
    assert "Stud.IP" in html and "Learnweb" in html and "Auf deinem iPad" in html
    assert "Einstellungen → Konto → <strong>Konto löschen</strong>" in html
    assert 'href="konto-loeschen.html"' in html and 'href="impressum.html"' in html


def test_start_page_is_a_learning_platform_landing_page_with_honest_content():
    """Startseite (Wunsch des Inhabers vom 05.11.2026, Vorbild Lernplattform): Einstieg mit Versprechen und App-Store-Knopf
    (noch ohne Store-Link: "#" und "Bald verfügbar"), Vertrauensleiste, Funktionen mit Bildschirmfotos, Schritte, Tarife
    aus app/plans.py, Fragen als details/summary, Abschluss. Die Website nennt die KI-Hilfe (Entscheidung 05.11.2026);
    die Store-Felder bleiben ohne KI (tests/test_release_texts.py). Keine erfundenen Zahlen, Stimmen oder Suchfelder."""
    html = page("index.html")
    flat = re.sub(r"\s+", " ", html)                 # die Quelle ist hart umbrochen
    assert '<main id="inhalt" class="home">' in html and '<h1 id="hero-title">Dein Studium an einem Ort.</h1>' in html
    assert "<title>StudiNow – dein Studium an einem Ort</title>" in html
    assert html.count('<a class="btn btn-store') == 2 and html.count('href="#" aria-describedby=') == 2
    assert "Im App Store laden" in html and "Bald verfügbar" in html and "iPhone-Version kommt bald" in flat
    for anchor in ("laden", "uni", "funktionen", "so-gehts", "preise", "fragen"):
        assert f'id="{anchor}"' in html, anchor
    for s in ("Stud.IP", "QIS", "Apple Pencil", "„Erkläre die ganze Vorlesung“", "„Erkläre alle Aufgaben“",
              "Wochentest", "Karteikarten", "Stapel", "Studienverlauf", "Prüfungsanmeldung", "Abgeben in Stud.IP",
              "Nachrichten beantworten", "Kein Uni-Passwort auf unseren Servern", "Kein Tracking", "nicht mit den Hochschulen verbunden",
              "Leibniz Universität Hannover", "support@studinow.app", "das aktuelle Semester zuerst"):
        assert s in flat, s
    # Wunsch des Inhabers 05.11.2026: ganz Deutschland ansprechen, aber ehrlich nur die angebundenen Hochschulen nennen
    # (Richtlinie 2.3, keine irrefuehrende Werbung); Systeme als Chips; Mensa mit Quellen und "ohne Gewähr".
    # Entscheidung 07.11.2026: 1.0 nur die LUH, Hochschule Hannover und Uni Hildesheim "in Kürze" (1.0.1)
    assert '<p class="eyebrow">Lernmanagementsystem für Hochschulen in ganz Deutschland</p>' in html
    assert re.search(r"Heute angebunden: <strong>Leibniz Universität Hannover</strong>\. In Kürze: Hochschule Hannover und "
                     r"Universität Hildesheim\. Weitere Hochschulen folgen\.", flat)
    assert "Heute für die Leibniz Universität Hannover." in flat and "In Kürze Hochschule Hannover und Uni Hildesheim" in flat
    assert "Deine fehlt?" in flat and 'href="mailto:support@studinow.app">Schreib uns</a>' in flat
    assert not re.search(r"alle(n)? (deutschen )?Hochschulen|jede(r)? Hochschule|alle(n)? Unis", flat), "nicht alle Hochschulen angebunden"
    assert "Zuerst für die Leibniz Universität Hannover" not in flat
    assert not re.search(r"Heute angebunden: <strong>Leibniz Universität Hannover</strong>, <strong>Hochschule Hannover", flat), "HsH erst 1.0.1"
    assert ('<ul class="systems" aria-label="Angebundene Hochschulsysteme"><li>Stud.IP</li><li>QIS</li>'
            '<li class="soon">In Kürze: Moodle, HISinOne, LSF</li></ul>') in html
    assert "Abgeben in Stud.IP</h3>" in html and "(Moodle in Kürze)" in flat
    faq = flat.split("Für welche Hochschulen ist StudiNow?")[1].split("</details>")[0]
    for s in ("ganz Deutschland", "zum Start mit voller Anbindung an die Leibniz Universität Hannover", "In Kürze folgen die Hochschule Hannover",
              "Universität Hildesheim", "Weitere Hochschulen folgen", "support@studinow.app", "nicht mit den Hochschulen verbunden"):
        assert s in faq, s
    assert "Modulkatalogen von über 300 Studiengängen und Fächern" in flat or "Modulkataloge von über 300 Studiengängen und Fächern" in flat
    mensa = flat.split('id="mensa"')[1].split("</section>")[0]
    for s in ("Heute in der Mensa", "Preise", "Nährwerte", "Allergene", "vegan", "vegetarisch", "Studentenwerk Hannover",
              "Studierendenwerk OstNiedersachsen", "ohne Gewähr", "img/mensa-hell.jpg", "img/mensa-dunkel.jpg"):
        assert s in mensa, s
    # Tarife wie app/plans.py, Probe wie docs/PREISLISTE.md
    from app import plans
    for key, price in (("free", "0 €"), ("plus", "19,99 €"), ("pro_ai", "39,99 €")):
        assert plans.PLANS[key]["name"] in html and f'<span class="amount">{price}</span>' in html, key
    # nur Jahresabos (Entscheidung des Inhabers vom 09.11.2026)
    assert plans.PLANS["plus"]["price_cents"] == 1999 and plans.PLANS["pro_ai"]["price_cents"] == 3999
    assert "pro Monat</span>" not in html and "um ein Jahr" in flat
    assert "7 Tage alles wie StudiNow Pro AI, ohne Zahlungsdaten" in flat and "deine Daten bleiben" in flat
    assert "24 Stunden" in flat and 'href="nutzungsbedingungen.html"' in html
    assert html.count("<details>") >= 5 and "<summary>" in html
    # ehrlich: keine Formulare/Suchfelder, keine Nutzerzahlen oder Stimmen, kein Anbieter-Name der KI
    assert "<form" not in html and "<input" not in html
    assert not re.search(r"\d[\d.]*\s*(\+|Tsd|k\b)?\s*(Studierende|Nutzer|Downloads|Bewertungen)", html)
    assert "OpenAI" not in html and "Sterne" not in html


def test_start_page_images_are_small_demo_screenshots_for_light_and_dark():
    html = page("index.html")
    assert IMAGES and len(IMAGES) % 2 == 0
    for img in IMAGES:
        data = (SITE / img).read_bytes()
        assert data[:3] == b"\xff\xd8\xff" and len(data) < 250_000, img
        assert data == (IMG_SRC / img[4:]).read_bytes()
    pictures = re.findall(r"<picture>(.*?)</picture>", html, re.S)
    assert len(pictures) == len(IMAGES) // 2 >= 3
    for pic in pictures:
        dark = re.search(r'<source media="\(prefers-color-scheme: dark\)" srcset="(img/[a-z-]+-dunkel\.jpg)">', pic)
        light = re.search(r'<img src="(img/[a-z-]+-hell\.jpg)" width="\d+" height="\d+"[^>]* alt="([^"]{20,})"', pic)
        assert dark and light, pic
        assert dark.group(1) in IMAGES and light.group(1) in IMAGES and "Demo" in light.group(2)
    total = sum(p.stat().st_size for p in SITE.rglob("*") if p.is_file())
    assert total < 2_000_000, f"Website {total} Bytes"


def test_invite_page_explains_the_invitation_and_links_the_store_without_ai_promises():
    """https://studinow.app/i/<CODE> (docs/EINLADUNGEN.md): erklaert die Einladung, fuehrt zum App Store, Stufen wie
    in app/invites.py, Pfade relativ zur Wurzel (../), nicht in der Navigation, kein Skript."""
    html = page("i/index.html")
    assert html.startswith("<!doctype html>\n<html lang=\"de\">") and "<script" not in html
    assert '<link rel="stylesheet" href="../style.css">' in html and 'href="../favicon.png"' in html and 'href="../index.html"' in html
    assert '<main id="inhalt" class="doc invite">' in html and "<h1>Du bist zu StudiNow eingeladen</h1>" in html
    assert 'class="btn btn-store"' in html and "Im App Store laden" in html and "Bald verfügbar" in html
    for s in ("1 Monat StudiNow Plus gratis", "3 Monate StudiNow Plus gratis", "12 Monate StudiNow Plus gratis",
              "12 Monate StudiNow Pro AI zum Plus-Preis (19,99 € statt 39,99 € für das Jahr)", "30 Tage", "Pro Person zählt eine Einladung",
              "Angebotscodes", "nie automatisch", "nichts kaufen und nichts teilen"):
        assert s in html, s
    assert 'href="../support.html"' in html and 'href="../datenschutz.html"' in html and "aria-current" not in html
    assert 'src="../logo.png"' in html and 'href="../index.html#preise"' in html
    assert not re.search(r"\bKI\b|ChatGPT|OpenAI", html), "keine KI-Versprechen auf oeffentlichen Seiten (docs/release/README.md)"
    assert not PLACEHOLDER.findall(html)


def test_apple_app_site_association_declares_the_invite_links():
    """Universal Links: appID <TEAMID>.de.uniflow.ai fuer /i/* (beide Schreibweisen), gueltiges JSON ohne Platzhalter,
    sobald Config/Team.xcconfig da ist (sonst [[TEAMID]], gelb wie die anderen offenen Stellen)."""
    import json
    doc = json.loads(page(".well-known/apple-app-site-association"))
    details = doc["applinks"]["details"]
    assert details[0]["paths"] == ["/i/*"] and details[1]["components"][0]["/"] == "/i/*"
    app_id = details[0]["appID"]
    assert TEAM_ID.fullmatch(app_id) and details[1]["appIDs"] == [app_id] and doc["webcredentials"]["apps"] == [app_id]
    team = ROOT / "apps" / "apple" / "Config" / "Team.xcconfig"
    if team.exists() and re.search(r"^\s*DEVELOPMENT_TEAM\s*=\s*[A-Z0-9]{10}", team.read_text(encoding="utf-8"), re.M):
        assert "[[TEAMID]]" not in app_id, "Team-ID aus Team.xcconfig eintragen: tools/gen-site.py ausfuehren"


def test_css_has_app_tokens_and_dark_mode_without_script():
    css = page("style.css")
    assert "--accent: #4f5bd5" in css and "--accent: #7b86f0" in css, "Akzent der App hell/dunkel"
    assert "@media (prefers-color-scheme: dark)" in css and "color-scheme: light dark" in css
    assert "mark.todo" in css and "@media (max-width: 600px)" in css and ":focus-visible" in css
    assert "url(" not in css and "@import" not in css, "keine fremden Ressourcen"
    assert page("icon.svg") == (ROOT / "app" / "static" / "icon.svg").read_text(encoding="utf-8")


def test_pages_are_served_by_a_plain_static_server():
    """Wie beim Veroeffentlichen auf einem statischen Host: python3 -m http.server liefert jede Seite mit 200."""
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    proc = subprocess.Popen([sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1", "--directory", str(SITE)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(50):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/style.css", timeout=1).read()
                break
            except OSError:
                time.sleep(0.1)
        for name in FILES + NESTED:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/{name}", timeout=5) as r:
                assert r.status == 200, name
                body = r.read()
            assert body == (SITE / name).read_bytes()
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=5) as r:
            assert "StudiNow – dein Studium an einem Ort" in r.read().decode("utf-8"), "index.html als Startseite"
    finally:
        proc.terminate()
        proc.wait(timeout=10)


def test_netlify_files_route_invites_and_serve_the_apple_file_as_json():
    red = (SITE / "_redirects").read_text(encoding="utf-8")
    assert "/i/* /i/index.html 200" in red and "https://studinow.ai/* https://studinow.app/:splat 301!" in red
    # fehlt .well-known nach dem Hochladen, liefert Netlify die Kopie an der Wurzel unter der Apple-Adresse aus
    assert "/.well-known/apple-app-site-association /apple-app-site-association 200\n" in red
    hdr = (SITE / "_headers").read_text(encoding="utf-8")
    assert "/.well-known/apple-app-site-association\n  Content-Type: application/json" in hdr
    assert "\n/apple-app-site-association\n  Content-Type: application/json" in hdr
    assert (SITE / AASA_ROOT).read_bytes() == (SITE / AASA).read_bytes()
