"""Store- und Rechtstexte (docs/release): vollstaendig, innerhalb der Laengen der Stores, KI nur in der Fassung mit
Pro AI, Platzhalter einheitlich markiert, Aussagen passend zum Build (Build 10, 06.11.2026)."""
import json
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
REL = ROOT / "docs" / "release"
APPLE = ROOT / "apps" / "apple" / "UniFlow"
FILES = ("README.md", "DATENSCHUTZ.md", "NUTZUNGSBEDINGUNGEN.md", "IMPRESSUM.md", "KONTO-LOESCHEN.md", "APP-STORE.md", "PLAY-STORE.md")
# Entscheidung des Inhabers (25.10.2026): keine KI-Funktionen anbieten oder bewerben. Seit 28.10.2026 verkauft V1 nur
# StudiNow Free und Plus; "Pro AI" und andere englische Formen ("AI", "OpenAI", "ChatGPT") gehoeren erst mit dem
# StudiNow-Dienst in die Store-Texte. "AI" nur in Grossbuchstaben (sonst traefe z. B. ein spanisches "ai").
AI_WORDS = re.compile(r"\bKI\b|\bK\.I\.|künstliche[nr]? Intelligenz|\bClaude\b|\bGPT\b|\bLLM\b|Sprachmodell|KI-|Tutor"
                      r"|automatisch erstellte[nr]? (Test|Zusammenfassung)|(?-i:\bA\.?I\b)|artificial intelligence|OpenAI|ChatGPT", re.I)
