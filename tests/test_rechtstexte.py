"""tools/rechtstexte-fuellen.py: fuellt die Platzhalter der Rechts- und Store-Texte aus einer JSON; --check meldet offene
Stellen (Exit 1); leere Werte und unbekannte Platzhalter sind Fehler; nach dem Fuellen bleibt kein [[ und kein TODO.
Stand 03.11.2026: docs/release/*.md sind mit den Angaben des Inhabers (docs/release/angaben.json) an Ort und Stelle
gefuellt; offen sind nur Hoster, Serverstandort (Datenschutz 11; Mail-Anbieter STRATO seit 05.11.2026), Telefon (Play Store) und die Schalter
und Pruefhinweise des Play Store. APP-STORE.md ist seit 06.11.2026 ohne Platzhalter (fertig zum Einfuegen)."""
import datetime as dt
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "tools" / "rechtstexte-fuellen.py"
REL = ROOT / "docs" / "release"
EXAMPLE = REL / "angaben.example.json"
ANGABEN = REL / "angaben.json"
FILES = ("IMPRESSUM.md", "DATENSCHUTZ.md", "NUTZUNGSBEDINGUNGEN.md", "KONTO-LOESCHEN.md", "APP-STORE.md", "PLAY-STORE.md")
LEGAL = ("IMPRESSUM.md", "DATENSCHUTZ.md", "NUTZUNGSBEDINGUNGEN.md", "KONTO-LOESCHEN.md")
TODAY = dt.date.today().strftime("%d.%m.%Y")
OPEN_KEYS = ("hoster", "hoster_ort", "telefon")       # in angaben.json noch leer
COMPANY = "IT solutions by Ahmad Fakih (Einzelunternehmen, Inhaber: Ahmad Fakih)"


def run(*args):
    p = subprocess.run([sys.executable, str(TOOL), *map(str, args)], capture_output=True, text=True, encoding="utf-8",
                       cwd=ROOT, timeout=60)
    return p.returncode, p.stdout + p.stderr


def _merge(data: dict, changes: dict) -> dict:
    for k, v in changes.items():
        if isinstance(v, dict) and isinstance(data.get(k), dict):
            data[k].update(v)
        else:
            data[k] = v
    return data


def example(**changes) -> dict:
    return _merge(json.loads(EXAMPLE.read_text(encoding="utf-8")), changes)


def angaben(**changes) -> dict:
    """Echte Angaben, die noch leeren Werte (Hoster, Telefon) mit den Beispielwerten der Vorlage ergaenzt."""
    data = json.loads(ANGABEN.read_text(encoding="utf-8"))
    ex = json.loads(EXAMPLE.read_text(encoding="utf-8"))
    for k in OPEN_KEYS:
        if not data.get(k):
            data[k] = ex[k]
    return _merge(data, changes)


def write_json(tmp_path, data, name="angaben.json") -> Path:
    p = tmp_path / name
    p.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    return p


@pytest.fixture(scope="module")
def filled(tmp_path_factory):
    out = tmp_path_factory.mktemp("rechtstexte")
    code, log = run(write_json(out.parent, angaben(), "vollstaendig.json"), "--out", out)
    assert code == 0, log
    return out, log


def test_example_json_is_a_template_with_hints():
    data = json.loads(EXAMPLE.read_text(encoding="utf-8"))
    assert "_hinweis" in data and "Beispiel" in json.dumps(data["_hinweis"], ensure_ascii=False)
    assert data["name"] == "Max Beispiel" and data["domain"].endswith("beispiel.de") and "Beispielstraße" in data["strasse"]
    assert data["datum"] == "" and data["ustid"] == "" and data["kleinunternehmer"] is True
    assert set(data["funktionen"]) - {"_hinweis"} == {"ipad_hildesheim", "ipad_fristen", "ipad_skriptsuche",
                                                      "ipad_community_online", "android_karteikarten", "android_community",
                                                      "ipad_hsh"}


def test_angaben_json_holds_the_owner_values_and_leaves_hosting_open():
    data = json.loads(ANGABEN.read_text(encoding="utf-8"))
    assert data["name"] == COMPANY and data["strasse"] == "Baldurstraße 5" and data["plz_ort"] == "30657 Hannover"
    assert data["email"] == "support@studinow.app" and data["domain"] == "studinow.app" and data["datum"] == "03.11.2026"
    assert data["ustid"] == "DE462836430" and data["kleinunternehmer"] is False and data["unternehmen"]["firma"] == ""
    assert "Niedersachsen" in data["aufsichtsbehoerde"] and data["antwortfrist"] == "7 Tagen"
    for k in OPEN_KEYS:
        assert data[k] == "", f"{k}: nicht erfinden (docs/release/README.md)"
    assert set(data["funktionen"]) - {"_hinweis"} == set(json.loads(EXAMPLE.read_text(encoding="utf-8"))["funktionen"]) - {"_hinweis"}


