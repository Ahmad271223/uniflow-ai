"""Texte zu Tarifen, Probe und Einladungen halten den Stand vom 04.11.2026 (Paket D vom 05.11.2026): drei Tarife Free,
Plus 1,99 EUR, Pro AI 3,99 EUR; keine Einfuehrungsangebote; 7 Tage Probe mit allem wie Pro AI, danach Free, Daten
bleiben; Pro Connect gibt es nicht mehr (nur der alte Schluessel `pro_connect`, intern). Prueft die sichtbaren Texte der
Oberflaeche (app/static), den Vertrag fuer die Apps und die Preisliste mit den Entscheidungen des Inhabers."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STATIC = ROOT / "app" / "static"
ALT = re.compile(r"Pro[ -]Connect|Woche gratis|Woche kostenlos|Einführungsangebot|Einfuehrungsangebot", re.I)


def _lines(path):
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        yield n, line


def test_no_visible_pro_connect_or_intro_offer_in_the_web_ui():
    """Nur Kommentare duerfen die alten Namen nennen; sichtbarer Text (Zeichenketten, Vorlagen) nie."""
    bad = []
    for f in sorted(STATIC.glob("*.js")) + [STATIC / "index.html", STATIC / "login.html"]:
        for n, line in _lines(f):
            if ALT.search(line) and not line.lstrip().startswith(("//", "*", "/*")):
                bad.append(f"{f.name}:{n}: {line.strip()[:120]}")
    assert not bad, bad


def test_contract_for_the_apps_shows_three_plans_and_no_old_names():
    from app import plans
    text = json.dumps(plans.contract(), ensure_ascii=False)
    assert not ALT.search(text), "Vertrag nennt weder Pro Connect noch ein Einfuehrungsangebot"
    assert "proconnect" not in text and "pro_connect" not in text
    assert [plans.PLANS[k]["name"] for k in plans.ORDER] == ["StudiNow Free", "StudiNow Plus", "StudiNow Pro AI"]
    # die 7 Tage Probe gelten fuer alle wie Pro AI (kein Plus-Angebot)
    assert plans.TRIAL == {"days": 7, "plan": "pro_ai"}


def test_web_plan_texts_match_trial_free_and_service_wording():
    """Tarifseite: Probe wie Pro AI, ohne Zahlungsdaten, danach Free; Einzelplatz: Pro AI kommt mit dem Dienst."""
    abo = (STATIC / "views-abo.js").read_text(encoding="utf-8")
    assert "ohne Zahlungsdaten" in abo and "bleibst bei Free" in abo and "nie von selbst kostenpflichtig" in abo
    assert "kommt mit dem StudiNow-Dienst" in abo and "Auf diesem PC kannst du nichts kaufen" in abo
    # Abo-Pflicht in Web und Windows (05.11.2026): nach der Probe kein "Bei Free bleiben", sondern ansehen und exportieren
    assert "ohne Abo kannst du deine Daten weiter ansehen und exportieren" in abo and "GATE_TEXTS.lockedText" in abo
    # Plus gilt je Geraet: der Hinweis beim Abgleich nennt Pro AI, nicht Plus
    link = (STATIC / "studora-link.js").read_text(encoding="utf-8")
    assert "erst mit StudiNow Pro AI zwischen deinen Geräten" in link and "gleichen ab StudiNow Plus ab" not in link


def test_price_list_and_decisions_agree_with_plans_py():
    from app import plans
    preise = (ROOT / "docs" / "PREISLISTE.md").read_text(encoding="utf-8")
    entsch = (ROOT / "docs" / "ENTSCHEIDUNGEN-INHABER-2026-11-04.md").read_text(encoding="utf-8")
    for key in ("plus", "pro_ai"):
        euro = f"{plans.PLANS[key]['price_cents'] / 100:.2f}".replace(".", ",")
        assert f"{euro} €" in preise, f"Preisliste nennt {euro} €"
    for doc in (preise, entsch):                # "Woche gratis" darf nur vorkommen, um es zu verneinen
        for m in re.finditer("Woche gratis", doc):
            assert re.search(r"keine|ohne", doc[max(0, m.start() - 120):m.start()], re.I), "kein '1 Woche gratis' mehr"
    # Einfuehrungsangebote sind entschieden gestrichen und in beiden Dateien vermerkt
    for doc in (preise, entsch):
        assert re.search(r"keine[nrs]? (Apple-)?Einführungsangebot", doc, re.I), "Entscheidung 'ohne Einfuehrungsangebot' vermerkt"
    assert "kommt mit dem StudiNow-Dienst" in preise and "Windows" in entsch
