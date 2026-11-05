"""Website studinow.app (site/, gebaut von tools/gen-site.py aus docs/release/*.md): sechs Seiten mit den Firmenangaben,
keine offenen Platzhalter ausser dem Hoster, keine fremden Ressourcen und kein Skript, hell/dunkel per CSS, Navigation
zu allen Seiten, erreichbar ueber einen einfachen statischen Server; site/ entspricht dem Stand der Texte."""
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
FILES = PAGES + ("style.css", "icon.svg")
# ausserhalb der Navigation: Einladungsseite hinter https://studinow.app/i/<CODE> und Universal Links der iPad-App
NESTED = ("i/index.html", ".well-known/apple-app-site-association")
TEAM_ID = re.compile(r"(?:\b[A-Z0-9]{10}|\[\[TEAMID\]\])\.de\.uniflow\.ai\b")
COMPANY = ("IT solutions by Ahmad Fakih", "Ahmad Fakih", "Baldurstraße 5", "30657 Hannover", "support@studinow.app")
OPEN_ALLOWED = {"Hoster", "Serverstandort", "Mail-Anbieter"}      # Hosting des Dienstes ist nicht entschieden
PLACEHOLDER = re.compile(r"\[\[([^\]]+)\]\]")


@pytest.fixture(scope="module")
def generated(tmp_path_factory) -> Path:
    out = tmp_path_factory.mktemp("site")
    p = subprocess.run([sys.executable, str(TOOL), "--out", str(out)], capture_output=True, text=True, encoding="utf-8",
                       cwd=ROOT, timeout=60)
    assert p.returncode == 0, p.stdout + p.stderr
    assert "10 Dateien" in p.stdout and "datenschutz.html: 3 Platzhalter offen" in p.stdout
    return out


def page(name: str) -> str:
    return (SITE / name).read_text(encoding="utf-8")


def test_site_matches_the_generator_output(generated):
    """site/ ist eingecheckt; nach jeder Aenderung an docs/release neu erzeugen (python tools/gen-site.py)."""
    assert sorted(p.name for p in SITE.iterdir() if p.is_file()) == sorted(FILES)
    assert sorted(p.relative_to(SITE).as_posix() for p in SITE.rglob("*") if p.is_file()) == sorted(FILES + NESTED)
    for name in FILES + NESTED[:1]:
        assert (SITE / name).read_bytes() == (generated / name).read_bytes(), f"{name}: tools/gen-site.py ausfuehren"
    # die Team-ID kommt aus der nicht eingecheckten Team.xcconfig: ohne sie steht der Platzhalter im Erzeugten
    aasa = NESTED[1]
    assert TEAM_ID.sub("TEAM.de.uniflow.ai", page(aasa)) == TEAM_ID.sub("TEAM.de.uniflow.ai", (generated / aasa).read_text(encoding="utf-8"))


@pytest.mark.parametrize("name", PAGES)
def test_pages_are_german_self_contained_and_without_scripts(name):
    html = page(name)
    assert html.startswith("<!doctype html>\n<html lang=\"de\">") and '<meta charset="utf-8">' in html
    assert 'name="viewport"' in html and '<link rel="stylesheet" href="style.css">' in html and 'href="icon.svg"' in html
    assert "<script" not in html, "kein Skript"
    assert not re.search(r'<(link|script|img|iframe)[^>]*(src|href)="(https?:)?//', html), "keine fremden Ressourcen"
    assert "– StudiNow</title>" in html or "<title>StudiNow" in html
    for other in PAGES:
        assert f'href="{other}"' in html, f"{name}: Navigation zu {other}"
    assert f'<a href="{name}" class="active">' in html
    assert "Studora" not in html and "UniFlow" not in html, "alter Produktname"
    assert "© 2026 IT solutions by Ahmad Fakih" in html


def test_only_the_hoster_placeholders_are_open():
    for name in PAGES:
        html = page(name)
        found = set(PLACEHOLDER.findall(html))
        assert found <= OPEN_ALLOWED, (name, found - OPEN_ALLOWED)
        if name == "datenschutz.html":
            assert found == OPEN_ALLOWED
            assert html.count('<mark class="todo"') == 3, "offene Stellen sichtbar markiert"
        else:
            assert not found and "todo" not in html


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


def test_start_page_describes_the_product_with_store_and_screenshot_placeholders():
    html = page("index.html")
    assert '<main class="home">' in html and "<h1>StudiNow – dein Studium an einem Ort</h1>" in html
    assert 'class="badge"' in html and "Laden im App Store" in html
    assert html.count('<div class="shot"></div>') == 3, "drei Bildschirmfoto-Platzhalter"
    assert "Kein Tracking" in html and "1,99 €" in html and "nicht mit den Hochschulen verbunden" in html
    assert 'href="support.html"' in html
    assert not re.search(r"\bKI\b|ChatGPT|OpenAI", html), "keine KI-Versprechen auf der Produktseite (docs/release/README.md)"


def test_invite_page_explains_the_invitation_and_links_the_store_without_ai_promises():
    """https://studinow.app/i/<CODE> (docs/EINLADUNGEN.md): erklaert die Einladung, fuehrt zum App Store, Stufen wie
    in app/invites.py, Pfade relativ zur Wurzel (../), nicht in der Navigation, kein Skript."""
    html = page("i/index.html")
    assert html.startswith("<!doctype html>\n<html lang=\"de\">") and "<script" not in html
    assert '<link rel="stylesheet" href="../style.css">' in html and 'href="../icon.svg"' in html and 'href="../index.html"' in html
    assert '<main class="home">' in html and "<h1>Du bist zu StudiNow eingeladen</h1>" in html
    assert 'class="badge"' in html and "Laden im App Store" in html
    for s in ("1 Monat StudiNow Plus gratis", "3 Monate StudiNow Plus gratis", "12 Monate StudiNow Plus gratis",
              "12 Monate StudiNow Pro AI zum Plus-Preis (1,99 € statt 3,99 € pro Monat)", "30 Tage", "Pro Person zählt eine Einladung",
              "Angebotscodes", "nie automatisch", "nichts kaufen und nichts teilen"):
        assert s in html, s
    assert 'href="../support.html"' in html and 'href="../datenschutz.html"' in html and 'class="active"' not in html
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
    assert "mark.todo" in css and "@media (max-width: 600px)" in css
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
