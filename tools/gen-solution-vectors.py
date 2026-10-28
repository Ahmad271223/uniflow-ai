"""Schreibt packages/shared-contracts/fixtures/solutions/vectors.json: gemeinsame Testvektoren fuer Loesungspakete
"uniflow-solution" Version 1 (Windows/Web: app/static/solutions.js, iPad: SolutionPackage.swift + SolutionCrypto.swift,
Referenz: app/solution_format.py).

Jeder Fall enthaelt die PDF-Bytes (Base64; frei erfunden, nur Schluesselmaterial), festes Salz und Nonce, den Inhalt,
das erwartete kanonische Klartext-JSON, die AAD, den abgeleiteten Schluessel und das fertige Paket. Pruefen:
1. Paket mit der PDF oeffnen ergibt genau den Inhalt;
2. Inhalt mit Salz/Nonce versiegeln ergibt byte-gleich das Paket (kanonisches JSON, AAD, HKDF, AES-GCM);
3. die Negativfaelle scheitern mit dem genannten Fehler.

Aufruf aus dem Repo-Wurzelverzeichnis:  python tools/gen-solution-vectors.py [--check]
"""
import base64
import hashlib
import json
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app import solution_format as sf  # noqa: E402

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "solutions" / "vectors.json"


def png_1x1() -> bytes:
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"\x00\x2b\x5d\xf0\xff")) + chunk(b"IEND", b""))


def pdf_bytes(tag: str) -> bytes:
    body = f"%PDF-1.7\n% Studora-Testvektor {tag}\n".encode() + bytes(range(256)) * 8 + b"\n%%EOF\n"
    return body


def content_full(fp: str) -> dict:
    png = base64.b64encode(png_1x1()).decode()
    return {
        "format": sf.CONTENT_FORMAT, "formatVersion": 1,
        "solutionId": "6f1c2b9e-4d3a-4e8b-9c7d-2a1b3c4d5e6f", "createdAt": "2026-10-28T09:30:00Z",
        "title": "Übungsblatt 3 – Lösungen", "displayName": "Jörg \"JJ\"",
        "document": {"sha256": fp, "pageCount": 3},
        "pages": [
            {"key": "p1", "kind": "pdf", "pdfIndex": 1, "width": 595.28, "height": 841.89, "rotation": 0, "extraRotation": 0,
             "objects": [
                 {"id": "s1", "type": "stroke", "tool": "pen", "color": "#1d2130", "width": 2.2, "opacity": 1,
                  "points": [10, 20, 30.5, 40.25, 50.125, 60], "widths": [2, 2.4, 2.1], "x": 0, "y": 0, "rotation": 0, "scaleX": 1, "scaleY": 1},
                 {"id": "t1", "type": "text", "x": 100, "y": 120.5, "text": "a² + b² = c²\n\tZeile 2 \u0001 \\ / \"Zitat\" 😀 %PDF- im Freitext",
                  "fontFamily": "Arial", "fontSize": 14, "fill": "#e5322d", "bg": "", "width": 220, "rotation": 0, "scaleX": 1, "scaleY": 1},
                 {"id": "i1", "type": "image", "src": "/api/files/abc/assets/bild.png", "x": 20, "y": 300, "width": 64, "height": 64,
                  "rotation": 0, "scaleX": 1, "scaleY": 1, "opacity": 1},
                 {"id": "i2", "type": "image", "src": "/api/files/abc/assets/fehlt.jpg", "x": 20, "y": 400, "width": 10, "height": 10}]},
            {"key": "p3", "kind": "pdf", "pdfIndex": 3, "width": 612, "height": 792, "rotation": 90, "extraRotation": 90,
             "objects": [{"id": "r1", "type": "shape", "shape": "rect", "x": 0.00001, "y": 1234.5678, "width": 50, "height": 0.25,
                          "stroke": "#2b5df0", "strokeWidth": 1.5, "fill": "", "opacity": 0.35, "rotation": -12.5, "scaleX": 1, "scaleY": 1}]},
            {"key": "b1", "kind": "blank", "width": 595, "height": 842, "rotation": 0, "extraRotation": 0, "template": "lined",
             "objects": [{"id": "t2", "type": "text", "x": 40, "y": 40, "text": "Eigene Seite", "fontSize": 12}]},
        ],
        "images": {"/api/files/abc/assets/bild.png": {"mime": "image/png", "data": png}},
        "missingImages": ["/api/files/abc/assets/fehlt.jpg"],
    }


