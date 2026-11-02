"""Referenz des Loesungspakets "uniflow-solution" in Python: Version 1 (28.10.2026) lesen, Version 2 (2.11.2026)
lesen und schreiben.

Der Dienst selbst entschluesselt nie (er hat die PDF nicht, `community.validate_package` prueft nur den Kopf). Diese
Umsetzung dient als dritte, unabhaengige Gegenprobe zu Swift (`SolutionPackage.swift`, `SolutionCrypto.swift`) und
dem Browser (`app/static/solutions.js`): `tools/gen-solution-vectors.py` erzeugt damit die gemeinsamen Testvektoren
`packages/shared-contracts/fixtures/solutions/vectors.json`, die alle drei nachrechnen.

- Schluessel: HKDF-SHA256 (RFC 5869) ueber die vollstaendigen PDF-Bytes, Salz 32 Byte, Info
  "uniflow-solution/v<formatVersion>|<loesungs-id klein>", 32 Byte.
  Community-Pakete (1.11.2026): `keyMaterial` = "community-secret", Eingabe statt der PDF ist `community_secret`
  aus Kurs-ID bzw. Beitrittscode, damit Mitglieder eine Loesung auch ohne die PDF oeffnen. Der Dienst kennt nur den
  davon getrennten Kurs- bzw. Gruppen-Schluessel.
- AES-256-GCM, Nonce 12 Byte, Ergebnis Chiffrat + 16-Byte-Tag, AAD = kanonisches JSON von
  {"format", "formatVersion", "header"}.
- Version 2 (kleiner, docs/LOESUNGEN-TEILEN.md Abschnitt 3a): Strich-Objekte tragen statt `points`/`widths` die
  Felder `pointsDelta` (Koordinate x 10 abgerundet nach +0,5, Differenz zum Wert zwei Stellen davor, die ersten beiden
  absolut) und `widthsDelta` (Breite x 100, Differenz zum Vorgaenger); der kanonische Klartext wird vor dem
  Verschluesseln mit raw DEFLATE (RFC 1951) gepackt. Kopf: `encryption.compression` = "deflate-raw",
  `compressedBytes` = gepackte Groesse (Chiffrat = compressedBytes + 16), `plaintextBytes` = entpackte Groesse (harte
  Obergrenze beim Entpacken). Nach dem Oeffnen sind es wieder Objekte wie in Version 1 (Punkte als Zahlenliste in
  Seitenpunkten, auf 0,1 Punkt genau).
- Kanonisches JSON wie `JSONValue.serialized(sortedKeys: true)`: sortierte Schluessel, keine Leerzeichen, UTF-8 ohne
  \\u-Maskierung ausser Steuerzeichen (\\n \\r \\t, sonst \\u00xx), ganze Zahlen ohne Nachkommastellen.
"""
from __future__ import annotations

import base64
import hashlib
import json
import math
import zlib

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

FORMAT = "uniflow-solution"
CONTENT_FORMAT = "uniflow-solution-content"
FORMAT_VERSION = 2                      # geschrieben wird immer Version 2
READ_VERSIONS = (1, 2)
CONTENT_VERSION = 1                     # Form des Inhalts nach dem Oeffnen (Punkte als Zahlenliste)
TAG_BYTES = 16
COMPRESSION = "deflate-raw"
MAX_PLAINTEXT_BYTES = 48 << 20          # wie SolutionLimits.maxPlaintextBytes
# Feld im Speicher, Feld in Version 2, Faktor (0,1 Punkt bzw. 0,01 Punkt Strichbreite), Abstand der Differenz
DELTA_FIELDS = (("points", "pointsDelta", 10, 2), ("widths", "widthsDelta", 100, 1))
MAX_QUANT = 10**10                      # |Wert x Faktor| hoechstens so gross, sonst bleibt die Liste unveraendert


def number(d) -> str:
    if isinstance(d, bool):
        raise TypeError("bool ist keine Zahl")
    if isinstance(d, int):
        return str(d) if abs(d) < 10**15 else repr(float(d))
    if not math.isfinite(d):
        return "null"
    if d == int(d) and abs(d) < 1e15:
        return str(int(d))
    return repr(d)                      # kuerzeste Darstellung, Exponent wie Swift (1e-05, 1e+16)


