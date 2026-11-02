"""tools/rechtstexte-fuellen.py: fuellt die Platzhalter der Rechts- und Store-Texte aus einer JSON; --check meldet offene
Stellen (Exit 1); leere Werte und unbekannte Platzhalter sind Fehler; nach dem Fuellen bleibt kein [[ und kein TODO."""
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
FILES = ("IMPRESSUM.md", "DATENSCHUTZ.md", "NUTZUNGSBEDINGUNGEN.md", "KONTO-LOESCHEN.md", "APP-STORE.md", "PLAY-STORE.md")
TODAY = dt.date.today().strftime("%d.%m.%Y")


def run(*args):
    p = subprocess.run([sys.executable, str(TOOL), *map(str, args)], capture_output=True, text=True, encoding="utf-8",
                       cwd=ROOT, timeout=60)
    return p.returncode, p.stdout + p.stderr


def example(**changes) -> dict:
    data = json.loads(EXAMPLE.read_text(encoding="utf-8"))
    for k, v in changes.items():
        if isinstance(v, dict) and isinstance(data.get(k), dict):
            data[k].update(v)
        else:
            data[k] = v
    return data


def write_json(tmp_path, data, name="angaben.json") -> Path:
    p = tmp_path / name
    p.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    return p


@pytest.fixture(scope="module")
def filled(tmp_path_factory):
    out = tmp_path_factory.mktemp("rechtstexte")
    code, log = run(EXAMPLE, "--out", out)
    assert code == 0, log
    return out, log


def test_example_json_is_a_template_with_hints():
    data = json.loads(EXAMPLE.read_text(encoding="utf-8"))
    assert "_hinweis" in data and "Beispiel" in json.dumps(data["_hinweis"], ensure_ascii=False)
    assert data["name"] == "Max Beispiel" and data["domain"].endswith("beispiel.de") and "Beispielstraße" in data["strasse"]
    assert data["datum"] == "" and data["ustid"] == "" and data["kleinunternehmer"] is True
    assert set(data["funktionen"]) - {"_hinweis"} == {"ipad_hildesheim", "ipad_fristen", "ipad_skriptsuche",
                                                      "ipad_community_online", "android_karteikarten", "android_community"}


def test_fill_into_out_dir_leaves_sources_untouched_and_no_placeholders(filled):
    out, log = filled
    assert sorted(p.name for p in out.iterdir()) == sorted(FILES)
    for name in FILES:
        text = (out / name).read_text(encoding="utf-8")
        assert "[[" not in text and "]]" not in text, name
        for word in ("TODO", "TBD", "XXX"):
            assert word not in text, (name, word)
        assert "Entwurf" in text and "26.10.2026" in text, "Vorbehalt der Vorlage bleibt (tests/test_release_texts.py)"
    # Quelle unveraendert: dort stehen die Platzhalter noch
    assert "[[Name]]" in (REL / "IMPRESSUM.md").read_text(encoding="utf-8")
    assert "Dateien geschrieben" in log and "Datum: heute" in log


def test_values_and_today_are_inserted(filled):
    out, _ = filled
    ds = (out / "DATENSCHUTZ.md").read_text(encoding="utf-8")
    nb = (out / "NUTZUNGSBEDINGUNGEN.md").read_text(encoding="utf-8")
    assert f"Stand {TODAY} (26.10.2026)" in ds and f"Stand {TODAY} (26.10.2026)" in nb
    assert "Max Beispiel, Beispielstraße 1, 12345 Beispielstadt, E-Mail: hallo@beispiel.de" in ds
    assert "Anbieter ist Max Beispiel, Beispielstraße 1, 12345 Beispielstadt, E-Mail hallo@beispiel.de" in nb
    assert "läuft bei Beispiel-Hosting GmbH, Serverstandort Beispielstadt, Deutschland" in ds and "versendet\nBeispiel-Mail GmbH, Deutschland" in ds
    assert "Behörde: Die Landesbeauftragte für den Datenschutz Niedersachsen, Prinzenstraße 5, 30159 Hannover." in ds
    assert "gibt es nicht, weil die gesetzlichen Voraussetzungen dafür nicht vorliegen." in ds and "Falls doch benannt" not in ds
    assert "`https://app.beispiel.de/datenschutz`" in ds and "`https://app.beispiel.de/impressum`" in nb
    assert "Anwaltlich prüfen" not in nb and "digitaler Inhalte.\n" in nb and "soweit gesetzlich zulässig.\n" in nb
    kl = (out / "KONTO-LOESCHEN.md").read_text(encoding="utf-8")
    assert "innerhalb von 7 Tagen" in kl and "an hallo@beispiel.de" in kl


