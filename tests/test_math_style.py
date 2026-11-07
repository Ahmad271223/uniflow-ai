"""Mathematik in KI-Antworten (07.11.2026): jeder System-Prompt des Dienstes enthaelt die gemeinsame Formel-Anweisung
(app/math_style.py), damit die App Formeln in richtigen Zeichen zeigen kann (Kern: MathText.swift)."""
import ast
from pathlib import Path

from app import math_style

ROOT = Path(__file__).resolve().parents[1]


def _system_constants():
    """Alle Konstanten *SYSTEM in app/*.py, die als KI-Systemprompt dienen (nicht die Absender-Marken von Stud.IP)."""
    import importlib
    found = []
    for path in sorted((ROOT / "app").glob("*.py")):
        tree = ast.parse(path.read_text(encoding="utf-8"))
        for node in tree.body:
            if isinstance(node, ast.Assign):
                for t in node.targets:
                    if isinstance(t, ast.Name) and t.id.endswith("SYSTEM") and t.id != "SYSTEM_SENDER":
                        mod = importlib.import_module(f"app.{path.stem}")
                        found.append((f"{path.stem}.{t.id}", getattr(mod, t.id)))
    return found


def test_alle_system_prompts_haben_die_formel_anweisung():
    found = _system_constants()
    names = {n for n, _ in found}
    # die bekannten Prompts muessen dabei sein (sonst findet der Test nichts mehr)
    assert {"ai.SYSTEM", "ai.TUTOR_SYSTEM", "doc_explain.SYSTEM", "doc_index.SYSTEM", "weekly.SYSTEM",
            "week_library.SYSTEM", "library_api.GEN_SYSTEM"} <= names
    for name, text in found:
        assert math_style.MATH_RULES in text, name
        assert math_style.MATH_STYLE in text or math_style.MATH_STYLE_JSON in text, name
        assert "Formeln als Text" not in text, name


def test_markdown_mit_latex_json_ohne_backslash():
    from app import ai, doc_explain
    assert "$...$" in math_style.MATH_STYLE and "LaTeX" in math_style.MATH_STYLE
    assert "\\" not in math_style.MATH_STYLE_JSON
    assert math_style.MATH_STYLE in ai.TUTOR_SYSTEM and math_style.MATH_STYLE in doc_explain.SYSTEM
    assert "ε" in math_style.MATH_RULES and "integral von" in math_style.MATH_RULES


def test_keine_alte_anweisung_in_prompts():
    for p in ["app/ai.py", "app/flashcard_order.py", "app/doc_index.py", "app/weekly.py", "app/doc_explain.py"]:
        text = (ROOT / p).read_text(encoding="utf-8")
        assert "Formeln als Text" not in text and "LaTeX-frei" not in text, p