def test_sources_are_filled_except_hosting_phone_switches_and_notes():
    """Die Rechtstexte tragen die Firmenangaben; offen sind nur die Platzhalter, deren Werte fehlen."""
    for name in LEGAL:
        text = (REL / name).read_text(encoding="utf-8")
        assert "support@studinow.app" in text and "Entwurf" in text and "26.10.2026" in text, name
        assert "[[Name]]" not in text and "[[E-Mail]]" not in text and "[[Domain]]" not in text and "[[Datum]]" not in text, name
    ds = (REL / "DATENSCHUTZ.md").read_text(encoding="utf-8")
    assert set(re.findall(r"\[\[([^\]]+)\]\]", ds)) == {"Hoster", "Serverstandort"}
    for name in ("IMPRESSUM.md", "NUTZUNGSBEDINGUNGEN.md", "KONTO-LOESCHEN.md"):
        assert "[[" not in (REL / name).read_text(encoding="utf-8"), name
    im = (REL / "IMPRESSUM.md").read_text(encoding="utf-8")
    assert "Baldurstraße 5<br>\n30657 Hannover<br>\nDeutschland" in im and "USt-IdNr. nach § 27a UStG: DE462836430" in im
    assert "Verantwortlich für den Inhalt nach § 18 Abs. 2 MStV" in im and "Variante" not in im
    # Nutzungsbedingungen 04.11.2026: drei Tarife, Probe wie Pro AI, Grenzen je Tarif (Abschnitt 5a)
    # 05.11.2026: Konto- und Abo-Pflicht in Web und Windows, Abschluss ueber Stripe (Datenschutz 5, 9, 12; Bedingungen 5)
    # 06.11.2026: Datenschutz passend zu Build 10 (StudiNow-Konto auf dem iPad, Kaufmeldung an den Dienst, HsH-Systeme)
    # 07.11.2026: Bedingungen mit Jahresabos (Plus 21,99 €, Pro AI 41,99 €); Datenschutz 8a mit "Eigenes ChatGPT" ueber
    # den eigenen OpenAI-Schluessel (nur Schluesselbund des iPads, Anfragen direkt an OpenAI, KI-Lernplan ohne Namen)
    nb = (REL / "NUTZUNGSBEDINGUNGEN.md").read_text(encoding="utf-8")
    assert "Stand 07.11.2026 (26.10.2026)" in ds and "Stand 07.11.2026 (26.10.2026)" in nb
    assert "Eigenes ChatGPT mit deinem OpenAI-Schlüssel" in ds and "nur im Schlüsselbund dieses iPads" in ds
    assert "direkt von deinem Gerät an die OpenAI-Schnittstelle" in ds and "KI-Lernplan" in ds and "KI-Lernplan" in nb
    site = (ROOT / "site" / "datenschutz.html").read_text(encoding="utf-8")
    assert "Stand 07.11.2026 (26.10.2026)" in site and "Eigenes ChatGPT mit deinem OpenAI-Schlüssel" in site
    assert "21,99 € pro Jahr" in nb and "41,99 € pro Jahr" in nb and "einen Monat bzw. ein Jahr" in nb
    pl = (REL / "PLAY-STORE.md").read_text(encoding="utf-8")
    assert "[[Telefon]]" in pl and "E-Mail support@studinow.app" in pl


