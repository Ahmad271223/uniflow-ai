"""Formeln in KI-Antworten wie im Lehrbuch (07.11.2026, Wunsch des Inhabers: "statt epsilon wirklich ε, kein ^2,
sondern das richtige hoch 2"): KI-Hilfe im Editor und KI-Hilfe fuer das ganze Dokument verlangen echte Zeichen statt
LaTeX oder ausgeschriebener Namen. Die Apps setzen Reste zusaetzlich um (apps/apple: FormulaText)."""
from app import ai, doc_explain


def test_tutor_and_document_ask_for_real_symbols():
    for system in (ai.TUTOR_SYSTEM, doc_explain.SYSTEM):
        assert ai.FORMULA_RULE in system
        assert "LaTeX zwischen" not in system and "Formeln als Text" not in system
    for sign in ("ε statt epsilon", "x² statt x^2", "aₙ statt a_n", "kein LaTeX"):
        assert sign in ai.FORMULA_RULE
