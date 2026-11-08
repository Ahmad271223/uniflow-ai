"""Credit-Regel des Inhabers vom 08.11.2026 (docs/audit/AUDIT-2026-11-08-PAKET-21-22.md, Abschnitt "Credit-Regel 08.11.").

Credits je Kalendermonat (Europe/Berlin):
- 7-Tage-Probe ohne bezahltes Abo: 25
- Plus (bezahlt): 0 (keine StudiNow-KI)
- Pro AI (bezahlt): 100
Laufende Probe + Plus gekauft: 25, bis die Probe endet, danach 0. Laufende Probe + Pro AI gekauft: 100.
Vorher (docs/release/TESTFLIGHT-500-2026-11-08.md 7.1): Probe + Plus bekam 100, weil is_trial_account bei jedem bezahlten
Tarif "keine Probe" sagte und die Probe (Pro-AI-Umfang) den Rahmen bestimmte.
"""
from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta

import pytest
from conftest import asgi_call
from test_subscriptions import FakeAI, _j, hosted, user  # noqa: F401 - hosted ist eine Fixture

# Probe beginnt am 27.10., endet am 03.11.: der Monatswechsel liegt mitten in der Probe
T_START = datetime(2026, 10, 27, 10, 0, tzinfo=UTC)
T_OCT = datetime(2026, 10, 29, 10, 0, tzinfo=UTC)
T_NOV = datetime(2026, 11, 2, 10, 0, tzinfo=UTC)
T_AFTER = datetime(2026, 11, 5, 10, 0, tzinfo=UTC)
YEAR = (T_START + timedelta(days=365)).isoformat()


def _account(email: str) -> str:
    """Konto ohne die Probe der Registrierung, damit die Zeitpunkte frei waehlbar sind."""
    from app import accounts, billing
    uid = accounts.register(email, "sehr-geheim-123", "luh")["id"]
    conn = billing.connect()
    try:
        conn.execute("DELETE FROM entitlements WHERE user_id=?", (uid,))
    finally:
        conn.close()
    return uid


def _setup(uid: str, combo: str) -> None:
    from app import billing
    conn = billing.connect()
    try:
        parts = combo.split("+")
        if "trial" in parts:
            billing.start_trial(conn, uid, now=T_START)
        for paid in ("plus", "pro_ai"):
            if paid in parts:
                billing.set_entitlement(conn, uid, "app_store", paid, original_transaction_id=f"otid-{uid}",
                                        expires_at=YEAR, now=T_START)
    finally:
        conn.close()


def _balance(uid: str, now: datetime) -> dict:
    from app import credits
    conn = credits.connect()
    try:
        return credits.balance(conn, uid, now=now)
    finally:
        conn.close()


def _allowance(uid: str, now: datetime) -> tuple[int, str]:
    b = _balance(uid, now)
    return b["allowance"], b["plan"]


# Kombination, Zeitpunkt -> (Credits, Kennung in credit_months.plan)
CASES = [
    ("free", T_OCT, 0, "free"),
    ("trial", T_OCT, 25, "pro_ai:trial"),
    ("plus", T_OCT, 0, "plus"),
    ("pro_ai", T_OCT, 100, "pro_ai"),
    ("trial+plus", T_OCT, 25, "pro_ai:trial"),       # vorher 100 (der Fehler)
    ("trial+pro_ai", T_OCT, 100, "pro_ai"),
    ("trial+plus", T_AFTER, 0, "plus"),              # Probe abgelaufen + Plus
    ("trial+pro_ai", T_AFTER, 100, "pro_ai"),
    ("trial", T_AFTER, 0, "free"),                   # Probe abgelaufen, nichts gekauft
]


@pytest.mark.parametrize("combo,now,expected,label", CASES, ids=[f"{c[0]}@{c[1]:%m-%d}" for c in CASES])
def test_allowance_per_combination(hosted, combo, now, expected, label):
    uid = _account(f"{combo.replace('+', '-').replace('_', '')}-{now:%m%d}@beispiel.de")
    _setup(uid, combo)
    assert _allowance(uid, now) == (expected, label)


def test_trial_plus_drops_to_zero_when_the_trial_ends_in_the_same_month(hosted):
    from app import billing
    uid = _account("ende@beispiel.de")
    conn = billing.connect()
    try:
        billing.start_trial(conn, uid, now=T_NOV - timedelta(days=1))
        billing.set_entitlement(conn, uid, "app_store", "plus", original_transaction_id="otid-ende",
                                expires_at=(T_NOV + timedelta(days=30)).isoformat(), now=T_NOV)
    finally:
        conn.close()
    assert _allowance(uid, T_NOV) == (25, "pro_ai:trial")
    assert _allowance(uid, T_NOV + timedelta(days=7)) == (0, "plus"), "Probe vorbei: Plus hat keine Credits"


def test_trial_plus_upgrade_to_pro_ai_mid_month_gives_100(hosted):
    from app import billing
    uid = _account("upgrade@beispiel.de")
    _setup(uid, "trial+plus")
    assert _allowance(uid, T_OCT) == (25, "pro_ai:trial")
    conn = billing.connect()
    try:
        billing.set_entitlement(conn, uid, "app_store", "pro_ai", original_transaction_id=f"otid-{uid}", expires_at=YEAR, now=T_OCT)
    finally:
        conn.close()
    assert _allowance(uid, T_OCT) == (100, "pro_ai"), "Pro AI gekauft: sofort 100"


