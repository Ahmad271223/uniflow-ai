"""Schreibt packages/shared-contracts/fixtures/solutions/vectors.json: gemeinsame Testvektoren fuer Loesungspakete
"uniflow-solution" Version 2 (geschrieben) und Version 1 (nur gelesen) (Windows/Web: app/static/solutions.js, iPad:
SolutionPackage.swift + SolutionCrypto.swift, Referenz: app/solution_format.py).

Jeder Fall enthaelt die PDF-Bytes (Base64; frei erfunden, nur Schluesselmaterial), festes Salz und Nonce, den Inhalt
(`content`, wie ihn der Absender baut), den kanonischen Klartext von Version 2 vor dem Packen (`plaintext`), den
Inhalt nach dem Oeffnen (`opened`, Striche auf 0,1 Punkt), die AAD, den abgeleiteten Schluessel und das fertige Paket.
Die gepackten Bytes (raw DEFLATE) muessen zwischen den Sprachen NICHT gleich sein. Pruefen:
1. Paket aus Python oeffnen ergibt genau `opened`; alte Pakete (`legacy`, Version 1) ergeben genau `content`;
2. eigener Klartext von Version 2 aus `content` ist byte-gleich `plaintext`, AAD und Schluessel wie Python;
3. selbst versiegeln und wieder oeffnen ergibt `opened` (Hin und zurueck je Sprache);
4. `packed` (zlib-Ausgabe im Chiffrat) entpackt genau `plaintext`; `stroke_cases`: einzelne Striche -> Version 2 (`wire`) -> geoeffnet (`opened`);
5. die Negativfaelle scheitern mit dem genannten Fehler (u. a. entpackt groesser als angegeben).

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
                 {"id": "s2", "type": "stroke", "tool": "pen", "color": "#1d2130", "width": 1,
                  "points": [-0.05, -0.04, -0.15, 1e-07, 14400.04, 0.25, 7], "widths": [0.005, -0.015, 1e12]},
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


def case(name: str, pdf: bytes, make, salt: bytes, nonce: bytes, version: int = sf.FORMAT_VERSION) -> dict:
    fp = hashlib.sha256(pdf).hexdigest()
    content = make(fp)
    pkg = sf.seal(content, pdf, salt, nonce, version=version)
    opened = sf.normalized(content) if version == 2 else content
    assert sf.open_package(pkg, pdf) == opened
    out = {"name": name, "formatVersion": version, "pdf": base64.b64encode(pdf).decode(), "sha256": fp,
            "salt": base64.b64encode(salt).decode(), "nonce": base64.b64encode(nonce).decode(),
            "key_hex": sf.derive_key(pdf, salt, sf.key_info(content["solutionId"], version)).hex(),
            "info": sf.key_info(content["solutionId"], version).decode(),
            "aad": sf.aad(pkg["header"], version).decode(), "plaintext": sf.plaintext_of(content, version).decode(),
            "content": content, "opened": opened, "package": pkg, "package_text": sf.canonical(pkg)}
    if version == 2:
        # gepackter Klartext aus zlib (im Chiffrat), fuer Entpack-Tests ohne AES (Swift-Kern unter Linux)
        out["packed"] = base64.b64encode(sf.deflate(sf.plaintext_of(content))).decode()
    return out


def seal_raw(pdf: bytes, header: dict, body: bytes) -> dict:
    """Version 2 mit beliebigem gepacktem Klartext (Negativfaelle), ehrlich verschluesselt."""
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    e = header["encryption"]
    e["compressedBytes"] = len(body)
    key = sf.derive_key(pdf, base64.b64decode(e["salt"]), sf.key_info(header["solutionId"]))
    ct = AESGCM(key).encrypt(base64.b64decode(e["nonce"]), body, sf.aad(header))
    return {"format": sf.FORMAT, "formatVersion": 2, "header": header, "ciphertext": base64.b64encode(ct).decode()}


def stroke_cases() -> list:
    objs = [{"type": "stroke", "points": [10, 20, 30.5, 40.25, 50.125, 60], "widths": [2, 2.4, 2.1]},
            {"type": "stroke", "points": [-0.05, -0.04, -0.15, 1e-07, 14400.04, 0.25, 7], "widths": [0.005, -0.015]},
            {"type": "stroke", "points": [], "widths": []},
            {"type": "stroke", "points": [1e12, 5], "widths": [1, "x"], "tool": "pen"},
            {"type": "shape", "shape": "line", "points": [0.123, 4.567]}]
    out = []
    for o in objs:
        wire = sf.encode_object(o)
        out.append({"object": o, "wire": wire, "opened": json.loads(sf.canonical(sf.decode_object(json.loads(sf.canonical(wire)))))})
    return out


def render() -> str:
    pdf_a, pdf_b = pdf_bytes("A"), pdf_bytes("B")
    c1 = case("drei Seiten: PDF, gedrehte PDF-Seite, Leerseite, Bild, fehlendes Bild, Sonderzeichen", pdf_a, content_full,
              bytes(range(32)), bytes(range(100, 112)))
    c2 = case("anonym, eine Seite, Textmarker", pdf_b, content_anon, b"\xff" * 32, b"\x00" * 12)
    legacy = case("Version 1 (alt, ungepackt): drei Seiten wie oben, Punkte unveraendert", pdf_a, content_full,
                  bytes(range(32)), bytes(range(100, 112)), version=1)
    tampered = json.loads(json.dumps(c1["package"]))
    tampered["header"]["displayName"] = "Jemand anderes"
    flipped = json.loads(json.dumps(c2["package"]))
    ct = bytearray(base64.b64decode(flipped["ciphertext"]))
    ct[0] ^= 1
    flipped["ciphertext"] = base64.b64encode(bytes(ct)).decode()
    extra = json.loads(json.dumps(c2["package"]))
    extra["header"]["note"] = "zusätzlich"
    zstd = json.loads(json.dumps(c2["package"]))
    zstd["header"]["encryption"]["compression"] = "zstd"
    legacy_v2 = json.loads(json.dumps(legacy["package"]))
    legacy_v2["formatVersion"] = 2
    # Zip-Bombe: Kopf sagt 4096 Byte, entpackt waeren es mehr als maxPlaintextBytes
    bomb_header = json.loads(json.dumps(c2["package"]["header"]))
    bomb_header["encryption"]["plaintextBytes"] = 4096
    bomb = seal_raw(pdf_b, bomb_header, sf.deflate(b" " * (sf.MAX_PLAINTEXT_BYTES + 1)))
    short_header = json.loads(json.dumps(c2["package"]["header"]))
    short_header["encryption"]["plaintextBytes"] += 1
    short = seal_raw(pdf_b, short_header, sf.deflate(c2["plaintext"].encode()))
    both = json.loads(c2["plaintext"])
    both["pages"][0]["objects"][0]["points"] = [1, 2]
    both_text = sf.canonical(both).encode()
    both_header = json.loads(json.dumps(c2["package"]["header"]))
    both_header["encryption"]["plaintextBytes"] = len(both_text)
    both_pkg = seal_raw(pdf_b, both_header, sf.deflate(both_text))
    negative = [
        {"name": "Kopf veraendert (Anzeigename): AAD passt nicht", "pdf_of": 0, "package": tampered, "error": "decryptionFailed"},
        {"name": "Chiffrat veraendert", "pdf_of": 1, "package": flipped, "error": "decryptionFailed"},
        {"name": "andere PDF", "pdf_of": 1, "package": c1["package"], "error": "fingerprintMismatch"},
        {"name": "unbekanntes Feld im Kopf", "pdf_of": 1, "package": extra, "error": "invalidHeader"},
        {"name": "unbekannte Kompression", "pdf_of": 1, "package": zstd, "error": "invalidHeader"},
        {"name": "Version 1 als Version 2 ausgegeben (Kopf ohne Kompression)", "pdf_of": 0, "package": legacy_v2, "error": "invalidHeader"},
        {"name": "Zip-Bombe: entpackt groesser als plaintextBytes (und als maxPlaintextBytes)", "pdf_of": 1, "package": bomb, "error": "tooLarge"},
        {"name": "entpackt kleiner als plaintextBytes", "pdf_of": 1, "package": short, "error": "invalidContent"},
        {"name": "Strich mit points und pointsDelta zugleich", "pdf_of": 1, "package": both_pkg, "error": "invalidContent"},
    ]
    for n in negative:
        try:
            sf.open_package(n["package"], pdf_a if n["pdf_of"] == 0 else pdf_b)
        except Exception:
            pass
        else:
            raise AssertionError(n["name"])
    from app.studip_sync import classify
    secret = sf.community_secret("course", "luh", "kurs-beispiel")
    group_secret = sf.community_secret("group", "luh", "ABCDEFGH")
    content = content_anon(hashlib.sha256(pdf_b).hexdigest())
    pkg = sf.seal(content, None, b"\x11" * 32, b"\x22" * 12, secret)
    assert sf.open_package(pkg, secret=secret) == sf.normalized(content)
    community = {"university": "luh", "course_id": "kurs-beispiel", "code": "ABCDEFGH", "secret_hex": secret.hex(), "group_secret_hex": group_secret.hex(),
                 "module_cases": [{"title": t, "module": classify(t)[0], "key": sf.community_module_key("luh", classify(t)[0]),
                                   "secret_hex": sf.community_secret("module", "luh", sf.normalized_course_name(classify(t)[0])).hex()}
                                  for t in ("Programmieren I", "Übung: Programmieren I", "Hörsaalübung Programmieren I", "Tutorium zu Programmieren I",
                                            "Programmieren I - Gruppenübung 3", "Programmieren I (Vorlesung)", "Signale und Systeme (für Elektrotechnik)")],
                 "salt": base64.b64encode(b"\x11" * 32).decode(), "nonce": base64.b64encode(b"\x22" * 12).decode(),
                 "plaintext": sf.plaintext_of(content).decode(), "content": content, "opened": sf.normalized(content),
                 "package": pkg, "package_text": sf.canonical(pkg)}
    data = {"_hinweis": "Erzeugt mit tools/gen-solution-vectors.py (Referenz app/solution_format.py); nicht von Hand aendern. "
                        "Pruefen: tests/test_solution_vectors.py (Python), tests/js/solutions.test.mjs (Browser), "
                        "Swift: SolutionPackageTests/ServiceCommunityTests (Kern) und SolutionVectorsAppTests (App). "
                        "Gepackte Bytes sind je Sprache verschieden: geprueft werden Oeffnen der Python-Pakete, Klartext vor dem Packen "
                        "und Hin und zurueck.",
            "format": sf.FORMAT, "formatVersion": sf.FORMAT_VERSION, "readVersions": list(sf.READ_VERSIONS),
            "cases": [c1, c2], "legacy": [legacy], "stroke_cases": stroke_cases(), "negative": negative,
            "community": community}
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
