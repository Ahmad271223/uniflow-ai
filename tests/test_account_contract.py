"""Vertrag G1: packages/shared-contracts/fixtures/account/contract.json entspricht der Python-Referenz.
Dieselbe Datei prueft der Swift- und der Kotlin-Client (Modelle, Fehlercodes, Ablaeufe)."""
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / "packages" / "shared-contracts" / "fixtures" / "account" / "contract.json"


def _tool():
    spec = importlib.util.spec_from_file_location("gen_account_fixture", ROOT / "tools" / "gen-account-fixture.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_account_contract_matches_python(app, monkeypatch):
    from app import accounts, config
    monkeypatch.setattr(config, "MODE", "hosted")
    accounts.db_path().unlink(missing_ok=True)
    monkeypatch.setattr(accounts, "identity_verifiers", {})
    try:
        built = _tool().build()
    finally:
        monkeypatch.setattr(config, "MODE", "local")
        accounts.db_path().unlink(missing_ok=True)
    stored = json.loads(CONTRACT.read_text(encoding="utf-8"))
    assert built["rules"] == stored["rules"]
    assert built["email-cases"] == stored["email-cases"] and built["password-cases"] == stored["password-cases"]
    assert built["endpoints"] == stored["endpoints"]
    assert built["errors"] == stored["errors"]
    assert [(f["step"], f["status"]) for f in built["flows"]] == [(f["step"], f["status"]) for f in stored["flows"]]
    assert built["flows"] == stored["flows"], "python tools/gen-account-fixture.py neu ausfuehren"


def test_contract_has_no_real_tokens_or_ids():
    text = CONTRACT.read_text(encoding="utf-8")
    import re
    d = json.loads(text)
    responses = json.dumps([f["response"] for f in d["flows"]])
    assert not re.search(r'"token": "(?!<token>)', responses), "Antworten enthalten nur Platzhalter-Tokens"
    assert not re.search(r'"id": "[a-f0-9]{32}"', text)
    assert all(f["status"] != 500 for f in d["flows"])
    assert {e["path"] for e in d["endpoints"]} >= {"/api/account/register", "/api/account/login", "/api/account/me",
                                                     "/api/account/logout", "/api/account/logout-all", "/api/account/password",
                                                     "/api/account/password/reset-request", "/api/account/password/reset",
                                                     "/api/account/university", "/api/account/delete", "/api/account/link/{provider}",
                                                     "/api/account/login/{provider}", "/api/account/info"}
