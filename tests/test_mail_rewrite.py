"""Uni-Mail "Mit KI verbessern" (13.11.2026, Inhaber: "ab Pro AI, Pro hat 50 KI-Mails"): Aufgabe `mail` der StudiNow-KI
(app/ai_relay.py), Kontingent ai_mail (plans.QUOTAS, 50 je Monat), ohne Credits; Prompt und System-Text gleich auf dem
iPad (UniFlowCore/AI/MailRewrite.swift). 26.11.2026 neues Modell: ab Plus (50 je Monat), nur mit verfuegbaren Credits."""
import json
from pathlib import Path

import pytest
from test_ai_relay import account, link, pc  # noqa: F401  (Fixture)

ROOT = Path(__file__).resolve().parents[1]
SWIFT = ROOT / "apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/AI/MailRewrite.swift"


def test_quota_is_fifty_a_month_from_plus():
    """26.11.2026 neues Modell: Plus hat die Kontingente von Pro AI (50 KI-Mails, frueher 0); die KI-Mail gehoert zur
    StudiNow-KI und geht nur mit verfuegbaren Credits (kostet selbst keine)."""
    from app import plans
    assert plans.QUOTAS["pro_ai"]["ai_mail"] == 50
    assert plans.QUOTAS["plus"]["ai_mail"] == 50 and plans.QUOTAS["free"]["ai_mail"] == 0
    assert plans.QUOTA_LABELS["ai_mail"] == "E-Mails mit KI verbessern"
    fx = json.loads((ROOT / "packages/shared-contracts/fixtures/plans/plans.json").read_text(encoding="utf-8"))
    assert fx["plans"]["pro_ai"]["quotas"]["ai_mail"] == 50, "Fixture neu erzeugt (tools/gen-plans-fixture.py)"


def test_prompt_marks_the_mail_as_material_and_keeps_it_short():
    from app import ai
    p = ai.mail_prompt("  Frage   zur Klausur ", "hallo herr meier\nich wollte fragen ob ")
    assert p.splitlines()[0] == "Verbessere diese E-Mail."
    assert "Betreff (nur zum Verstehen): Frage zur Klausur" in p
    assert ai.UNTRUSTED in p and p.endswith("<<<\nhallo herr meier\nich wollte fragen ob\n>>>")
    assert "(kein Betreff)" in ai.mail_prompt("", "x")
    assert len(ai.mail_prompt("", "a" * 20000)) < ai.MAIL_TEXT_MAX + 400
    assert "erfinde nichts" in ai.MAIL_INSTRUCTION and "NUR mit dem verbesserten Text" in ai.MAIL_INSTRUCTION


def test_ipad_uses_the_same_texts():
    from app import ai
    swift = SWIFT.read_text(encoding="utf-8")
    assert json.dumps(ai.MAIL_INSTRUCTION, ensure_ascii=False) in swift
    for line in ("Verbessere diese E-Mail.", "Betreff (nur zum Verstehen): ", "(kein Betreff)", "TEXT DER E-MAIL. "):
        assert line in swift, line
    assert f"textMax = {ai.MAIL_TEXT_MAX}" in swift and f"subjectMax = {ai.MAIL_SUBJECT_MAX}" in swift


def test_relay_task_mail_counts_fifty_and_costs_no_credits(pc, monkeypatch):  # noqa: F811
    app, _, fake = pc
    from app import ai, ai_relay, plans
    monkeypatch.setitem(plans.QUOTAS, "pro_ai", {**plans.QUOTAS["pro_ai"], "ai_mail": 2})
    account(app, "mail@beispiel.de")
    link(app, "mail@beispiel.de")
    prompt = ai.mail_prompt("Klausur", "hallo ich hab ne frage")
    r = ai_relay.complete("mail", prompt)
    assert r["answer"] and fake.calls == 1
    assert (r.get("credits") or {}).get("charged", 0) == 0, "KI-Mails kosten keine Credits"
    assert ai_relay.complete("mail", prompt)["answer"]
    with pytest.raises(ai_relay.RelayError) as e:
        ai_relay.complete("mail", prompt)
    assert (e.value.status, e.value.code) == (429, "quota_exhausted"), (e.value.status, e.value.code)
    assert fake.calls == 2, "aufgebraucht: kein Aufruf der KI"


@pytest.mark.parametrize("plan", ["plus", "free"])
def test_relay_task_mail_needs_credits(pc, plan):  # noqa: F811
    """26.11.2026 neues Modell: Free hat die KI-Mail nicht (402/403); Plus hat sie, ohne Credits aber 429
    credits_exhausted (frueher 403); mit gekauften Credits geht sie und kostet keine."""
    app, _, fake = pc
    from app import ai, ai_relay
    from test_subscriptions import give_credits
    u = account(app, f"mail-{plan}@beispiel.de", plan=plan)
    link(app, f"mail-{plan}@beispiel.de")
    with pytest.raises(ai_relay.RelayError) as e:
        ai_relay.complete("mail", ai.mail_prompt("x", "y"))
    if plan == "free":
        assert e.value.status in (402, 403), (e.value.status, e.value.code)
    else:
        assert (e.value.status, e.value.code) == (429, "credits_exhausted")
    assert fake.calls == 0
    if plan == "plus":
        give_credits(u["id"], 50)
        r = ai_relay.complete("mail", ai.mail_prompt("x", "y"))
        assert r["answer"] and fake.calls == 1
        assert (r.get("credits") or {}).get("charged", 0) == 0, "KI-Mails kosten keine Credits"
