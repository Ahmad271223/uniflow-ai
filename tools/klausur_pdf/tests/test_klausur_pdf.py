"""Tests für tools/klausur_pdf. Start: cd tools/klausur_pdf && python -m pytest tests -q"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

HIER = Path(__file__).resolve().parent
sys.path.insert(0, str(HIER.parent))

pytest.importorskip("reportlab")

from klausur_pdf import EingabeFehler, aus_dict, lade_json, lade_markdown  # noqa: E402
from klausur_pdf.__main__ import main  # noqa: E402
from klausur_pdf.fonts import kann, registriere  # noqa: E402
from klausur_pdf.render import fett, schritt_markup  # noqa: E402


def _ist_pdf(p: Path) -> bool:
    return p.is_file() and p.stat().st_size > 1500 and p.read_bytes()[:5] == b"%PDF-"


def test_schrift_kann_mathezeichen():
    s = registriere()
    assert s.fehlend == "", f"Schrift {s.pfad} kann nicht: {s.fehlend}"


def test_json_build(tmp_path):
    assert main(["build", "--input", str(HIER / "beispiel.json"), "--out", str(tmp_path)]) == 0
    assert _ist_pdf(tmp_path / "Probeklausur-1-Aufgaben.pdf")
    assert _ist_pdf(tmp_path / "Probeklausur-1-Loesungen.pdf")


def test_markdown_parse():
    d = lade_markdown(HIER / "beispiel.md")
    assert d.titel == "Probeklausur 2" and d.meta["dauer"] == "30 Minuten"
    assert [a.nr for a in d.aufgaben] == ["1", "2", "3"]
    assert d.aufgaben[0].punkte == "2 + 2"
    assert [t.label for t in d.aufgaben[0].teile] == ["a", "b"]
    assert [l.nr for l in d.loesungen] == ["1", "2", "3"]
    assert d.loesungen[0].merke.startswith("cos")
    assert [t.ergebnis for t in d.loesungen[0].teile] == ["∠(x, y) = π/4", "Fläche = 3"]
    assert d.loesungen[1].teile[0].ergebnis == "d = √34/2"
    assert d.loesungen[2].wichtig.startswith("Beide")


def test_markdown_build(tmp_path):
    assert main(["from-markdown", "--input", str(HIER / "beispiel.md"), "--out", str(tmp_path)]) == 0
    assert _ist_pdf(tmp_path / "Probeklausur-2-Aufgaben.pdf")
    assert _ist_pdf(tmp_path / "Probeklausur-2-Loesungen.pdf")


def test_formelblatt(tmp_path):
    d = lade_markdown(HIER / "beispiel-formelblatt.md")
    assert len(d.formeln) == 3 and d.formeln[2].abschnitt == "Ebenen"
    assert d.formeln[0].hinweis.startswith("Ergebnis")
    assert main(["build", "--input", str(HIER / "beispiel-formelblatt.md"), "--out", str(tmp_path)]) == 0
    assert _ist_pdf(tmp_path / "Formelblatt-KK1.pdf")


def test_build_all(tmp_path):
    ordner = tmp_path / "04-Probeklausuren"
    ordner.mkdir()
    for n in ("beispiel.json", "beispiel.md"):
        (ordner / n).write_bytes((HIER / n).read_bytes())
    out = tmp_path / "pdf"
    assert main(["build-all", "--dir", str(ordner), "--out", str(out)]) == 0
    # beispiel.md hat dieselbe Basis wie beispiel.json → nur die JSON wird gebaut
    assert sorted(p.name for p in out.glob("*.pdf")) == ["Probeklausur-1-Aufgaben.pdf", "Probeklausur-1-Loesungen.pdf"]


def test_ungueltige_eingabe():
    with pytest.raises(EingabeFehler):
        aus_dict({"typ": "klausur", "fach": "X"})
    with pytest.raises(EingabeFehler):
        aus_dict({"typ": "quatsch", "fach": "X", "titel": "Y", "aufgaben": [{"nr": 1}]})
    d = json.loads((HIER / "beispiel.json").read_text(encoding="utf-8"))
    d["aufgaben"] = []
    with pytest.raises(EingabeFehler):
        aus_dict(d)


def test_json_lesbar():
    d = lade_json(HIER / "beispiel.json")
    assert d.loesungen[0].teile[1].ergebnis == "t = 3/2 oder t = −15/2"


def test_fettdruck_mischt_schriften():
    s = registriere()
    if s.titel == s.normal:
        pytest.skip("keine Fettschrift auf diesem Rechner")
    auf = f'<font name="{s.titel}">'
    # Text, den die Fettschrift ganz kann: ein einziger fetter Lauf
    assert fett("Schritt 1:") == f"{auf}Schritt 1:</font>"
    assert fett("a &amp; b") == f"{auf}a &amp; b</font>"
    # Tags bleiben stehen, der Text davor und danach ist fett
    assert fett("eins<br/>zwei") == f"{auf}eins</font><br/>{auf}zwei</font>"
    # Zeichen, die der Fettschrift fehlen, bleiben in der Grundschrift; der Rest ist fett
    fehlt = next((z for z in "∠ℝ∈₀▶" if not kann(s.titel, z)), None)
    if fehlt:
        assert fett(f"x {fehlt} y") == f"{auf}x </font>{fehlt}{auf} y</font>"


def test_schritt_nummer_nicht_doppelt():
    ohne_tags = lambda t: __import__("re").sub(r"<[^>]+>", "", t)  # noqa: E731
    assert ohne_tags(schritt_markup("a = 2", 3)) == "Schritt 3: a = 2"
    assert ohne_tags(schritt_markup("Schritt 1: a = 2", 3)) == "Schritt 1: a = 2"
    assert ohne_tags(schritt_markup("**Schritt 1:** a = 2", 3)) == "Schritt 1: a = 2"
    # die Nummer ist in allen drei Fällen hervorgehoben
    for zeile in ("a = 2", "Schritt 1: a = 2", "**Schritt 1:** a = 2"):
        assert schritt_markup(zeile, 1).startswith(("<font", "<b>"))
