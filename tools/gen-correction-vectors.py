"""Schreibt packages/shared-contracts/fixtures/community/correction-vectors.json: gemeinsame Testvektoren fuer das
Chiffrat eines Korrekturvorschlags (Typ `Correction` in CloudKit, `payload` beim Dienst; Referenz
app/community_corrections.py, Gegenstueck zu CommunityCorrections.swift, im Browser app/static/community-corrections.js).

Jeder Fall enthaelt Geheimnis, festes Salz und Nonce, die Korrektur (wie der Absender sie baut), den kanonischen Klartext
von Version 2 vor dem Packen (`plaintext`), Info und Zusatzdaten sowie das fertige Chiffrat (`payload`) und den Inhalt nach
dem Oeffnen (`opened`, Striche auf 0,1 Punkt). Die gepackten Bytes (raw DEFLATE) muessen zwischen den Sprachen NICHT gleich
sein. Pruefen: (1) das Chiffrat aus Python oeffnen ergibt genau `opened`; (2) der eigene Klartext aus `correction` ist
byte-gleich `plaintext`, Info und Zusatzdaten wie angegeben; (3) selbst versiegeln und wieder oeffnen ergibt `opened`;
(4) falscher Schluessel, andere Loesung oder andere Korrektur scheitern.

Aufruf aus dem Repo-Wurzelverzeichnis:  python tools/gen-correction-vectors.py [--check]
"""
import base64
import json
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "community" / "correction-vectors.json"
SOLUTION = "6f1c1c0e-0000-4000-8000-000000000003"


def build() -> dict:
    if "app.config" not in sys.modules:                  # nie den echten Datenordner anfassen (wie tests/conftest.py)
        tmp = tempfile.mkdtemp(prefix="uniflow-correction-vectors-")
        os.environ.setdefault("LERNAPP_DATA_DIR", str(Path(tmp) / "data"))
        os.environ.setdefault("LERNAPP_LOG_DIR", str(Path(tmp) / "logs"))
        sys.path.insert(0, str(ROOT))
    from app import community_corrections as cc
    from app import solution_format as sf
    secret = sf.community_secret("module", "luh", "analysis i")
    stroke = {"id": "s1", "type": "stroke", "tool": "pen", "color": "#e5322d", "width": 2.2, "opacity": 1,
              "points": [10.04, 20, 11.5, 20.75, 13.04, 21.5], "x": 0, "y": 0, "rotation": 0, "scaleX": 1, "scaleY": 1}
    marker = {"id": "s2", "type": "stroke", "tool": "marker", "color": "#ffd60a", "width": 14, "opacity": 0.35,
              "points": [100, 200, 180, 200.5], "x": 0, "y": 0, "rotation": 0, "scaleX": 1, "scaleY": 1}
    cases = []
    for name, corr_id, c in (
        ("Striche und Randnotiz auf zwei Seiten, eine gedrehte", "00000000-0000-4000-8000-000000000001",
         {"pseudonym": "Ben", "note": "  Aufgabe 2b: Vorzeichen  ",
          "pages": [{"pdfIndex": 5, "width": 595.28, "height": 841.89, "rotation": 90, "strokes": [marker], "notes": []},
                    {"pdfIndex": 3, "width": 595, "height": 842, "rotation": 0, "strokes": [stroke],
                     "notes": [{"id": "n1", "x": 0.25, "y": 0.75, "text": "hier fehlt ein Minus – äöü"}]}]}),
        ("nur Begleittext", "00000000-0000-4000-8000-000000000002",
         {"pseudonym": "", "note": "Sieht gut aus, nur Tippfehler in 3a.", "pages": []}),
    ):
        corr = {"id": corr_id, "solution_id": SOLUTION, "created_at": "2026-11-03T10:00:00Z", **c}
        salt, nonce = bytes([0x11 + len(cases)]) * 32, bytes([0x22 + len(cases)]) * 12
        payload = cc.seal(corr, secret, salt, nonce)
        cases.append({"name": name, "correction": corr, "salt": base64.b64encode(salt).decode(), "nonce": base64.b64encode(nonce).decode(),
                      "plaintext": cc.plaintext(corr).decode(), "info": cc._key_info(SOLUTION).decode(),
                      "aad": cc._aad(SOLUTION, corr_id).decode(), "payload": payload,
                      "opened": cc.open_payload(payload, corr_id, SOLUTION, secret)})
    return {"_hinweis": "Erzeugt mit tools/gen-correction-vectors.py (Referenz app/community_corrections.py); nicht von Hand aendern. "
                        "Pruefen: tests/test_community_corrections.py (Python), tests/js/community-corrections.test.mjs (Browser). "
                        "Gepackte Bytes sind je Sprache verschieden: geprueft werden Oeffnen der Python-Chiffrate, Klartext vor dem Packen "
                        "und Hin und zurueck.",
            "format": cc.FORMAT, "contentVersion": cc.CONTENT_VERSION, "payloadVersion": cc.PAYLOAD_VERSION,
            "secret": secret.hex(), "solutionID": SOLUTION, "cases": cases}


if __name__ == "__main__":
    text = json.dumps(build(), ensure_ascii=False, indent=1) + "\n"
    if "--check" in sys.argv:
        ok = OUT.exists() and OUT.read_text(encoding="utf-8") == text
        print("aktuell" if ok else f"veraltet: {OUT.relative_to(ROOT)}")
        sys.exit(0 if ok else 1)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding="utf-8", newline="\n")
    print(f"geschrieben: {OUT.relative_to(ROOT)}")