def test_impressum_takes_variant_a_for_a_natural_person(filled):
    out, _ = filled
    im = (out / "IMPRESSUM.md").read_text(encoding="utf-8")
    assert im.startswith("# Impressum\n") and "Vorlage" not in im.splitlines()[0]
    assert "## Angaben nach § 5 DDG" in im and "Variante" not in im and "## Weitere Angaben" in im
    assert "**Anbieter**\nMax Beispiel\nBeispielstraße 1\n12345 Beispielstadt\nDeutschland" in im
    assert "E-Mail: hallo@beispiel.de\nTelefon: +49 170 0000000 (zweiter" in im
    assert "**Umsatzsteuer**\nKleinunternehmer nach § 19 UStG, keine USt-IdNr.\n\n## Weitere Angaben" in im
    assert "Vertreten durch" not in im and "Registergericht" not in im and "*oder*" not in im


def test_store_texts_drop_optional_sentences_when_switches_are_false(filled):
    out, _ = filled
    ap = (out / "APP-STORE.md").read_text(encoding="utf-8")
    assert "FÜR STUDIERENDE DER LEIBNIZ UNIVERSITÄT HANNOVER\n" in ap and "HILDESHEIM\n" not in ap.split("```text description")[1].split("```")[0]
    assert "bei Stud.IP an." in ap and "Übungstermine. Deine Zugangsdaten" in ap
    assert "Quiz-Termine" not in ap and "Skriptsuche zur Aufgabe" not in ap.split("```text description")[1].split("```")[0]
    assert "nebeneinander\n" in ap and "dieselbe PDF hat\n" in ap
    assert "Nutzungsbedingungen: https://app.beispiel.de/nutzungsbedingungen" in ap and "Datenschutz: https://app.beispiel.de/datenschutz" in ap
    assert f"© {TODAY[-4:]} Max Beispiel" in ap and "`https://app.beispiel.de/support` (Kontakt per E-Mail hallo@beispiel.de)" in ap
    assert "gespeichert werden.\n" in ap and "Apple-Dokumentation" not in ap
    pl = (out / "PLAY-STORE.md").read_text(encoding="utf-8")
    assert "Karteikarten" not in pl.split("```text full")[1].split("```")[0]
    assert "Geräten frei. Das Abo" in pl and "der eingereicht wird.\n" in pl and "Google-Dokumentation" not in pl
    assert "E-Mail hallo@beispiel.de, Telefon +49 170 0000000, Website `https://app.beispiel.de`" in pl
    # Feldlaengen bleiben innerhalb der Store-Grenzen (Schalter koennen den Text nur kuerzen)
    desc = re.search(r"```text description\n(.*?)\n```", ap, re.S).group(1)
    assert len(desc) <= 4000 and "[[" not in desc


def test_switches_true_keep_the_optional_sentences(tmp_path):
    data = example(funktionen={k: True for k in ("ipad_hildesheim", "ipad_fristen", "ipad_skriptsuche",
                                                 "ipad_community_online", "android_karteikarten", "android_community")})
    out = tmp_path / "out"
    code, log = run(write_json(tmp_path, data), "--out", out)
    assert code == 0, log
    ap = (out / "APP-STORE.md").read_text(encoding="utf-8")
    assert "HANNOVER UND DER UNIVERSITÄT HILDESHEIM" in ap and "Stud.IP bzw. Learnweb an" in ap
    assert "• Abgabefristen, Quiz-Termine, Feiertage und vorlesungsfreie Zeit auf einen Blick\n" in ap
    assert "nebeneinander, mit Skriptsuche zur Aufgabe" in ap and "; später online in der Community deines Kurses, unter Pseudonym" in ap
    pl = (out / "PLAY-STORE.md").read_text(encoding="utf-8")
    assert "• Eigene Karteikarten mit Wiederholung (Plus)\n" in pl and "frei, dazu Karteikarten und das Teilen von Lösungen." in pl
    assert "[[" not in ap and "[[" not in pl