LIMITS = {"APP-STORE.md": {"name": 30, "subtitle": 30, "promo": 170, "description": 4000, "description-proai": 4000,
                          "keywords": 100, "whats-new": 4000, "review-notes": 4000, "review-notes-proai": 4000},
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
    for hit in ("StudiNow Pro AI", "mit AI-Tutor", "A.I. inklusive", "Powered by OpenAI", "ChatGPT verbinden", "KI-Tests", "Artificial Intelligence"):
        assert AI_WORDS.search(hit), hit
    for ok in ("Mai", "Lernplan im Mai", "Kaiserslautern", "StudiNow Plus", "Keine Werbung"):
        assert not AI_WORDS.search(ok), ok


# Nicht oeffentlich: die Hinweise fuer die App-Pruefung. Sie muessen den Build ehrlich beschreiben (Richtlinie 2.3.1,
# keine versteckten Funktionen). Entscheidung 05./06.11.2026: StudiNow-KI nur ueber Pro AI (Dienst app.studinow.app),
# eigenes ChatGPT aus ("bald verfuegbar", ChatGPTLink.isEnabled = false). Oeffentlich nennt nur die Beschreibung der
# Fassung mit Pro AI die KI; die Fassung ohne Pro AI bleibt ohne KI, weil man sie dann nicht kaufen kann.
NOT_PUBLIC = {"review-notes", "review-notes-proai"}
PRO_AI_PUBLIC = {"description-proai"}


def test_store_texts_promise_no_ai():
    for name in ("APP-STORE.md", "PLAY-STORE.md"):
        for field, text in fields(name).items():
            if field in NOT_PUBLIC | PRO_AI_PUBLIC:
                continue
            hit = AI_WORDS.search(text.replace("Keine KI-Funktionen", ""))
            assert not hit, (name, field, hit.group(0))


def test_pro_ai_description_is_honest_and_names_no_foreign_brand():
    """Die Fassung mit Pro AI nennt Preis, Credits, Kontopflicht und Fehlerhinweis; keine fremden Marken (2.3.7) und kein
    eigenes ChatGPT (im Build aus). Sonst sagt sie dasselbe wie die Fassung ohne Pro AI."""
    f = fields("APP-STORE.md")
    pro, plus = f["description-proai"], f["description"]
    for s in ("StudiNow Pro AI (39,99 €/Jahr)", "100 Credits", "StudiNow-Konto (Anmelden mit Apple)",
              "KI-Antworten können Fehler enthalten", "Ganze Vorlesung erklären", "StudiNow Plus (19,99 €/Jahr)"):
        assert s in pro, s
    assert not re.search(r"ChatGPT|OpenAI|Claude|Anthropic|\bGPT", pro)
    for s in ("FÜR STUDIERENDE IN GANZ DEUTSCHLAND", "Uni-Mail und Uni-Kalender", "Immatrikulations- oder BAföG-Bescheinigung",
              "Raumfinder", "Studentenwerk Hannover, Studierendenwerk OstNiedersachsen", "Passwort auf diesem iPad merken",
              "nicht in iCloud", "An Server von StudiNow geht es nie", "Kein Tracking"):
        assert s in pro and s in plus, s
    assert "Pro AI" not in plus and "39,99" not in plus


def _swift(rel: str) -> str:
    return (APPLE / rel).read_text(encoding="utf-8")


def test_review_notes_describe_the_build_honestly():
    """Beide Fassungen der Pruefhinweise: Demo nur ueber den Link auf der Anmeldeseite und "Beenden" (Entscheidung
    04.11.2026 "Nur fuer Pruefer"), Passwort nur im Schluesselbund dieses iPads, KI ueber den Dienst mit StudiNow-Konto,
    eigener OpenAI-Schluessel mit Haken der Einwilligung, Jahresabos. Die zitierten Oberflaechen-Texte stehen so im Swift-Code."""
    f = fields("APP-STORE.md")
    demo = _swift("Views/DemoViews.swift")
    assert 'firstStart = "Ohne Hochschulkonto ansehen (Demo)"' in demo and 'barTitle = "Demo-Inhalte – erfunden, ohne Hochschule"' in demo
    assert "Passwort auf diesem iPad merken" in _swift("Views/Settings/UniAutoLoginViews.swift")
    assert "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly" in _swift("Services/UniAutoLogin.swift")
    link = _swift("Services/ChatGPTLink.swift")
    assert "static let isEnabled = false" in link and "bald verfügbar" in link
    card = _swift("Views/Settings/OpenAIKeyCard.swift")
    assert 'agreeText = "Ich stimme zu, dass StudiNow die oben genannten Inhalte mit meinem Schlüssel direkt an OpenAI sendet."' in card
    assert ".disabled(!agreed ||" in card
    assert "ChatGPTSoonCard" not in _swift("Views/Settings/SettingsPage.swift")
    assert 'defaultServiceURL = "https://app.studinow.app"' in _swift("Services/StudoraAccountLink.swift")
    assert "„Mit Apple anmelden“ legt es an (7 Tage Probe mit 25 Credits" in _swift("Views/Settings/StudoraAccountCard.swift")
    # Pro AI wird mit 1.0 verkauft (Entscheidung 07.11.2026): fehlt das Produkt, nur der ehrliche Grund, kein "folgt"
    assert 'proAIMissingNote = "StudiNow Pro AI konnte gerade nicht aus dem App Store geladen werden.' in _swift("Purchases/Plans.swift")
    assert "Pro AI folgt" not in _swift("Purchases/Plans.swift")
    for field in ("review-notes", "review-notes-proai"):
        notes = f[field]
        assert "Keine KI-Funktionen" not in notes and "No AI" not in notes, field
        assert "Ohne Hochschulkonto ansehen (Demo)" in notes and "Beenden" in notes, field
        assert "Demo-Inhalte anlegen" not in notes and "Demo-Inhalte – erfunden, ohne Hochschule" in notes, field
        assert "Konto löschen" in notes and "Melden" in notes and "support@studinow.app" in notes, field
        assert "Passwort auf diesem iPad merken" in notes and "not synced to iCloud" in notes, field
        assert "never sent to our servers" in notes, field
        assert '"StudiNow-Konto" → "Mit Apple anmelden"' in notes and "https://app.studinow.app" in notes, field
        # eigener OpenAI-Schluessel (07.11.2026): nutzbar in jedem Tarif, Einwilligung per Haken, keine Anmeldung bei ChatGPT
        assert '"Eigenes ChatGPT", every plan' in notes and "directly from the iPad to OpenAI" in notes, field
        assert 'ticking "Ich stimme zu …"' in notes and "no ChatGPT login" in notes, field
        assert "yearly" in notes and "Monatlich" not in notes, field          # nur Jahresabos (09.11.2026)
        assert len(notes) <= 4000, (field, len(notes))
        # 1.0 nur LUH (Entscheidung 07.11.2026): HsH und Hildesheim erst mit 1.0.1 wieder nennen
        assert "Connected today: Leibniz Universität Hannover" in notes, field
        assert "Hochschule Hannover" not in notes and "Hildesheim" not in notes, field
        assert "Sign in with ChatGPT" not in notes and "consent" not in notes, field
    # Fassung nur Plus ist ueberholt (1.0 mit Pro AI); sie zitiert den Satz, den die App ohne Pro-AI-Produkt wirklich zeigt
    assert "not part of this submission" in f["review-notes"] and "StudiNow Pro AI konnte gerade nicht aus dem App Store geladen werden." in f["review-notes"]
    assert "Pro AI folgt" not in f["review-notes"]
    text = (REL / "APP-STORE.md").read_text(encoding="utf-8")
    assert "ÜBERHOLT, nicht verwenden" in text and "für 1.0 verwenden" in text
    pro = f["review-notes-proai"]
    assert "sandbox" in pro and "100 credits" in pro and "section 8c" in pro and "never name, e-mail or university credentials" in pro
    # 07.11.2026 abends: Probe einmal je iPad, danach Pflicht-Entscheidung mit "Bei Free bleiben" ohne Kauf (3.1.2/5.1.1);
    # Frage nach frueheren Semestern (Demo hat keine); eigener Schluessel praezise je Funktion
    trial = _swift("Views/Settings/TrialBanner.swift")
    assert 'overTitle = "Deine Probe ist vorbei"' in trial and 'stayFree = "Bei Free bleiben"' in trial
    assert '"Deine Probe ist vorbei"' in pro and '"Bei Free bleiben" is a valid choice without any purchase' in pro and "once per iPad" in pro
    assert "Auch frühere Semester laden?" in _swift("Views/Library/OlderSemestersViews.swift")
    assert '"Auch frühere Semester laden?"' in pro and "Wi-Fi only" in pro
    assert "flashcards from a document need Plus, weekly tests Pro AI" in pro
    assert "Wochentests ab \\(UFPlan.proAI.name)" in _swift("Views/Settings/OpenAIKeyCard.swift")
    desc = f["description-proai"]
    assert "danach wählst du: Free bleibt kostenlos, oder Plus bzw. Pro AI" in desc and "danach gilt Free" not in desc
    assert "mit Plus Lernplan automatisch" in desc and "Lernkalender" in desc
    assert "eigenen API-Schlüssel" in desc
    assert "„iPhone- und iPad-Apps auf Apple-Silicon-Macs“ = verfügbar" in text and "macOS nicht einreichen" in text


def test_no_store_text_says_the_university_password_is_never_stored():
    """Seit 06.11.2026 (Automatisch anmelden) darf die App das Uni-Passwort im Schluesselbund dieses iPads merken: kein
    Satz "speichert kein Passwort" mehr, weder in den Feldern noch in den Datenschutz-Angaben."""
    text = (REL / "APP-STORE.md").read_text(encoding="utf-8")
    for bad in ("speichert StudiNow nicht", "speichert die iPad-App nicht", "speichert kein Passwort", "merken kann es auf Wunsch iOS"):
        assert bad not in text, bad
    assert "kSecAttrSynchronizable = false" in text and "nie an StudiNow-Server" in text


def test_app_store_texts_match_current_build():
    """Fertig zum Einfuegen: keine Platzhalter; Hochschulen nur als "angebunden heute"; kein Zeitmesser (ausgeblendet);
    die genannten Zeichenzahlen stimmen; die Bildschirmfotos gibt es (falls der Ordner auf diesem Rechner liegt)."""
    text = (REL / "APP-STORE.md").read_text(encoding="utf-8")
    f = fields("APP-STORE.md")
    assert "[[" not in text and "]]" not in text
    import re
    build = re.search(r'CURRENT_PROJECT_VERSION: "(\d+)"', (ROOT / "apps" / "apple" / "project.yml").read_text(encoding="utf-8")).group(1)
    assert f"Build {build}" in text, f"APP-STORE.md nennt nicht den aktuellen Build {build}"
    assert "Offene Entscheidung KI" not in text
    # Entscheidung des Inhabers 07.11.2026: 1.0 (Build 16) nur mit der LUH; HsH und Hildesheim bleiben im Code, sind im
    # Store-Build ausgeblendet (project.yml UF_SHIPPED_UNIVERSITIES, Release "luh") und kommen mit 1.0.1
    assert "1.0 nur LUH, 1.0.1 mit HsH und Hildesheim" in text
    yml = (ROOT / "apps" / "apple" / "project.yml").read_text(encoding="utf-8")
    assert re.search(r'Release:\n\s+UF_SHIPPED_UNIVERSITIES: "luh"\n', yml), "Release-Build nur LUH"
    assert re.search(r'Debug:\n\s+UF_SHIPPED_UNIVERSITIES: "luh hildesheim hsh"\n', yml), "Debug und Tests alle drei"
    assert "UFShippedUniversities: $(UF_SHIPPED_UNIVERSITIES)" in yml
    if (APPLE / "Info.plist").is_file():                 # von xcodegen erzeugt (gitignore), nur wo es liegt
        assert "<key>UFShippedUniversities</key>" in (APPLE / "Info.plist").read_text(encoding="utf-8")
    for field in ("description", "description-proai"):
        d = f[field]
        assert "Angebunden heute: Leibniz Universität Hannover (Stud.IP, QIS). Weitere Hochschulen folgen." in d
        assert "alle Hochschulen" not in d and "allen Hochschulen" not in d
    for field in ("description", "description-proai", "keywords", "promo", "whats-new", "subtitle", "name"):
        v = f[field]
        for bad in ("Hochschule Hannover", "Hildesheim", "Moodle", "Learnweb", "HISinOne", "PLuS", "Campusmanagement"):
            assert bad not in v, (field, bad)
    assert "static let isEnabled = false" in _swift("Views/Timer/StudyTimer.swift")
    for field, value in f.items():
        assert "Zeitmesser" not in value and "Pomodoro" not in value, field
    for field in ("description", "description-proai", "review-notes", "review-notes-proai", "keywords", "whats-new"):
        assert f"– {len(f[field])} Zeichen" in text, field
    # Endgueltiger Satz mit Pro AI (07.11.2026, zweiter Satz vom Nachmittag: flacher KI-Hilfe-Kopf, "Neue Mails
    # pruefen", nur LUH): genau zehn Bilder im Hochformat, je Motiv eine Fassung hell oder dunkel, im eigenen Ordner;
    # der Pruef-Screenshot (reserve/) liegt im frueheren Satz
    section = text[text.index("## Bildschirmfotos"):]
    names = re.findall(r"`(\d\d-[a-z-]+-(?:light|dark)\.png)`", section)
    assert len(names) == 10 and len(set(names)) == 10, names
    assert [n[:2] for n in names] == [f"{i:02d}" for i in range(1, 11)], names
    assert any("-ki-" in n for n in names), "Pro AI eingereicht: der Satz zeigt die KI"
    assert "appstore-screenshots-final-2026-11-07" in section
    shots = Path.home() / "Studora-Builds" / "appstore-screenshots-final-2026-11-07"
    if shots.is_dir():
        assert sorted(p.name for p in shots.glob("*.png")) == sorted(names)
    old = Path.home() / "Studora-Builds" / "appstore-screenshots"
    reserve = set(re.findall(r"`(reserve/\d\d[a-z]?-[a-z-]+-light-portrait\.png)`", text))
    assert reserve
    if old.is_dir():
        for n in reserve:
            assert (old / n).is_file(), n


def test_store_texts_keep_the_universities_authoritative_and_no_tracking():
    for name in ("APP-STORE.md", "PLAY-STORE.md"):
        f = fields(name)
        long = f.get("description") or f.get("full")
        assert "nicht mit den Hochschulen verbunden" in long and "Verbindlich für Termine, Fristen und Noten" in long
        assert "Kein Tracking" in long and "19,99 €" in long and "https://studinow.app/datenschutz" in long


def test_placeholders_use_one_syntax_and_are_listed():
    """Alle offenen Stellen stehen als [[...]]; der README nennt die noch offenen Platzhalter (Hoster, Telefon)."""
    readme = (REL / "README.md").read_text(encoding="utf-8")
    seen = set()
    for f in FILES:
        text = (REL / f).read_text(encoding="utf-8")
        assert "TODO" not in text and "TBD" not in text and "XXX" not in text, f
        seen |= set(re.findall(r"\[\[([^\]]+)\]\]", text))
    for must in ("Hoster", "Serverstandort", "Telefon"):
        assert must in seen and f"[[{must}]]" in readme, must


# Angaben des Inhabers vom 03.11.2026 (docs/release/angaben.json), zur Veroeffentlichung bestimmt
OWNER = ("IT solutions by Ahmad Fakih", "Inhaber: Ahmad Fakih", "Baldurstraße 5", "30657 Hannover", "support@studinow.app")


def test_legal_texts_carry_the_owner_data_and_only_hosting_is_open():
    """Impressum, Datenschutz, Nutzungsbedingungen und Konto loeschen sind an Ort und Stelle gefuellt (README,
    Abschnitt Platzhalter); offen bleibt nur der Hoster in Datenschutz 11 – nichts erfinden."""
    for f in ("IMPRESSUM.md", "DATENSCHUTZ.md", "NUTZUNGSBEDINGUNGEN.md"):
        text = (REL / f).read_text(encoding="utf-8")
        for s in OWNER:
            assert s in text, (f, s)
        assert "Studora" not in text and "UniFlow" not in text, f
    im = (REL / "IMPRESSUM.md").read_text(encoding="utf-8")
    assert "USt-IdNr. nach § 27a UStG: DE462836430" in im and "Verantwortlich für den Inhalt nach § 18 Abs. 2 MStV" in im
    assert "Ahmad Fakih, Anschrift wie oben" in im and "[[" not in im and "Variante" not in im
    assert set(re.findall(r"\[\[([^\]]+)\]\]", (REL / "DATENSCHUTZ.md").read_text(encoding="utf-8"))) == set()
    for f in ("NUTZUNGSBEDINGUNGEN.md", "KONTO-LOESCHEN.md", "SUPPORT.md", "STARTSEITE.md"):
        text = (REL / f).read_text(encoding="utf-8")
        assert "[[" not in text and "support@studinow.app" in text, f
    for f in ("APP-STORE.md", "PLAY-STORE.md"):
        text = (REL / f).read_text(encoding="utf-8")
        assert "https://studinow.app/datenschutz" in text and "support@studinow.app" in text and "[[Domain]]" not in text, f
    assert "© 2026 IT solutions by Ahmad Fakih" in (REL / "APP-STORE.md").read_text(encoding="utf-8")
    assert json.loads((REL / "angaben.json").read_text(encoding="utf-8"))["ustid"] == "DE462836430"


def test_privacy_policy_matches_the_implementation():
    """Zahlen und Fakten der Datenschutzerklaerung stimmen mit dem Code ueberein."""
    from app import accounts, community
    t = (REL / "DATENSCHUTZ.md").read_text(encoding="utf-8")
    assert f"{accounts.SESSION_DAYS} Tage" in t and f"{accounts.RESET_MINUTES} Minuten" in t and f"{accounts.LOCK_MINUTES} Minuten" in t
    assert "30 Tage nach Löschung" in t                       # accounts.purge_deleted(30)
    assert "scrypt" in t and "AES-256-GCM" in t and "SHA-256" in t
    assert f"Ab {'drei' if community.REPORTS_TO_HIDE == 3 else community.REPORTS_TO_HIDE} Meldungen" in t
    assert "uniflow_session" in t and "lernapp_pin" in t
    # 06.11.2026: keine Hochschul-Passwoerter auf unseren Servern, kein Abgleich durch den Dienst (app/vault.py, app/jobs.py)
    from app import jobs, vault
    assert vault.users_with_credentials() == [] and jobs.HOSTED_UNI_SYNC is False
    assert "speichern wir Hochschul-Passwörter nie" in t and "nie auf unseren Servern" in t
    assert "um 8 und 15 Uhr" not in t and "verschlüsselt in deinem Konto" not in t
    from app import retention
    assert f"gelöscht nach {retention.ACCESS_DAYS} Tagen" in t and f"gelöscht nach\n  {retention.SYNC_DAYS} Tagen" in t.replace("\r", "")
    assert "keine Schriften von Google" in t and "Google Fonts" not in t, "Schrift wird selbst ausgeliefert (tests/test_fonts.py)"


def test_old_release_doc_no_longer_promises_ai_in_store_texts():
    t = (ROOT / "docs" / "RELEASE-VORBEREITUNG.md").read_text(encoding="utf-8")
    assert "KI-Wochentests" not in t and "KI-Test" not in t
    assert "docs/release/APP-STORE.md" in t