def string(s: str) -> str:
    out = ['"']
    for ch in s:
        c = ord(ch)
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif c == 10:
            out.append("\\n")
        elif c == 13:
            out.append("\\r")
        elif c == 9:
            out.append("\\t")
        elif c < 0x20:
            out.append("\\u00%02x" % c)
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def canonical(v) -> str:
    if v is None:
        return "null"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, (int, float)):
        return number(v)
    if isinstance(v, str):
        return string(v)
    if isinstance(v, (list, tuple)):
        return "[" + ",".join(canonical(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{" + ",".join(string(k) + ":" + canonical(v[k]) for k in sorted(v)) + "}"
    raise TypeError(type(v))


def key_info(solution_id: str, version: int = FORMAT_VERSION) -> bytes:
    return f"{FORMAT}/v{version}|{solution_id.lower()}".encode()


def derive_key(pdf: bytes, salt: bytes, info: bytes) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=info).derive(pdf)


def normalized_course_name(raw: str) -> str:
    """Wie CommunityKeys.normalizedCourseName: Kleinbuchstaben, Umlaute ausgeschrieben, nur Buchstaben und Ziffern."""
    import unicodedata
    out, pending = "", False
    for ch in unicodedata.normalize("NFC", raw).lower():          # zerlegte Umlaute wie in Swift (Graphem-Cluster)
        mapped = {"ä": "ae", "ö": "oe", "ü": "ue", "ß": "ss"}.get(ch) or (ch if ch.isalnum() else "")
        if not mapped:
            pending = bool(out)
        else:
            out += (" " if pending else "") + mapped
            pending = False
    return out


def community_module_key(university: str, module_name: str) -> str | None:
    """Community eines Moduls wie CommunityKeys.moduleKey: eine fuer alle Veranstaltungen des Moduls."""
    name = normalized_course_name(module_name)
    return hashlib.sha256(f"uniflow.community.coursename.v1\0{university}\0{name}".encode()).hexdigest() if name else None


def community_secret(scope: str, university: str, value: str) -> bytes:
    """Schluesselmaterial einer Community; `scope` = module (normalisierter Modulname), course (Kurs-ID) oder group
    (normalisierter Code)."""
    return hashlib.sha256(f"uniflow.community.secret.v1\0{scope}\0{university}\0{value}".encode()).digest()


def aad(header: dict, version: int = FORMAT_VERSION) -> bytes:
    return canonical({"format": FORMAT, "formatVersion": version, "header": header}).encode()


# ---------------------------------------------------------------- Version 2: Striche als ganze Zahlen, raw DEFLATE

def quantize(v: float, scale: int) -> int:
    """Wie Swift `(v * scale + 0.5).rounded(.down)` und JS `Math.floor(v * scale + 0.5)` (nicht Pythons round)."""
    return math.floor(v * scale + 0.5)


def _encodable(arr, scale: int) -> bool:
    return isinstance(arr, list) and all(isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)
                                         and abs(x) * scale <= MAX_QUANT for x in arr)


def encode_object(o):
    """Strich im Speicher -> Version 2; andere Objekte und nicht kodierbare Listen bleiben unveraendert."""
    if not isinstance(o, dict) or o.get("type") != "stroke":
        return o
    if any(d in o for _, d, _, _ in DELTA_FIELDS):
        raise ValueError("invalidContent: reserviertes Feld")
    out = dict(o)
    for field, dfield, scale, step in DELTA_FIELDS:
        arr = o.get(field)
        if field in o and _encodable(arr, scale):
            q = [quantize(x, scale) for x in arr]
            out[dfield] = [q[i] - (q[i - step] if i >= step else 0) for i in range(len(q))]
            del out[field]
    return out


def decode_object(o):
    if not isinstance(o, dict) or o.get("type") != "stroke":
        return o
    out = dict(o)
    for field, dfield, scale, step in DELTA_FIELDS:
        if dfield not in o:
            continue
        arr = o[dfield]
        if field in o or not isinstance(arr, list):
            raise ValueError("invalidContent: Strich")
        q: list[int] = []
        for i, d in enumerate(arr):
            if isinstance(d, bool) or not isinstance(d, (int, float)) or not math.isfinite(d) or d != int(d) or abs(d) > 2 * MAX_QUANT:
                raise ValueError("invalidContent: Strich")
            v = int(d) + (q[i - step] if i >= step else 0)
            if abs(v) > MAX_QUANT:
                raise ValueError("invalidContent: Strich")
            q.append(v)
        out[field] = [v / scale for v in q]
        del out[dfield]
    return out


def _map_objects(content: dict, fn, version: int) -> dict:
    out = dict(content, formatVersion=version)
    pages = content.get("pages")
    if isinstance(pages, list):
        out["pages"] = [dict(p, objects=[fn(o) for o in p["objects"]]) if isinstance(p, dict) and isinstance(p.get("objects"), list) else p
                        for p in pages]
    return out


def encode_content(content: dict) -> dict:
    """Inhalt im Speicher (Version 1) -> Klartext von Version 2."""
    return _map_objects(content, encode_object, 2)


def decode_content(wire) -> dict:
    """Klartext von Version 2 -> Inhalt im Speicher (Version 1, Punkte als Zahlenliste)."""
    if not isinstance(wire, dict) or wire.get("format") != CONTENT_FORMAT or wire.get("formatVersion") != 2:
        raise ValueError("invalidContent: Formatversion")
    return _map_objects(wire, decode_object, CONTENT_VERSION)


