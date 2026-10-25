"""Erzeugt apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/Store/SchemaSQL.swift aus app.db.SCHEMA und der
Tabelle page_texts aus app/scriptsearch.py (ensure_table).

Das Schema steht woertlich als String-Konstante im Swift-Kern (keine Ressource: Bundle.module verhaelt sich unter
Linux anders). Nach jeder Aenderung an SCHEMA erneut ausfuehren, danach tools/gen-schema-fixture.py.
Aufruf im Projektordner: python tools/gen-swift-schema.py [--check]
  --check: nichts schreiben, Exitcode 1, wenn die Datei nicht aktuell ist
"""
from __future__ import annotations

import sys

from schema_source import CORE, SchemaSource, write_or_check

OUT = CORE / "Sources" / "UniFlowCore" / "Store" / "SchemaSQL.swift"


def swift_raw(text: str) -> str:
    """Mehrzeiliges Raw-Literal #\"\"\" ... \"\"\"#, dessen Wert genau `text` ist.

    Swift laesst den Zeilenumbruch direkt nach dem oeffnenden und direkt vor dem schliessenden Begrenzer weg;
    darum wird je einer ergaenzt. Der schliessende Begrenzer steht in Spalte 0, also wird nichts eingerueckt.
    """
    if '"""#' in text or "\r" in text:
        raise ValueError("Text laesst sich nicht als Raw-Literal schreiben")
    return '#"""\n' + text + '\n"""#'


def render(schema: str, page_texts: str) -> str:
    return f"""// erzeugt von tools/gen-swift-schema.py, nicht von Hand aendern
// Quelle: app/db.py (SCHEMA) und app/scriptsearch.py (ensure_table, Tabelle page_texts)

/// Schema der Python-Referenz, woertlich. `Migrations` fuehrt es aus und bringt bestehende Datenbanken danach wie
/// `init_db()` auf den aktuellen Stand.
enum SchemaSQL {{
    /// `app.db.SCHEMA`
    static let schema = {swift_raw(schema)}

    /// `app.scriptsearch.ensure_table` (in Python erst bei der ersten Skriptsuche angelegt)
    static let pageTexts = {swift_raw(page_texts)}
}}
"""


def main() -> int:
    check = "--check" in sys.argv[1:]
    src = SchemaSource()
    try:
        content = render(src.db.SCHEMA, src.page_texts_sql())
    finally:
        src.cleanup()
    ok = write_or_check(OUT, content, check)
    return 0 if ok or not check else 1


if __name__ == "__main__":
    sys.exit(main())