def test_month_change_in_the_middle_of_the_trial(hosted):
    """Rahmen je Kalendermonat: Oktober 25, im November eine neue Zeile mit 25 (Rest des Oktobers verfaellt), nach dem
    Ende der Probe 0."""
    from app import credits
    for combo in ("trial", "trial+plus"):
        uid = _account(f"wechsel-{combo.replace('+', '-')}@beispiel.de")
        _setup(uid, combo)
        conn = credits.connect()
        try:
            credits.reserve(conn, uid, "okt", "tutor:explain", 10, now=T_OCT)
            credits.settle(conn, uid, "okt", 90_000, now=T_OCT)     # 9 Cent = 10 Credits
        finally:
            conn.close()
        okt, nov, after = _balance(uid, T_OCT), _balance(uid, T_NOV), _balance(uid, T_AFTER)
        assert (okt["period"], okt["allowance"], okt["used"], okt["remaining"]) == ("2026-10", 25, 10, 15), combo
        assert (nov["period"], nov["allowance"], nov["used"], nov["remaining"]) == ("2026-11", 25, 0, 25), combo
        assert (after["period"], after["allowance"]) == ("2026-11", 0), combo


def test_trial_with_plus_uses_the_trial_pool(hosted):
    """Probe + Plus: die Credits sind Probe-Credits, also das Probe-Becken (is_trial_account); Probe + Pro AI nicht."""
    from app import ai_backend, billing
    a, b = _account("pool-plus@beispiel.de"), _account("pool-pro@beispiel.de")
    _setup(a, "trial+plus")
    _setup(b, "trial+pro_ai")
    conn = billing.connect()
    try:
        assert ai_backend.is_trial_account(conn, a, T_OCT) is True
        assert ai_backend.is_trial_account(conn, b, T_OCT) is False
        assert ai_backend.is_trial_account(conn, a, T_AFTER) is False
    finally:
        conn.close()


def test_users_plan_counts_like_a_paid_plan(hosted):
    """users.plan (Betrieb, `python -m app.accounts plan`): Plus neben der Probe -> 25, Pro AI -> 100."""
    from app import accounts
    uid = accounts.register("legacy@beispiel.de", "sehr-geheim-123", "luh")["id"]     # mit Probe ab jetzt
    now = datetime.now(UTC)
    assert _allowance(uid, now) == (25, "pro_ai:trial")
    accounts.set_plan(uid, "plus")
    assert _allowance(uid, now) == (25, "pro_ai:trial")
    accounts.set_plan(uid, "pro_ai")
    assert _allowance(uid, now) == (100, "pro_ai")


# ---------------------------------------------------------------- ueber die API

def _ask(app, headers, rid):
    return _j(asgi_call(app, "POST", "/api/ai/tutor", headers=headers,
                        body=json.dumps({"mode": "explain", "page_text": "Was ist ein Vektor?", "request_id": rid})))


def _ent(app, headers):
    st, d = _j(asgi_call(app, "GET", "/api/entitlements", headers=headers))
    assert st == 200, d
    return d


def test_api_trial_plus_shows_25_and_ai_works(hosted):
    from app import accounts, ai_backend, billing
    fake = FakeAI()
    ai_backend.set_provider(fake)
    st, d = _j(asgi_call(hosted, "POST", "/api/account/register",
                         body=json.dumps({"email": "api-pp@beispiel.de", "password": "sehr-geheim-123", "university": "luh"})))
    assert st == 201, d
    accounts.mark_email_verified(d["user"]["id"])
    h = {"Authorization": f"Bearer {d['token']}"}
    conn = billing.connect()
    try:
        billing.set_entitlement(conn, d["user"]["id"], "app_store", "plus", original_transaction_id="otid-api",
                                expires_at=(datetime.now(UTC) + timedelta(days=30)).isoformat())
    finally:
        conn.close()
    e = _ent(hosted, h)
    assert (e["plan"], e["paid_plan"], e["credits"]["allowance"], e["credits"]["plan"]) == ("pro_ai", "plus", 25, "pro_ai:trial")
    assert e["trial"]["active"] is True and e["access"]["state"] == "active"
    st, r = _ask(hosted, h, "pp-1")
    assert st == 200, r
    assert fake.calls == 1
    assert r["credits"]["allowance"] == 25 and r["credits"]["plan"] == "pro_ai:trial"


def test_api_plus_has_no_ai_and_zero_credits(hosted):
    from app import ai_backend
    fake = FakeAI()
    ai_backend.set_provider(fake)
    _, h = user(hosted, "nur-plus@beispiel.de", plan="plus")
    e = _ent(hosted, h)
    assert (e["plan"], e["credits"]["allowance"], e["credits"]["remaining"], e["credits"]["plan"]) == ("plus", 0, 0, "plus")
    assert e["entitlements"]["can_use_ai_explanations"] is False
    st, r = _ask(hosted, h, "plus-1")
    assert (st, r["code"], r["required_plan"]) == (403, "plan_required", "pro_ai"), r
    assert r["detail"] == "Diese Funktion gibt es ab StudiNow Pro AI."
    assert fake.calls == 0


def test_api_pro_ai_has_100(hosted):
    _, h = user(hosted, "pro@beispiel.de", plan="pro_ai")
    c = _ent(hosted, h)["credits"]
    assert (c["allowance"], c["remaining"], c["plan"]) == (100, 100, "pro_ai")
