"""Gemeinsame Anweisung fuer Mathematik in allen KI-Prompts (07.11.2026, Wunsch des Inhabers): Formeln so, dass die
App sie in richtigen Zeichen zeigt (Kern: MathText.swift). Markdown-Antworten (Tutor, ganzes Dokument) schreiben
Formeln in LaTeX zwischen $...$; JSON-Antworten (Tests, Karteikarten, Index) direkt mit Unicode-Zeichen, weil ein
einzelner Backslash in JSON die Antwort unlesbar macht. Die Geraete-Kerne haben dieselben Texte
(AIPromptTexts.mathStyle / mathStyleJSON, erzeugt von tools/gen-swift-ai-texts.py); tests/test_math_style.py prueft,
dass jeder System-Prompt eine davon enthaelt.
"""

MATH_RULES = ("Griechische Buchstaben immer als Symbol (ε, α, δ, λ, σ, ω, π), nie ausgeschrieben; keine Umschreibungen "
              "wie \"integral von ... bis ...\" oder \"x hoch 2\"; kein ^ oder _ im Fliesstext.")

MATH_STYLE = ("Mathematik: Formeln in LaTeX zwischen $...$, auch mitten im Satz (z. B. $x^2$, $e^{-2t}$, "
              "$\\int_{-\\infty}^{\\infty} |x(t)|^2 \\, dt$, $\\frac{a}{b}$, $\\varepsilon$). " + MATH_RULES)

MATH_STYLE_JSON = ("Mathematik: Formeln direkt mit Unicode-Zeichen statt LaTeX, ohne Backslash (x², e⁻²ᵗ, 10⁻³, aₙ, √x, "
                   "∫, ∑, ∞, ≤, ≥, ≠, →, ·, Brueche als (a+b)/(c+d)). " + MATH_RULES)
