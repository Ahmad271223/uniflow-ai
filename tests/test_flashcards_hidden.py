"""Versteckte Karteikarten (Trainer, 03.11.2026) sind nie faellig: `GET /api/flashcards?due=true` ("Heute faellig",
Zaehler auf Tests/Dashboard) laesst sie weg, die Liste ohne due zeigt sie weiter. Fach und Termin bleiben."""
import json
import subprocess
import sys
from pathlib import Path

from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]


def _get(app, path):
    st, _, raw = asgi_call(app, "GET", path)
    assert st == 200, raw[:200]
    return json.loads(raw)


def test_hidden_card_is_not_due_but_listed(app):
    from app import db
    with db.cursor() as conn:
        ids = [conn.execute("INSERT INTO flashcards(question, answer, created_at, box, due, hidden) VALUES (?, 'a', '2026-10-26', 1, '2000-01-01', ?)",
                            (q, h)).lastrowid for q, h in (("sichtbar", 0), ("versteckt", 1), ("alt ohne Wert", None))]
    due = {c["question"] for c in _get(app, "/api/flashcards?due=true")}
    assert {"sichtbar", "alt ohne Wert"} <= due and "versteckt" not in due
    listed = {c["question"]: c for c in _get(app, "/api/flashcards")}
    assert listed["versteckt"]["hidden"] == 1 and listed["versteckt"]["due"] == "2000-01-01"

    st, _, _ = asgi_call(app, "PATCH", f"/api/flashcards/{ids[1]}", body=json.dumps({"hidden": False}))
    assert st == 200
    assert "versteckt" in {c["question"] for c in _get(app, "/api/flashcards?due=true")}, "wieder gezeigt: wieder faellig"
    with db.cursor() as conn:
        conn.execute(f"DELETE FROM flashcards WHERE id IN ({','.join('?' * len(ids))})", ids)


def test_flashcards_fixture_is_current():
    r = subprocess.run([sys.executable, "tools/gen-flashcards-fixture.py", "--check"], cwd=ROOT, capture_output=True, text=True,
                       encoding="utf-8", timeout=300)
    assert r.returncode == 0, f"python tools/gen-flashcards-fixture.py neu ausfuehren\n{r.stdout}\n{r.stderr}"
