"""Gemeinsame Testvektoren der Loesungspakete (packages/shared-contracts/fixtures/solutions/vectors.json): aktuell,
mit der Python-Referenz zu oeffnen, Negativfaelle scheitern, und der Dienst nimmt die echten Pakete an
(community.validate_package prueft denselben Kopf wie Swift und der Browser)."""
import base64
import importlib.util
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
FIX = ROOT / "packages" / "shared-contracts" / "fixtures" / "solutions" / "vectors.json"


def _gen():
    spec = importlib.util.spec_from_file_location("gen_solution_vectors", ROOT / "tools" / "gen-solution-vectors.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def test_vectors_are_current():
    assert FIX.read_text(encoding="utf-8") == _gen().render(), "python tools/gen-solution-vectors.py ausfuehren"


def test_open_reseal_and_reject():
    from cryptography.exceptions import InvalidTag
    from app import solution_format as sf
    v = json.loads(FIX.read_text(encoding="utf-8"))
    for c in v["cases"]:
        pdf = base64.b64decode(c["pdf"])
        assert sf.open_package(c["package"], pdf) == c["content"]
        pkg = sf.seal(c["content"], pdf, base64.b64decode(c["salt"]), base64.b64decode(c["nonce"]))
        assert sf.canonical(pkg) == c["package_text"]
        assert sf.derive_key(pdf, base64.b64decode(c["salt"]), c["info"].encode()).hex() == c["key_hex"]
    for n in v["negative"]:
        pdf = base64.b64decode(v["cases"][n["pdf_of"]]["pdf"])
        with pytest.raises((InvalidTag, ValueError, KeyError)):
            sf.open_package(n["package"], pdf)


def test_service_accepts_real_packages():
    from app import community
    v = json.loads(FIX.read_text(encoding="utf-8"))
    for c in v["cases"]:
        info = community.validate_package(c["package"])
        assert info["id"] == c["content"]["solutionId"] and info["fingerprint"] == c["sha256"]
        assert info["pages"] == len(c["content"]["pages"])
    with pytest.raises(community.CommunityError):
        community.validate_package(v["negative"][3]["package"])


def test_canonical_matches_swift_rules():
    from app import solution_format as sf
    assert sf.canonical({"b": "a\u0001\n\"/ü", "a": [1, 2.5, None, True, 595.0, 1e-05]}) == '{"a":[1,2.5,null,true,595,1e-05],"b":"a\\u0001\\n\\"/ü"}'
