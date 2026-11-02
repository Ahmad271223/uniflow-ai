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
    assert v["formatVersion"] == 2 and v["readVersions"] == [1, 2]
    for c in v["cases"] + v["legacy"]:
        pdf = base64.b64decode(c["pdf"])
        assert c["package"]["formatVersion"] == c["formatVersion"]
        assert sf.open_package(c["package"], pdf) == c["opened"]
        assert sf.plaintext_of(c["content"], c["formatVersion"]).decode() == c["plaintext"]
        pkg = sf.seal(c["content"], pdf, base64.b64decode(c["salt"]), base64.b64decode(c["nonce"]), version=c["formatVersion"])
        assert sf.canonical(pkg) == c["package_text"]
        assert sf.derive_key(pdf, base64.b64decode(c["salt"]), c["info"].encode()).hex() == c["key_hex"]
    assert v["legacy"][0]["opened"] == v["legacy"][0]["content"], "alte Pakete: Punkte unveraendert"
    for c in v["cases"]:
        assert sf.inflate(base64.b64decode(c["packed"]), len(c["plaintext"].encode())).decode() == c["plaintext"]
    for n in v["negative"]:
        pdf = base64.b64decode(v["cases"][n["pdf_of"]]["pdf"])
        with pytest.raises((InvalidTag, ValueError, KeyError)) as x:
            sf.open_package(n["package"], pdf)
        if n["error"] in ("tooLarge", "invalidContent"):
            assert str(x.value).startswith(n["error"]), n["name"]


def test_stroke_cases_and_precision():
    from app import solution_format as sf
    v = json.loads(FIX.read_text(encoding="utf-8"))
    for c in v["stroke_cases"]:
        assert sf.encode_object(c["object"]) == c["wire"]
        assert sf.decode_object(c["wire"]) == c["opened"]
    for c in v["cases"]:
        for pa, pb in zip(c["content"]["pages"], c["opened"]["pages"]):
            for a, b in zip(pa["objects"], pb["objects"]):
                if a["type"] == "stroke" and "pointsDelta" in sf.encode_object(a):
                    assert len(a["points"]) == len(b["points"]) and max((abs(x - y) for x, y in zip(a["points"], b["points"])), default=0) <= 0.05 + 1e-9
    with pytest.raises(ValueError):
        sf.encode_object({"type": "stroke", "pointsDelta": [1]})
    with pytest.raises(ValueError):
        sf.decode_object({"type": "stroke", "pointsDelta": [1.5]})
    with pytest.raises(ValueError):
        sf.decode_object({"type": "stroke", "pointsDelta": [sf.MAX_QUANT, 0, 1]})


def test_inflate_has_a_hard_limit():
    from app import solution_format as sf
    data = sf.deflate(b"a" * 100_000)
    assert len(data) < 1000
    assert sf.inflate(data, 100_000) == b"a" * 100_000
    with pytest.raises(ValueError, match="tooLarge"):
        sf.inflate(data, 99_999)
    with pytest.raises(ValueError, match="invalidContent"):
        sf.inflate(data[:-3], 100_000)
    with pytest.raises(ValueError, match="invalidContent"):
        sf.inflate(data + b"x", 100_000)


def test_all_events_of_a_module_share_one_community():
    from app import solution_format as sf
    from app.studip_sync import classify
    cases = json.loads(FIX.read_text(encoding="utf-8"))["community"]["module_cases"]
    assert len({c["key"] for c in cases[:6]}) == 1 and cases[0]["module"] == "Programmieren I", "Vorlesung, Uebung, Tutorium: eine Community"
    assert cases[6]["key"] != cases[0]["key"]
    for c in cases:
        name = classify(c["title"])[0]
        assert sf.community_module_key("luh", name) == c["key"]
        assert sf.community_secret("module", "luh", sf.normalized_course_name(name)).hex() == c["secret_hex"]
    assert sf.community_module_key("luh", " - ") is None
    assert sf.normalized_course_name("Gru\u0308ndlagen") == "gruendlagen", "zerlegte Umlaute wie in Swift"


def test_community_package_opens_with_the_secret_without_the_pdf():
    from cryptography.exceptions import InvalidTag
    from app import community, solution_format as sf
    c = json.loads(FIX.read_text(encoding="utf-8"))["community"]
    secret = sf.community_secret("course", c["university"], c["course_id"])
    assert secret.hex() == c["secret_hex"]
    assert sf.open_package(c["package"], secret=secret) == c["opened"]
    assert sf.canonical(sf.seal(c["content"], None, base64.b64decode(c["salt"]), base64.b64decode(c["nonce"]), secret)) == c["package_text"]
    with pytest.raises(InvalidTag):
        sf.open_package(c["package"], secret=sf.community_secret("course", c["university"], "anderer-kurs"))
    with pytest.raises(ValueError):
        sf.open_package(c["package"], pdf=b"%PDF-1.7")
    assert community.validate_package(c["package"])["key_material"] == "community-secret"


def test_service_accepts_real_packages():
    from app import community
    v = json.loads(FIX.read_text(encoding="utf-8"))
    for c in v["cases"]:
        info = community.validate_package(c["package"])
        assert info["id"] == c["content"]["solutionId"] and info["fingerprint"] == c["sha256"]
        assert info["pages"] == len(c["content"]["pages"])
    for c in v["legacy"]:
        assert community.validate_package(c["package"])["id"] == c["content"]["solutionId"], "alte Pakete bleiben gueltig"
    for n in v["negative"]:
        if n["error"] == "invalidHeader":
            with pytest.raises(community.CommunityError):
                community.validate_package(n["package"])


def test_canonical_matches_swift_rules():
    from app import solution_format as sf
    assert sf.canonical({"b": "a\u0001\n\"/ü", "a": [1, 2.5, None, True, 595.0, 1e-05]}) == '{"a":[1,2.5,null,true,595,1e-05],"b":"a\\u0001\\n\\"/ü"}'