def test_legal_entity_takes_variant_b_with_ustid(tmp_path):
    data = example(ustid="DE123456789", kleinunternehmer=False, datenschutzbeauftragter="Erika Beispiel, dsb@beispiel.de",
                   email_datenschutz="datenschutz@beispiel.de", datum="15.11.2026",
                   unternehmen={"firma": "Beispiel", "rechtsform": "UG (haftungsbeschränkt)", "vertreten_durch": "Max Beispiel",
                                "registergericht": "Amtsgericht Beispielstadt", "registernummer": "HRB 12345"})
    out = tmp_path / "out"
    code, log = run(write_json(tmp_path, data), "--out", out)
    assert code == 0, log
    im = (out / "IMPRESSUM.md").read_text(encoding="utf-8")
    assert "**Anbieter**\nBeispiel UG (haftungsbeschränkt)\nBeispielstraße 1\n12345 Beispielstadt" in im
    assert "**Vertreten durch**\nMax Beispiel" in im and "Registergericht: Amtsgericht Beispielstadt\nRegisternummer: HRB 12345" in im
    assert "**Umsatzsteuer**\nUSt-IdNr. nach § 27a UStG: DE123456789\n" in im and "Kleinunternehmer" not in im
    assert "natürliche Person" not in im and "[[" not in im
    ds = (out / "DATENSCHUTZ.md").read_text(encoding="utf-8")
    assert "Datenschutzbeauftragte/r: Erika Beispiel, dsb@beispiel.de." in ds and "Datenschutzbeauftragten gibt es nicht" not in ds
    assert "E-Mail: datenschutz@beispiel.de" in ds and "hallo@beispiel.de" not in ds, "email_datenschutz nur in der Datenschutzerklärung"
    assert "hallo@beispiel.de" in (out / "IMPRESSUM.md").read_text(encoding="utf-8")
    assert "Stand 15.11.2026 (26.10.2026)" in ds and "© 2026 Beispiel" not in (out / "APP-STORE.md").read_text(encoding="utf-8")
    assert "© 2026 Max Beispiel" in (out / "APP-STORE.md").read_text(encoding="utf-8")


def test_check_on_docs_release_lists_open_placeholders_and_exits_1():
    code, log = run(EXAMPLE, "--check")
    assert code == 1
    for name in FILES:
        assert f"{name}:" in log
    assert "[[Domain]]  -> domain (https://...)" in log and "[[E-Mail]]  -> email" in log and "[[Anschrift]]  -> strasse + plz_ort" in log
    assert f"[[Datum]]  -> datum (heute: {TODAY})" in log and "[[Jahr]]  -> datum (Jahr)" in log
    assert "[[ UND DER UNIVERSITÄT HILDESHEIM]]  -> funktionen.ipad_hildesheim (faellt weg)" in log
    assert "[[Anwaltlich prüfen.]]  -> Pruefhinweis, wird entfernt" in log
    assert "UNBEKANNT" not in log, "jeder Platzhalter in docs/release ist dem Werkzeug bekannt"
    assert "Werte in der JSON: vollstaendig" in log and re.search(r"\n\d+ Platzhalter offen", log)
    # --check schreibt nichts
    assert "[[Name]]" in (REL / "IMPRESSUM.md").read_text(encoding="utf-8")


def test_check_on_filled_dir_exits_0(filled):
    out, _ = filled
    code, log = run(EXAMPLE, "--check", "--src", out)
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
    code, log = run(EXAMPLE, "--src", src)
    assert code == 0 and "(an Ort und Stelle)" in log, log
    for name in FILES:
        assert "[[" not in (src / name).read_text(encoding="utf-8"), name
    assert "[[Domain]]" in (src / "README.md").read_text(encoding="utf-8"), "README und BETRIEB bleiben unberuehrt"
    assert "[[Hosting-Anbieter]]" in (src / "BETRIEB.md").read_text(encoding="utf-8")


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
    assert "https://app.beispiel.de/datenschutz" in legal.render("impressum", hosted=True)[1]