def content_anon(fp: str) -> dict:
    return {"format": sf.CONTENT_FORMAT, "formatVersion": 1, "solutionId": "0a0b0c0d-0e0f-4a1b-8c2d-3e4f5a6b7c8d",
            "createdAt": "2026-10-28T10:00:00Z", "title": "", "displayName": "", "document": {"sha256": fp, "pageCount": 1},
            "pages": [{"key": "p1", "kind": "pdf", "pdfIndex": 1, "width": 595, "height": 842, "rotation": 0, "extraRotation": 0,
                       "objects": [{"id": "s", "type": "stroke", "tool": "marker", "color": "#f5b400", "width": 16, "opacity": 0.35,
                                    "points": [1, 2, 3, 4]}]}],
            "images": {}, "missingImages": []}


def case(name: str, pdf: bytes, make, salt: bytes, nonce: bytes) -> dict:
    fp = hashlib.sha256(pdf).hexdigest()
    content = make(fp)
    pkg = sf.seal(content, pdf, salt, nonce)
    assert sf.open_package(pkg, pdf) == content
    return {"name": name, "pdf": base64.b64encode(pdf).decode(), "sha256": fp,
            "salt": base64.b64encode(salt).decode(), "nonce": base64.b64encode(nonce).decode(),
            "key_hex": sf.derive_key(pdf, salt, sf.key_info(content["solutionId"])).hex(),
            "info": sf.key_info(content["solutionId"]).decode(),
            "aad": sf.aad(pkg["header"]).decode(), "plaintext": sf.canonical(content),
            "content": content, "package": pkg, "package_text": sf.canonical(pkg)}


def render() -> str:
    pdf_a, pdf_b = pdf_bytes("A"), pdf_bytes("B")
    c1 = case("drei Seiten: PDF, gedrehte PDF-Seite, Leerseite, Bild, fehlendes Bild, Sonderzeichen", pdf_a, content_full,
              bytes(range(32)), bytes(range(100, 112)))
    c2 = case("anonym, eine Seite, Textmarker", pdf_b, content_anon, b"\xff" * 32, b"\x00" * 12)
    tampered = json.loads(json.dumps(c1["package"]))
    tampered["header"]["displayName"] = "Jemand anderes"
    flipped = json.loads(json.dumps(c2["package"]))
    ct = bytearray(base64.b64decode(flipped["ciphertext"]))
    ct[0] ^= 1
    flipped["ciphertext"] = base64.b64encode(bytes(ct)).decode()
    extra = json.loads(json.dumps(c2["package"]))
    extra["header"]["note"] = "zusätzlich"
    negative = [
        {"name": "Kopf veraendert (Anzeigename): AAD passt nicht", "pdf_of": 0, "package": tampered, "error": "decryptionFailed"},
        {"name": "Chiffrat veraendert", "pdf_of": 1, "package": flipped, "error": "decryptionFailed"},
        {"name": "andere PDF", "pdf_of": 1, "package": c1["package"], "error": "fingerprintMismatch"},
        {"name": "unbekanntes Feld im Kopf", "pdf_of": 1, "package": extra, "error": "invalidHeader"},
    ]
    data = {"_hinweis": "Erzeugt mit tools/gen-solution-vectors.py (Referenz app/solution_format.py); nicht von Hand aendern. "
                        "Pruefen: tests/test_solution_vectors.py (Python), tests/js/solutions.test.mjs (Browser), "
                        "Swift: SolutionPackage.open/seal mit festem Salz und Nonce.",
            "format": sf.FORMAT, "formatVersion": sf.FORMAT_VERSION, "cases": [c1, c2], "negative": negative}
    return json.dumps(data, ensure_ascii=False, indent=1) + "\n"


if __name__ == "__main__":
    text = render()
    if "--check" in sys.argv:
        ok = OUT.exists() and OUT.read_text(encoding="utf-8") == text
        print("aktuell" if ok else f"veraltet: {OUT.relative_to(ROOT)}")
        sys.exit(0 if ok else 1)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding="utf-8", newline="\n")
    print(f"geschrieben: {OUT.relative_to(ROOT)}")
