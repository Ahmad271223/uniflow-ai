"""Store- und Rechtstexte (docs/release): vollstaendig, ohne KI-Versprechen, innerhalb der Laengen der Stores,
Platzhalter einheitlich markiert, alte KI-Formulierungen aus der Release-Doku entfernt."""
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
REL = ROOT / "docs" / "release"
FILES = ("README.md", "DATENSCHUTZ.md", "NUTZUNGSBEDINGUNGEN.md", "IMPRESSUM.md", "KONTO-LOESCHEN.md", "APP-STORE.md", "PLAY-STORE.md")
# Entscheidung des Inhabers (25.10.2026): keine KI-Funktionen anbieten oder bewerben. Seit 28.10.2026 verkauft V1 nur
# Studora Free und Plus; "Pro AI" und andere englische Formen ("AI", "OpenAI", "ChatGPT") gehoeren erst mit dem
# Studora-Dienst in die Store-Texte. "AI" nur in Grossbuchstaben (sonst traefe z. B. ein spanisches "ai").
AI_WORDS = re.compile(r"\bKI\b|\bK\.I\.|künstliche[nr]? Intelligenz|\bClaude\b|\bGPT\b|\bLLM\b|Sprachmodell|KI-|Tutor"
                      r"|automatisch erstellte[nr]? (Test|Zusammenfassung)|(?-i:\bA\.?I\b)|artificial intelligence|OpenAI|ChatGPT", re.I)
LIMITS = {"APP-STORE.md": {"name": 30, "subtitle": 30, "promo": 170, "description": 4000, "keywords": 100, "whats-new": 4000, "review-notes": 4000},
          "PLAY-STORE.md": {"title": 30, "short": 80, "full": 4000}}


def fields(name: str) -> dict[str, str]:
    text = (REL / name).read_text(encoding="utf-8")
    out = dict(re.findall(r"```text ([a-z-]+)\n(.*?)\n```", text, re.S))
    assert out, name
    return out


def test_all_release_files_exist_and_are_marked_as_drafts():
    for f in FILES:
        text = (REL / f).read_text(encoding="utf-8")
        assert re.search(r"Entw(urf|ürfe)", text) and "26.10.2026" in text, f


@pytest.mark.parametrize("name", ["APP-STORE.md", "PLAY-STORE.md"])
def test_store_fields_within_limits(name):
    f = fields(name)
    assert set(f) >= set(LIMITS[name]), (name, set(LIMITS[name]) - set(f))
    for field, limit in LIMITS[name].items():
        # Markierte Satzteile [[...]] zaehlen mit (sie werden entweder uebernommen oder gestrichen)
        n = len(f[field])
        assert n <= limit, f"{name} {field}: {n} > {limit} Zeichen"
    kw = f.get("keywords") or f.get("title")
    assert "  " not in kw


def test_ai_words_catch_english_forms():
    for hit in ("Studora Pro AI", "mit AI-Tutor", "A.I. inklusive", "Powered by OpenAI", "ChatGPT verbinden", "KI-Tests", "Artificial Intelligence"):
        assert AI_WORDS.search(hit), hit
    for ok in ("Mai", "Lernplan im Mai", "Kaiserslautern", "Studora Plus", "Keine Werbung"):
        assert not AI_WORDS.search(ok), ok


def test_store_texts_promise_no_ai():
    for name in ("APP-STORE.md", "PLAY-STORE.md"):
        for field, text in fields(name).items():
            hit = AI_WORDS.search(text.replace("Keine KI-Funktionen", ""))
            assert not hit, (name, field, hit.group(0))


def test_store_texts_keep_the_universities_authoritative_and_no_tracking():
    for name in ("APP-STORE.md", "PLAY-STORE.md"):
        f = fields(name)
        long = f.get("description") or f.get("full")
        assert "nicht mit den Hochschulen verbunden" in long and "Verbindlich für Termine, Fristen und Noten" in long
        assert "Kein Tracking" in long and "1,99 €" in long and "[[Domain]]/datenschutz" in long


def test_placeholders_use_one_syntax_and_are_listed():
    """Alle offenen Stellen stehen als [[...]]; der README nennt die haeufigen Platzhalter."""
    readme = (REL / "README.md").read_text(encoding="utf-8")
    seen = set()
    for f in FILES:
        text = (REL / f).read_text(encoding="utf-8")
        assert "TODO" not in text and "TBD" not in text and "XXX" not in text, f
        seen |= set(re.findall(r"\[\[([^\]]+)\]\]", text))
    for must in ("Name", "Anschrift", "E-Mail", "Domain", "Hosting-Anbieter", "Datum"):
        assert must in seen and f"[[{must}]]" in readme, must


def test_privacy_policy_matches_the_implementation():
    """Zahlen und Fakten der Datenschutzerklaerung stimmen mit dem Code ueberein."""
    from app import accounts, community
    t = (REL / "DATENSCHUTZ.md").read_text(encoding="utf-8")
    assert f"{accounts.SESSION_DAYS} Tage" in t and f"{accounts.RESET_MINUTES} Minuten" in t and f"{accounts.LOCK_MINUTES} Minuten" in t
    assert "30 Tage nach Löschung" in t                       # accounts.purge_deleted(30)
    assert "scrypt" in t and "AES-256-GCM" in t and "SHA-256" in t
    assert f"Ab {'drei' if community.REPORTS_TO_HIDE == 3 else community.REPORTS_TO_HIDE} Meldungen" in t
    assert "uniflow_session" in t and "lernapp_pin" in t and "08:00" in t and "15:00" in t
    from app import retention
    assert f"gelöscht nach {retention.ACCESS_DAYS} Tagen" in t and f"gelöscht nach\n  {retention.SYNC_DAYS} Tagen" in t.replace("\r", "")
    assert "keine Schriften von Google" in t and "Google Fonts" not in t, "Schrift wird selbst ausgeliefert (tests/test_fonts.py)"


def test_old_release_doc_no_longer_promises_ai_in_store_texts():
    t = (ROOT / "docs" / "RELEASE-VORBEREITUNG.md").read_text(encoding="utf-8")
    assert "KI-Wochentests" not in t and "KI-Test" not in t
    assert "docs/release/APP-STORE.md" in t
