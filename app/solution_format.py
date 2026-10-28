"""Referenz des Loesungspakets "uniflow-solution" Version 1 in Python (28.10.2026).

Der Dienst selbst entschluesselt nie (er hat die PDF nicht, `community.validate_package` prueft nur den Kopf). Diese
Umsetzung dient als dritte, unabhaengige Gegenprobe zu Swift (`SolutionPackage.swift`, `SolutionCrypto.swift`) und
dem Browser (`app/static/solutions.js`): `tools/gen-solution-vectors.py` erzeugt damit die gemeinsamen Testvektoren
`packages/shared-contracts/fixtures/solutions/vectors.json`, die alle drei byte-gleich nachrechnen.

- Schluessel: HKDF-SHA256 (RFC 5869) ueber die vollstaendigen PDF-Bytes, Salz 32 Byte, Info
  "uniflow-solution/v1|<loesungs-id klein>", 32 Byte.
- AES-256-GCM, Nonce 12 Byte, Ergebnis Chiffrat + 16-Byte-Tag, AAD = kanonisches JSON von
  {"format", "formatVersion", "header"}.
- Kanonisches JSON wie `JSONValue.serialized(sortedKeys: true)`: sortierte Schluessel, keine Leerzeichen, UTF-8 ohne
  \\u-Maskierung ausser Steuerzeichen (\\n \\r \\t, sonst \\u00xx), ganze Zahlen ohne Nachkommastellen.
"""
from __future__ import annotations

import base64
import hashlib
import json
import math

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

FORMAT = "uniflow-solution"
CONTENT_FORMAT = "uniflow-solution-content"
FORMAT_VERSION = 1
TAG_BYTES = 16


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


def key_info(solution_id: str) -> bytes:
    return f"{FORMAT}/v{FORMAT_VERSION}|{solution_id.lower()}".encode()


def derive_key(pdf: bytes, salt: bytes, info: bytes) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=info).derive(pdf)


def aad(header: dict) -> bytes:
    return canonical({"format": FORMAT, "formatVersion": FORMAT_VERSION, "header": header}).encode()


def header_for(content: dict, salt: bytes, nonce: bytes, plaintext_bytes: int) -> dict:
    return {"solutionId": content["solutionId"], "createdAt": content["createdAt"], "displayName": content["displayName"],
            "document": {"sha256": content["document"]["sha256"], "pageCount": content["document"]["pageCount"]},
            "contents": {"pages": len(content["pages"]), "images": len(content["images"]), "missingImages": len(content["missingImages"])},
            "encryption": {"cipher": "AES-256-GCM", "kdf": "HKDF-SHA256", "keyMaterial": "original-pdf-bytes",
                           "salt": base64.b64encode(salt).decode(), "nonce": base64.b64encode(nonce).decode(),
                           "plaintextBytes": plaintext_bytes}}


def seal(content: dict, pdf: bytes, salt: bytes, nonce: bytes) -> dict:
    if hashlib.sha256(pdf).hexdigest() != content["document"]["sha256"]:
        raise ValueError("Fingerabdruck passt nicht")
    plaintext = canonical(content).encode()
    header = header_for(content, salt, nonce, len(plaintext))
    key = derive_key(pdf, salt, key_info(header["solutionId"]))
    ct = AESGCM(key).encrypt(nonce, plaintext, aad(header))
    return {"format": FORMAT, "formatVersion": FORMAT_VERSION, "header": header, "ciphertext": base64.b64encode(ct).decode()}


def open_package(pkg: dict, pdf: bytes) -> dict:
    h = pkg["header"]
    if hashlib.sha256(pdf).hexdigest() != h["document"]["sha256"]:
        raise ValueError("fingerprintMismatch")
    e = h["encryption"]
    key = derive_key(pdf, base64.b64decode(e["salt"]), key_info(h["solutionId"]))
    plain = AESGCM(key).decrypt(base64.b64decode(e["nonce"]), base64.b64decode(pkg["ciphertext"]), aad(h))
    if len(plain) != e["plaintextBytes"]:
        raise ValueError("Groesse")
    return json.loads(plain)
