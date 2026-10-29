"""Erzeugt apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/AI/AIPromptTexts.swift aus app/ai.py und
app/chatgpt_login.py: die festen Texte der KI (System-Prompts, Modi des Tutors, Analysefelder, Regel des Wochentests)
und die Konstanten von Sign in with ChatGPT, woertlich als String-Konstanten (keine Ressource: Bundle.module verhaelt
sich unter Linux anders). Die Prompts selbst baut `AIPrompts` daraus; AIContractTests prueft beides gegen
packages/shared-contracts/ai/contract.json.
Aufruf im Projektordner: python tools/gen-swift-ai-texts.py [--check]
"""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

from schema_source import CORE, write_or_check

OUT = CORE / "Sources" / "UniFlowCore" / "AI" / "AIPromptTexts.swift"


def raw(text: str) -> str:
    """Raw-Literal, dessen Wert genau `text` ist (einzeilig #"..."#, sonst mehrzeilig wie gen-swift-schema)."""
    if '"#' in text or "\r" in text:
        raise ValueError(f"Text laesst sich nicht als Raw-Literal schreiben: {text[:60]!r}")
    if "\n" in text:
        return '#"""\n' + text + '\n"""#'
    return '#"' + text + '"#'


def render(ai, cl) -> str:
    modes = "\n".join(f"        ({raw(k)}, {raw(v)})," for k, v in ai.TUTOR_MODES.items())
    diff = ", ".join(f"({raw(k)}, {v})" for k, v in ai.WEEK_TEST_DIFFICULTY.items())
    types = ", ".join(raw(t) for t in ai.WEEK_TEST_TYPES)
    consts = [("authURL", cl.AUTH_URL), ("tokenURL", cl.TOKEN_URL), ("issuer", cl.ISSUER), ("jwksURL", cl.JWKS_URL),
              ("resource", cl.RESOURCE), ("responsesURL", cl.RESPONSES_URL), ("modelsURL", cl.MODELS_URL),
              ("usageHelpURL", cl.USAGE_HELP_URL), ("scope", cl.SCOPE), ("usageScope", cl.USAGE_SCOPE),
              ("firstClientID", cl.FIRST_CLIENT_ID), ("agentName", cl.AGENT_NAME), ("callbackPath", cl.CALLBACK_PATH)]
    chat = "\n".join(f"    static let {n} = {raw(v)}" for n, v in consts)
    return f"""// erzeugt von tools/gen-swift-ai-texts.py, nicht von Hand aendern
// Quelle: app/ai.py und app/chatgpt_login.py

/// Feste Texte der KI wie in app/ai.py (byte-gleich; Vertrag packages/shared-contracts/ai/contract.json).
enum AIPromptTexts {{
    /// `ai.SYSTEM`
    static let system = {raw(ai.SYSTEM)}

    /// `ai.TUTOR_SYSTEM`
    static let tutorSystem = {raw(ai.TUTOR_SYSTEM)}

    /// `ai.TUTOR_MODES` in der Reihenfolge von Python
    static let tutorModes: [(key: String, text: String)] = [
{modes}
    ]

    /// `ai.ANALYSIS_FIELDS`
    static let analysisFields = {raw(ai.ANALYSIS_FIELDS)}

    /// `ai.WEEK_TEST_DIFFICULTY` (Entscheidung des Inhabers vom 29.10.2026) in der Reihenfolge von Python
    static let weekTestDifficulty: [(level: String, count: Int)] = [{diff}]

    /// `ai.WEEK_TEST_TOTAL`
    static let weekTestTotal = {ai.WEEK_TEST_TOTAL}

    /// `ai.WEEK_TEST_TYPES`
    static let weekTestTypes = [{types}]
}}

/// Konstanten von Sign in with ChatGPT wie app/chatgpt_login.py
enum ChatGPTConstants {{
{chat}
    /// Sekunden bis zum Abbruch einer Anmeldung
    static let flowTimeout: Double = {cl.FLOW_TIMEOUT_S}
    /// Zugriffstoken so viele Sekunden vor Ablauf erneuern
    static let refreshMargin: Double = {cl.REFRESH_MARGIN_S}
}}
"""


def main() -> int:
    tmp = tempfile.mkdtemp(prefix="studora-ai-texts-")
    os.environ["LERNAPP_DATA_DIR"] = str(Path(tmp) / "data")
    os.environ["LERNAPP_LOG_DIR"] = str(Path(tmp) / "logs")
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from app import ai, chatgpt_login
    ok = write_or_check(OUT, render(ai, chatgpt_login), "--check" in sys.argv[1:])
    return 0 if ok or "--check" not in sys.argv[1:] else 1


if __name__ == "__main__":
    sys.exit(main())