def test_check_with_owner_values_lists_only_what_is_open_and_exits_1():
    code, log = run(ANGABEN, "--check")
    assert code == 1
    for name in ("IMPRESSUM.md", "NUTZUNGSBEDINGUNGEN.md", "KONTO-LOESCHEN.md"):
        assert f"{name}: keine offenen Platzhalter" in log, name
    assert "DATENSCHUTZ.md: 2 offen" in log
    assert "[[Hoster]]  -> hoster" in log and "[[Serverstandort]]  -> hoster_ort" in log
    assert "[[Telefon]]  -> telefon" in log
    # APP-STORE.md ist seit 06.11.2026 fertig zum Einfuegen (keine Schalter, keine Pruefhinweise mehr)
    assert "APP-STORE.md: keine offenen Platzhalter" in log
    assert "[[• Eigene Karteikarten mit Wiederholung (Plus)]]  -> funktionen.android_karteikarten (faellt weg)" in log
    assert "Google-Dokumentation zum Zeitpunkt der Einreichung abgleichen, ob die Sitzungs-Cookies anzugeben sind.]]  -> Pruefhinweis, wird entfernt" in log
    assert "[[Name]]" not in log and "[[E-Mail]]" not in log and "[[Domain]]" not in log and "[[Datum]]" not in log
    assert "UNBEKANNT" not in log, "jeder Platzhalter in docs/release ist dem Werkzeug bekannt"
    for k in OPEN_KEYS:
        assert f"{k}: leer" in log, k
    assert re.search(r"\n\d+ Platzhalter offen", log)
    # --check schreibt nichts
    assert "[[Hoster]]" in (REL / "DATENSCHUTZ.md").read_text(encoding="utf-8")


def test_fill_into_out_dir_leaves_sources_untouched_and_no_placeholders(filled):
    out, log = filled
    assert sorted(p.name for p in out.iterdir()) == sorted(FILES)
    for name in FILES:
        text = (out / name).read_text(encoding="utf-8")
        assert "[[" not in text and "]]" not in text, name
        for word in ("TODO", "TBD", "XXX"):
            assert word not in text, (name, word)
        assert "Entwurf" in text and "26.10.2026" in text, "Vorbehalt der Vorlage bleibt (tests/test_release_texts.py)"
    # Quelle unveraendert: dort stehen die offenen Platzhalter noch
    assert "[[Hoster]]" in (REL / "DATENSCHUTZ.md").read_text(encoding="utf-8")
    assert "Dateien geschrieben" in log and "Datum: heute" not in log, "datum steht fest in angaben.json"


def test_hosting_and_phone_values_are_inserted_and_owner_data_stays(filled):
    out, _ = filled
    ds = (out / "DATENSCHUTZ.md").read_text(encoding="utf-8")
    assert "läuft bei Beispiel-Hosting GmbH, Serverstandort Beispielstadt, Deutschland" in ds and "versendet\nSTRATO GmbH, Otto-Ostrowski-Straße 7, 10249 Berlin (Deutschland)" in ds
    assert "IT solutions by Ahmad Fakih (Einzelunternehmen, Inhaber: Ahmad Fakih), Baldurstraße 5, 30657 Hannover, Deutschland,\nE-Mail: support@studinow.app" in ds
    assert "Behörde: Die Landesbeauftragte für den\nDatenschutz Niedersachsen, Prinzenstraße 5, 30159 Hannover." in ds
    assert "gibt es nicht, weil die\ngesetzlichen Voraussetzungen dafür nicht vorliegen." in ds and "Falls doch benannt" not in ds
    nb = (out / "NUTZUNGSBEDINGUNGEN.md").read_text(encoding="utf-8")
    assert "Anbieter ist IT solutions by Ahmad Fakih (Einzelunternehmen, Inhaber: Ahmad Fakih),\nBaldurstraße 5, 30657 Hannover, E-Mail support@studinow.app" in nb
    assert "`https://studinow.app/datenschutz`" in ds and "`https://studinow.app/impressum`" in nb
    assert "Anwaltlich prüfen" not in nb and "digitaler Inhalte.\n" in nb and "soweit gesetzlich zulässig.\n" in nb
    kl = (out / "KONTO-LOESCHEN.md").read_text(encoding="utf-8")
    assert "innerhalb von 7 Tagen" in kl and "an support@studinow.app" in kl
    pl = (out / "PLAY-STORE.md").read_text(encoding="utf-8")
    assert "E-Mail support@studinow.app, Telefon +49 170 0000000, Website `https://studinow.app`" in pl