def normalized(content: dict) -> dict:
    """Was der Empfaenger nach Version 2 erhaelt (Striche auf 0,1 Punkt), als reines JSON."""
    return json.loads(canonical(decode_content(json.loads(canonical(encode_content(content))))))


def deflate(data: bytes) -> bytes:
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    return c.compress(data) + c.flush()


def inflate(data: bytes, limit: int) -> bytes:
    """Raw DEFLATE entpacken, hoechstens `limit` Byte (Schutz vor Zip-Bomben); mehr: tooLarge."""
    d = zlib.decompressobj(-15)
    try:
        out = d.decompress(data, limit + 1)
    except zlib.error:
        raise ValueError("invalidContent: Kompression")
    if len(out) > limit:
        raise ValueError("tooLarge")
    if not d.eof or d.unused_data or d.unconsumed_tail:
        raise ValueError("invalidContent: Kompression")
    return out


def header_for(content: dict, salt: bytes, nonce: bytes, plaintext_bytes: int, key_material: str = "original-pdf-bytes",
               compressed_bytes: int | None = None) -> dict:
    h = {"solutionId": content["solutionId"], "createdAt": content["createdAt"], "displayName": content["displayName"],
         "document": {"sha256": content["document"]["sha256"], "pageCount": content["document"]["pageCount"]},
         "contents": {"pages": len(content["pages"]), "images": len(content["images"]), "missingImages": len(content["missingImages"])},
         "encryption": {"cipher": "AES-256-GCM", "kdf": "HKDF-SHA256", "keyMaterial": key_material,
                        "salt": base64.b64encode(salt).decode(), "nonce": base64.b64encode(nonce).decode(),
                        "plaintextBytes": plaintext_bytes}}
    if compressed_bytes is not None:
        h["encryption"].update(compression=COMPRESSION, compressedBytes=compressed_bytes)
    return h


def plaintext_of(content: dict, version: int = FORMAT_VERSION) -> bytes:
    """Kanonischer Klartext vor dem Packen (Version 2) bzw. vor dem Verschluesseln (Version 1)."""
    return canonical(encode_content(content) if version == 2 else content).encode()


def seal(content: dict, pdf: bytes | None, salt: bytes, nonce: bytes, secret: bytes | None = None, version: int = FORMAT_VERSION) -> dict:
    """Versiegeln; `version=1` nur fuer Testvektoren alter Pakete (die Apps schreiben immer Version 2)."""
    if secret is None and hashlib.sha256(pdf).hexdigest() != content["document"]["sha256"]:
        raise ValueError("Fingerabdruck passt nicht")
    plaintext = plaintext_of(content, version)
    if len(plaintext) > MAX_PLAINTEXT_BYTES:
        raise ValueError("tooLarge")
    body = deflate(plaintext) if version == 2 else plaintext
    header = header_for(content, salt, nonce, len(plaintext), "community-secret" if secret else "original-pdf-bytes",
                        len(body) if version == 2 else None)
    key = derive_key(secret or pdf, salt, key_info(header["solutionId"], version))
    ct = AESGCM(key).encrypt(nonce, body, aad(header, version))
    return {"format": FORMAT, "formatVersion": version, "header": header, "ciphertext": base64.b64encode(ct).decode()}


def open_package(pkg: dict, pdf: bytes | None = None, secret: bytes | None = None) -> dict:
    version = pkg["formatVersion"]
    if isinstance(version, bool) or version not in READ_VERSIONS:
        raise ValueError("unsupportedVersion")
    h = pkg["header"]
    e = h["encryption"]
    if ("compression" in e or "compressedBytes" in e) != (version == 2) or (version == 2 and e["compression"] != COMPRESSION):
        raise ValueError("invalidHeader")
    if not 1 <= e["plaintextBytes"] <= MAX_PLAINTEXT_BYTES:
        raise ValueError("invalidHeader")
    if e["keyMaterial"] == "community-secret":
        if secret is None:
            raise ValueError("decryptionFailed")
        material = secret
    else:
        if pdf is None or hashlib.sha256(pdf).hexdigest() != h["document"]["sha256"]:
            raise ValueError("fingerprintMismatch")
        material = pdf
    key = derive_key(material, base64.b64decode(e["salt"]), key_info(h["solutionId"], version))
    body = AESGCM(key).decrypt(base64.b64decode(e["nonce"]), base64.b64decode(pkg["ciphertext"]), aad(h, version))
    if version == 2:
        if len(body) != e["compressedBytes"]:
            raise ValueError("invalidHeader")
        body = inflate(body, e["plaintextBytes"])
    if len(body) != e["plaintextBytes"]:
        raise ValueError("invalidContent: Groesse")
    content = json.loads(body)
    return decode_content(content) if version == 2 else content
