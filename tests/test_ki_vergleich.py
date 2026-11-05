"""tools/ki-vergleich.py (docs/KI-VERGLEICH-2026-11-05.md): nur mit der Attrappe, nie ueber das Netz."""
import importlib.util
import json
import socket
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def _load():
    if "ki_vergleich" in sys.modules:
        return sys.modules["ki_vergleich"]
    spec = importlib.util.spec_from_file_location("ki_vergleich", ROOT / "tools" / "ki-vergleich.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["ki_vergleich"] = mod
    spec.loader.exec_module(mod)
    return mod


kv = _load()


@pytest.fixture(autouse=True)
def no_network(monkeypatch):
    def refuse(*a, **k):
        raise AssertionError("Netzzugriff im Test")
    monkeypatch.setattr(socket.socket, "connect", refuse)
    monkeypatch.setattr(kv.ai_backend, "urllib_transport", refuse)


def test_tasks_use_app_prompt_builders():
    tasks = kv.load_tasks()
    assert 18 <= len(tasks) <= 24
    assert len({t["id"] for t in tasks}) == len(tasks)
    kinds = {t["kind"] for t in tasks}
    assert kinds == {"explain", "steps", "flashcards", "week_test", "grade", "doc"}
    subjects = {t["subject"] for t in tasks}
    for s in ("Mathe/Analysis", "Signale und Systeme", "Elektrotechnik", "Informatik", "BWL", "Recht"):
        assert s in subjects
    by = {t["id"]: t for t in tasks}
    assert by["mathe-erklaeren"]["built"]["system"] == kv.ai.TUTOR_SYSTEM
    assert kv.ai.TUTOR_MODES["steps"] in by["mathe-loesen"]["built"]["prompt"]
    assert by["mathe-karteikarten"]["built"]["schema"] == kv.ai.FLASHCARDS_SCHEMA
    assert "genau 8 Karteikarten" in by["mathe-karteikarten"]["built"]["prompt"]
    assert "Genau 5 Aufgaben" in by["sus-wochentest"]["built"]["prompt"]
    assert by["et-bewerten"]["built"]["prompt"].startswith("Bewerte diesen Wochentest")
    doc = by["info-dokument"]["built"]
    assert doc["system"] == kv.de.SYSTEM and doc["step"]["kind"] == "full" and doc["max_output"] == kv.de.MAX_OUTPUT["full"]
    assert "[Seite 10]" in doc["prompt"]
    # Demo-Inhalt der App
    assert "Zweierkomplement" in by["info-erklaeren"]["built"]["prompt"]
    assert "Demo: Grundlagen der Informatik" in by["info-loesen"]["built"]["prompt"]


def test_deepseek_peak_and_costs():
    mon_2 = datetime(2026, 11, 2, 2, 30, tzinfo=timezone.utc)      # Montag 02:30 UTC
    mon_5 = datetime(2026, 11, 2, 5, 0, tzinfo=timezone.utc)
    mon_9 = datetime(2026, 11, 2, 9, 59, tzinfo=timezone.utc)
    mon_10 = datetime(2026, 11, 2, 10, 0, tzinfo=timezone.utc)
    sat_2 = datetime(2026, 11, 7, 2, 0, tzinfo=timezone.utc)
    assert kv.is_peak(mon_2) and kv.is_peak(mon_9)
    assert not kv.is_peak(mon_5) and not kv.is_peak(mon_10) and not kv.is_peak(sat_2)
    # 1 Mio. Eingabe (davon 400k Cache) + 1 Mio. Ausgabe
    assert kv.cost_usd("deepseek", mon_5, 1_000_000, 400_000, 1_000_000) == pytest.approx(0.6 * 0.15 + 0.4 * 0.003 + 0.60)
    assert kv.cost_usd("deepseek", mon_2, 1_000_000, 400_000, 1_000_000) == pytest.approx(0.6 * 0.30 + 0.4 * 0.006 + 1.20)
    assert kv.cost_usd("openai", mon_5, 1_000_000, 0, 1_000_000) == pytest.approx(0.10 + 0.50)
    assert kv.cost_usd("bedrock", mon_5, 1_000_000, 0, 1_000_000) == pytest.approx(2.20 + 11.00)


def test_dry_run_writes_everything(tmp_path):
    tasks = kv.load_tasks()
    out = tmp_path / "lauf"
    res = kv.run(tasks, list(kv.PROVIDERS), {}, out, dry=True, seed=1, log=lambda *_: None)
    lines = [json.loads(x) for x in (out / "results.jsonl").read_text().splitlines()]
    assert len(lines) == len(tasks) * 3
    assert all(r["error"] is None and r["skipped"] is None for r in lines)
    assert all(r["input_tokens"] > 0 and r["output_tokens"] > 0 and r["latency_s"] is not None for r in lines)
    assert {r["price_period"] for r in lines if r["provider"] == "deepseek"} <= {"peak", "offpeak"}
    assert any(r["cached_tokens"] > 0 for r in lines if r["provider"] == "deepseek")
    for t in tasks:
        for p in kv.PROVIDERS:
            assert (out / "answers" / t["id"] / f"{p}.md").exists()
    # Attrappe: OpenAI und Claude bestehen alle Pruefungen, DeepSeek hat eingebaute Fehler
    auto = {(r["task_id"], r["provider"]): r["auto"] for r in lines}
    assert all(auto[(t["id"], "openai")] == "pass" for t in tasks)
    assert auto[("mathe-loesen", "deepseek")] == "fail"
    assert auto[("sus-wochentest", "deepseek")] == "fail"        # MC-Loesung ausserhalb der Optionen
    # Blindbewertung: kein Anbieter- oder Modellname in der Seite, Zuordnung nur in key.json
    page = (out / "bewertung.html").read_text()
    for name in ("deepseek", "openai", "bedrock", "gpt-6", "claude", "sonnet"):
        assert name not in page.lower()
    key = json.loads((out / "key.json").read_text())
    assert set(key["labels"]) == {t["id"] for t in tasks}
    assert all(sorted(v) == ["A", "B", "C"] and sorted(v.values()) == sorted(kv.PROVIDERS) for v in key["labels"].values())
    assert "| Anbieter |" in (out / "summary.md").read_text()
    assert res["budgets"]["bedrock"] > 0


def test_budget_cap_stops_provider(tmp_path):
    tasks = kv.load_tasks()
    out = tmp_path / "lauf"
    kv.run(tasks, ["bedrock"], {}, out, dry=True, caps={"bedrock": 0.06}, seed=1, log=lambda *_: None)
    lines = [json.loads(x) for x in (out / "results.jsonl").read_text().splitlines()]
    done = [r for r in lines if r["skipped"] is None]
    skipped = [r for r in lines if r["skipped"]]
    assert done and skipped
    assert sum(r["cost_usd"] for r in done) <= 0.06
    assert "Budget" in skipped[0]["skipped"]
    assert "Budgetgrenze erreicht" in (out / "summary.md").read_text()


def test_keys_only_from_files_and_never_written(tmp_path):
    keys = tmp_path / "keys"
    keys.mkdir()
    assert kv.load_credentials(keys) == {}
    (keys / "openai.key").write_text("sk-test-geheim-123456\n")
    (keys / "bedrock.env").write_text("# Kommentar\nAWS_REGION=eu-central-1\nAWS_BEARER_TOKEN_BEDROCK=bedrock-geheim-987\n")
    creds = kv.load_credentials(keys)
    assert creds["openai"] == "sk-test-geheim-123456" and "deepseek" not in creds
    assert creds["bedrock"]["AWS_BEARER_TOKEN_BEDROCK"] == "bedrock-geheim-987"
    (keys / "bedrock.env").write_text("AWS_REGION=eu-central-1\n")
    assert "bedrock" not in kv.load_credentials(keys)              # ohne Zugangsdaten
    (keys / "bedrock.env").write_text("AWS_REGION=eu-central-1\nAWS_BEARER_TOKEN_BEDROCK=bedrock-geheim-987\n")
    creds = kv.load_credentials(keys)
    assert kv.redact("Fehler mit sk-test-geheim-123456 und bedrock-geheim-987", kv.secrets_of(creds)).count("geheim") == 0
    out = tmp_path / "lauf"
    tasks = [t for t in kv.load_tasks() if t["id"] in ("et-loesen", "bwl-karteikarten")]
    kv.run(tasks, ["openai", "bedrock"], creds, out, dry=True, seed=1, log=lambda *_: None)
    for f in out.rglob("*"):
        if f.is_file():
            assert "geheim" not in f.read_text()


def test_main_skips_providers_without_key_file(tmp_path, capsys):
    rc = kv.main(["--keys-dir", str(tmp_path), "--out", str(tmp_path / "x")])
    assert rc == 1
    assert "übersprungen: DeepSeek" in capsys.readouterr().out
    assert not (tmp_path / "x").exists()


def test_deepseek_request_body():
    p = kv.DeepSeekDirect("k", "deepseek-flash")
    b = p.request_body("S", "P", kv.ai.FLASHCARDS_SCHEMA, max_output_tokens=3000)
    assert p.base_url == "https://api.deepseek.com" and b["model"] == "deepseek-flash"
    assert b["response_format"] == {"type": "json_object"} and b["max_tokens"] == 3000 and "reasoning_effort" not in b
    assert b["messages"][0] == {"role": "system", "content": "S"}


def test_checks_on_realistic_answers():
    by = {t["id"]: t for t in kv.load_tasks()}
    good = ("**Schritt 1:** $f'(x) = 3x^2 - 12x + 9 = 3(x-1)(x-3)$\n\nHochpunkt $H(1 \\mid 5)$, Tiefpunkt $T(3|1)$.\n"
            "Wendepunkt: $f''(x)=6x-12=0$, also $W(2|3)$.")
    assert kv.auto_status(kv.check(by["mathe-loesen"], good)) == "pass"
    wrong = good.replace("T(3|1)", "T(3|2)")
    assert kv.auto_status(kv.check(by["mathe-loesen"], wrong)) == "fail"
    lap = ("$$X(s) = \\frac{3}{s+2}, \\quad \\text{Re}\\{s\\} > -2$$\nPole bei $s=-1$ und $s=-4$, beide links: "
           "das System ist stabil.")
    assert kv.auto_status(kv.check(by["sus-loesen"], lap)) == "pass"
    info = ("1. 42 = 0010 1010, 100 = 0110 0100, 255 = 1111 1111\n2. 1011 0110 = 128+32+16+4+2 = 182\n"
            "3. 37 = 0010 0101 -> invertiert 1101 1010 -> +1 = 1101 1011")
    assert kv.auto_status(kv.check(by["info-loesen"], info)) == "pass"
    et = "I = 12 V / 6 kΩ = 2 mA\nU₁ = 4 V, U2 = 8 V\nP = 8 V · 2 mA = 16 mW"
    assert kv.auto_status(kv.check(by["et-loesen"], et)) == "pass"
    q = {"type": "mc", "options": ["A Eins", "B Zwei"], "answer": "B"}
    assert kv.mc_key_ok(q) and kv.mc_key_ok({**q, "answer": "B Zwei"}) and not kv.mc_key_ok({**q, "answer": "C"})
    assert kv.mc_key_ok({"options": ["Eins", "Zwei"], "answer": "Zwei"})


def test_evaluate_merges_export_with_key(tmp_path):
    tasks = [t for t in kv.load_tasks() if t["id"] in ("mathe-loesen", "recht-erklaeren")]
    out = tmp_path / "lauf"
    res = kv.run(tasks, list(kv.PROVIDERS), {}, out, dry=True, seed=3, log=lambda *_: None)
    labels = res["key"]["labels"]
    grades = {}
    for tid, m in labels.items():
        grades[tid] = {}
        for letter, p in m.items():
            v = 5 if p == "openai" else 3
            grades[tid][letter] = {"richtigkeit": v, "verstaendlichkeit": v, "vollstaendigkeit": v, "note": ""}
    exp = tmp_path / "export.json"
    exp.write_text(json.dumps({"run": out.name, "grades": grades}))
    text = kv.evaluate(out, exp)
    row = next(line for line in text.splitlines() if line.startswith("| OpenAI"))
    assert "| 5.00 | 5.00 | 5.00 | 5.00 | 2 |" in row
    assert list(out.glob("auswertung-*.md"))
