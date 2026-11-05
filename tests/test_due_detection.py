"""Fristen-Erkennung ohne KI (app/due_detection.py) gegen die gemeinsamen Faelle
packages/shared-contracts/fixtures/due-detection/cases.json (Erwartungen aus den Swift-Tests DueDetectionTests)."""
import json
from pathlib import Path

import pytest

from app import due_detection as D

FIX = json.loads((Path(__file__).resolve().parents[1] / "packages/shared-contracts/fixtures/due-detection/cases.json").read_text("utf-8"))


def _detect(c):
    w = D.Window.current(c["university"], D.parse_iso(c["today"]))
    assert w is not None
    text = D.name_text(c["text"]) if c.get("name_text") else c["text"]
    ref = D.parse_iso(c["reference"]) if c.get("reference") else None
    return D.detect(text, D.Context(w, reference=ref))


@pytest.mark.parametrize("c", FIX["detect"], ids=[f"{i}-{c['group']}" for i, c in enumerate(FIX["detect"])])
def test_detect_cases(c):
    hits = _detect(c)
    got = [h.summary() for h in hits]
    if "expect" in c:
        assert got == c["expect"], c["text"]
    if "count" in c:
        assert len(got) == c["count"]
    if "first" in c:
        assert got[0] == c["first"]
    if c.get("snippet_contains"):
        assert c["snippet_contains"] in hits[0].snippet, hits


@pytest.mark.parametrize("w", FIX["windows"])
def test_windows(w):
    got = D.Window.current(w["university"], D.parse_iso(w["today"]))
    if w.get("none"):
        assert got is None
        return
    assert sorted(str(s) for s in got.semesters) == sorted(w["semesters"])
    if "from" in w:
        assert D.iso(got.start) == w["from"] and D.iso(got.end) == w["to"]


def test_semester_mentions_and_head():
    for s in FIX["semesters"]:
        assert [str(k) for k in D.semesters(s["text"])] == s["expect"]
    for h in FIX["head_semester"]:
        got = D.head_semester(h["first_page"], h["name"])
        assert (str(got) if got else None) == h["expect"]
    for n in FIX["name_text"]:
        assert D.name_text(n["name"]) == n["expect"]


def test_term_extends_window_and_flags():
    # aktives Semester der App (terms) zaehlt mit; Loesungen: keine Tests/Klausuren, keine Daten ohne Jahr
    w = D.Window.current("unbekannt", D.parse_iso("2026-10-27"), ("WiSe 2026/27", "2026-10-12", "2027-01-30"))
    assert w is not None and D.iso(w.start) == "2026-09-21"
    ctx = D.Context(w, allow_exams=False, allow_yearless=False)
    assert D.detect("Klausur am 10.02.2027", ctx) == []
    assert D.detect("Abgabe bis 03.11.", ctx) == []
    assert [h.summary() for h in D.detect("Abgabe bis 03.11.2026", ctx)] == ["2026-11-03 abgabe Abgabe"]