def test_impressum_keeps_the_sole_trader_block_and_ust_line(filled):
    out, _ = filled
    im = (out / "IMPRESSUM.md").read_text(encoding="utf-8")
    assert im.startswith("# Impressum\n") and "## Angaben nach § 5 DDG" in im and "## Weitere Angaben" in im
    assert "IT solutions by Ahmad Fakih<br>\nEinzelunternehmen, Inhaber: Ahmad Fakih<br>\nBaldurstraße 5<br>\n30657 Hannover<br>\nDeutschland" in im
    assert "E-Mail: support@studinow.app" in im and "Telefon" not in im
    assert "**Umsatzsteuer**<br>\nUSt-IdNr. nach § 27a UStG: DE462836430\n\n**Verantwortlich für den Inhalt nach § 18 Abs. 2 MStV**<br>\nAhmad Fakih, Anschrift wie oben" in im
    assert "Variante" not in im and "Kleinunternehmer" not in im and "Registergericht" not in im and "*oder*" not in im
    assert im == (REL / "IMPRESSUM.md").read_text(encoding="utf-8"), "ohne offene Platzhalter aendert das Werkzeug nichts"


FEATURE_SWITCHES = ("ipad_hildesheim", "ipad_fristen", "ipad_skriptsuche", "ipad_community_online",
                    "android_karteikarten", "android_community", "ipad_hsh")


def test_angaben_switch_on_hildesheim_and_hsh():
    """Wunsch des Inhabers 05.11.2026: alle angebundenen Hochschulen bewerben (Hildesheim und Hochschule Hannover)."""
    f = json.loads(ANGABEN.read_text(encoding="utf-8"))["funktionen"]
    assert f["ipad_hildesheim"] is True and f["ipad_hsh"] is True
    assert not any(f[k] for k in FEATURE_SWITCHES if k not in ("ipad_hildesheim", "ipad_hsh"))


def test_store_texts_drop_optional_sentences_when_switches_are_false(tmp_path):
    out = tmp_path / "out"
    code, log = run(write_json(tmp_path, angaben(funktionen={k: False for k in FEATURE_SWITCHES})), "--out", out)
    assert code == 0, log
    # APP-STORE.md hat seit 06.11.2026 keine Schalter mehr: das Werkzeug laesst die Datei unveraendert, auch mit allen
    # Schaltern aus (Hochschulen, die nicht laufen, streicht der Inhaber von Hand, Tabelle in APP-STORE.md)
    ap = (out / "APP-STORE.md").read_text(encoding="utf-8")
    assert ap == (REL / "APP-STORE.md").read_text(encoding="utf-8")
    desc = ap.split("```text description\n")[1].split("```")[0]
    assert "Hochschule Hannover (Moodle, HISinOne, QIS) und Universität Hildesheim (Learnweb, LSF, PLuS)" in desc
    assert "• Speiseplan deiner Mensa" in desc
    assert "Nutzungsbedingungen: https://studinow.app/nutzungsbedingungen" in ap and "Datenschutz: https://studinow.app/datenschutz" in ap
    assert "© 2026 IT solutions by Ahmad Fakih" in ap and "`https://studinow.app/support` (Kontakt per E-Mail support@studinow.app)" in ap
    assert "STUDINOW FREE UND PLUS" in ap and "STUDORA" not in ap
    pl = (out / "PLAY-STORE.md").read_text(encoding="utf-8")
    full = pl.split("```text full")[1].split("```")[0]
    assert "Karteikarten" not in full and "STUDINOW FREE UND PLUS" in full and "UNIFLOW" not in full
    assert "mit dem Stift frei. Das Abo" in pl and "Abgleich zwischen deinen Geräten" not in pl and "erste Woche gratis" not in pl and "der eingereicht wird.\n" in pl and "Google-Dokumentation" not in pl
    # Feldlaengen bleiben innerhalb der Store-Grenzen (Schalter koennen den Text nur kuerzen)
    assert len(desc) <= 4000 and "[[" not in desc


def test_switches_true_keep_the_optional_sentences(tmp_path):
    data = angaben(funktionen={k: True for k in ("ipad_hildesheim", "ipad_fristen", "ipad_skriptsuche",
                                                 "ipad_community_online", "android_karteikarten", "android_community", "ipad_hsh")})
    out = tmp_path / "out"
    code, log = run(write_json(tmp_path, data), "--out", out)
    assert code == 0, log
    ap = (out / "APP-STORE.md").read_text(encoding="utf-8")
    assert ap == (REL / "APP-STORE.md").read_text(encoding="utf-8"), "APP-STORE.md hat keine Schalter mehr (06.11.2026)"
    pl = (out / "PLAY-STORE.md").read_text(encoding="utf-8")
    assert "• Eigene Karteikarten mit Wiederholung (Plus)\n" in pl and "frei, dazu Karteikarten und das Teilen von Lösungen." in pl
    assert "[[" not in ap and "[[" not in pl


def test_filling_twice_changes_nothing(filled, tmp_path):
    """Gefuellte Texte sind ein Fixpunkt des Werkzeugs: ein zweiter Lauf schreibt dieselben Dateien."""
    out, _ = filled
    again = tmp_path / "again"
    code, log = run(write_json(tmp_path, angaben()), "--src", out, "--out", again)
    assert code == 0, log
    for name in FILES:
        assert (again / name).read_text(encoding="utf-8") == (out / name).read_text(encoding="utf-8"), name


def test_check_on_filled_dir_exits_0(filled, tmp_path):
    out, _ = filled
    code, log = run(write_json(tmp_path, angaben()), "--check", "--src", out)
    assert code == 0, log
    assert "Alles ausgefuellt" in log and "keine offenen Platzhalter" in log


def test_empty_value_is_an_error_with_name_and_nothing_written(tmp_path):
    out = tmp_path / "out"
    code, log = run(write_json(tmp_path, example(email="", hoster=" ")), "--out", out)
    assert code == 1 and "email: leer" in log and "hoster: leer" in log and "nichts geschrieben" in log
    assert not out.exists()
    code, log = run(write_json(tmp_path, example(email=""), "b.json"), "--check")
    assert code == 1 and "email: leer" in log


def test_missing_key_wrong_date_bad_domain_and_ust_rule(tmp_path):
    data = example(datum="2026-11-01", domain="https://app.beispiel.de/", ustid="", kleinunternehmer=False)
    del data["telefon"]
    code, log = run(write_json(tmp_path, data), "--check")
    assert code == 1
    assert "telefon: fehlt" in log and "datum: '2026-11-01'" in log and "ustid: leer und kleinunternehmer" in log
    assert "domain:" not in log, "https:// und Schlussstrich werden abgestreift"
    code, log = run(write_json(tmp_path, example(domain="kein hostname"), "c.json"), "--check")
    assert code == 1 and "domain: 'kein hostname' ist kein Hostname" in log
    code, log = run(write_json(tmp_path, example(unternehmen={"firma": "Beispiel"}), "d.json"), "--check")
    assert code == 1 and "unternehmen.rechtsform: leer" in log and "unternehmen.registernummer: leer" in log


def test_unknown_placeholder_is_reported_and_blocks_writing(tmp_path):
    src = tmp_path / "src"
    shutil.copytree(REL, src, ignore=shutil.ignore_patterns("*.json"))
    p = src / "KONTO-LOESCHEN.md"
    p.write_text(p.read_text(encoding="utf-8") + "\nNeu: [[Noch ein Wert]]\n", encoding="utf-8")
    out = tmp_path / "out"
    code, log = run(EXAMPLE, "--src", src, "--out", out)
    assert code == 1 and "unbekannter Platzhalter [[Noch ein Wert]]" in log and not out.exists()
    code, log = run(EXAMPLE, "--check", "--src", src)
    assert code == 1 and "[[Noch ein Wert]]  -> UNBEKANNT" in log


def test_in_place_fill_rewrites_the_source_dir(tmp_path):
    src = tmp_path / "release"
    shutil.copytree(REL, src, ignore=shutil.ignore_patterns("*.json"))
    code, log = run(write_json(tmp_path, angaben()), "--src", src)
    assert code == 0 and "(an Ort und Stelle)" in log, log
    for name in FILES:
        assert "[[" not in (src / name).read_text(encoding="utf-8"), name
    assert "[[Domain]]" in (src / "README.md").read_text(encoding="utf-8"), "README und BETRIEB bleiben unberuehrt"
    assert "[[Hoster]]" in (src / "BETRIEB.md").read_text(encoding="utf-8")


def test_service_renders_filled_pages_without_todo_marks(filled, monkeypatch):
    """app/legal.py liest die Dateien aus LERNAPP_LEGAL_DIR: mit dem gefuellten Ordner gibt es keine gelben Marken mehr."""
    out, _ = filled
    monkeypatch.setenv("LERNAPP_LEGAL_DIR", str(out))
    from app import legal
    for page in legal.PAGES:
        title, html = legal.render(page, hosted=True)
        assert 'class="todo"' not in html and "noch auszufüllen" not in html, page
        assert "[[" not in html
    assert legal.render("impressum", hosted=True)[0] == "Impressum"
    assert 'href="https://studinow.app/datenschutz"' in legal.render("impressum", hosted=True)[1]
