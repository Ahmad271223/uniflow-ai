"""Entscheidungen des Inhabers vom 08.11.2026 zu den Audit-Befunden P42-05 und P43-06
(docs/audit/AUDIT-2026-11-08-PAKET-42-43.md, Abschnitt "Entscheidungen 08.11.").

P43-06: Das Kontingent `card_stacks_adopted` (Plus 4 Stapel je Kalendermonat) zaehlt je Konto ueber alle Geraete. Das
iPad uebernimmt Stapel aus der Community ueber iCloud (die Stapel kennt der Dienst nicht); mit StudiNow-Konto meldet es
jede Uebernahme an POST /api/community/card-stacks/adopt-quota und der Dienst zaehlt im vorhandenen Kontingent
(billing.consume, once=True), nicht in einem zweiten. Der Monat ist der Kalendermonat in Europe/Berlin.

P42-05: Im Dienst-Weg loescht der Loesungsautor einen fremden Kommentar wirklich (Text weg) - dort bleibt "Löschen"
ehrlich; die Texte kommen nicht vom Dienst.
"""
from __future__ import annotations

import json
from datetime import datetime, timezone

from conftest import asgi_call
from test_audit_paket_38_39 import _cm, world  # noqa: F401 - world ist eine Fixture
from test_subscriptions import _j, hosted, user  # noqa: F401 - hosted ist eine Fixture

UTC = timezone.utc
PATH = "/api/community/card-stacks/adopt-quota"


def _login(app, email):
    st, d = _j(asgi_call(app, "POST", "/api/account/login", body=json.dumps({
        "email": email, "password": "sehr-geheim-123", "device_id": "ipad-zwei", "device_name": "Zweites iPad"})))
    assert st == 200, d
    return {"Authorization": f"Bearer {d['token']}"}


def _count(app, headers, ref):
    return _j(asgi_call(app, "POST", PATH, body=json.dumps({"ref": ref}), headers=headers))


def test_p43_06_adopt_quota_counts_per_account_across_devices(hosted):
    u, ipad1 = user(hosted, "stapel-konto@beispiel.de", plan="plus")
    ipad2 = _login(hosted, "stapel-konto@beispiel.de")                  # zweites Geraet, dasselbe Konto
    st, d = _count(hosted, ipad1, "community:stapel-1")
    assert st == 200 and d["ok"] is True and d["counted"] is True and (d["used"], d["limit"]) == (1, 4), d
    # derselbe Stapel auf dem anderen Geraet: zaehlt im Monat nicht noch einmal
    st, d = _count(hosted, ipad2, "community:stapel-1")
    assert st == 200 and d["ok"] is True and d["counted"] is False and d["used"] == 1, d
    for i in (2, 3, 4):
        st, d = _count(hosted, ipad1 if i % 2 else ipad2, f"community:stapel-{i}")
        assert st == 200 and d["ok"] is True and d["used"] == i, d
    # der fuenfte Stapel ist auf jedem Geraet des Kontos zu viel (kein 429: das iPad liest ok/used/limit)
    st, d = _count(hosted, ipad2, "community:stapel-5")
    assert st == 200 and d["ok"] is False and d["counted"] is False and (d["used"], d["limit"]) == (4, 4), d
    st, d = _count(hosted, ipad1, "week:7:3:vorlesung")
    assert st == 200 and d["ok"] is False, d
    # schon gezaehlte Stapel bleiben erlaubt
    st, d = _count(hosted, ipad1, "community:stapel-3")
    assert st == 200 and d["ok"] is True and d["counted"] is False, d
    # GET /api/entitlements zeigt denselben Stand (Vorabpruefung der Wochenstapel auf dem iPad)
    st, e = _j(asgi_call(hosted, "GET", "/api/entitlements", headers=ipad2))
    assert st == 200 and e["quotas"]["card_stacks_adopted"]["used"] == 4 and e["quotas"]["card_stacks_adopted"]["limit"] == 4, e
    # ein anderes Konto hat sein eigenes Kontingent
    _, other = user(hosted, "stapel-andere@beispiel.de", plan="plus")
    st, d = _count(hosted, other, "community:stapel-5")
    assert st == 200 and d["ok"] is True and d["used"] == 1, d


def test_p43_06_adopt_quota_needs_an_account_and_a_sane_ref(hosted):
    st, _ = _count(hosted, {}, "community:x")
    assert st == 401
    _, h = user(hosted, "stapel-ref@beispiel.de", plan="plus")
    for bad in ("", " ", "x" * 201, "a b", "<script>", None, 5):
        st, d = _j(asgi_call(hosted, "POST", PATH, body=json.dumps({"ref": bad}), headers=h))
        assert st == 400 and d["code"] == "ref_invalid", (bad, st, d)
    # Free: Grenze 0, der Dienst sagt ehrlich "aufgebraucht" (das iPad entscheidet dann nach seinem Tarif)
    _, free = user(hosted, "stapel-free@beispiel.de")
    st, d = _count(hosted, free, "community:x")
    assert st == 200 and d["ok"] is False and d["limit"] == 0, d


def test_p43_06_adopt_quota_month_is_the_calendar_month_in_berlin(hosted):
    """Der Monatswechsel des Kontingents folgt Europe/Berlin (wie die Credits), nicht UTC: 30.11. 23:30 UTC ist in
    Berlin schon der 01.12. Die anderen Kontingente bleiben unveraendert (UTC-Monat, Audit P21-10)."""
    from app import billing
    uid = user(hosted, "stapel-monat@beispiel.de", plan="plus")[0]["id"]
    late_nov_utc = datetime(2026, 11, 30, 23, 30, tzinfo=UTC)          # Berlin: 01.12. 00:30
    still_nov = datetime(2026, 11, 30, 22, 30, tzinfo=UTC)             # Berlin: 30.11. 23:30
    summer = datetime(2026, 6, 30, 22, 30, tzinfo=UTC)                 # Sommerzeit: Berlin 01.07. 00:30
    conn = billing.connect()
    try:
        assert billing.consume(conn, uid, "card_stacks_adopted", "a", now=still_nov, plan="plus").period == "2026-11"
        r = billing.consume(conn, uid, "card_stacks_adopted", "b", now=late_nov_utc, plan="plus")
        assert (r.period, r.used) == ("2026-12", 1), r
        assert billing.used(conn, uid, "card_stacks_adopted", late_nov_utc) == 1
        assert billing.used(conn, uid, "card_stacks_adopted", still_nov) == 1
        assert billing.consume(conn, uid, "card_stacks_adopted", "c", now=summer, plan="plus").period == "2026-07"
        assert billing.status(conn, {"id": uid, "plan": "plus"}, late_nov_utc)["quotas"]["card_stacks_adopted"]["period"] == "2026-12"
        # andere Kontingente: Monat wie bisher
        assert billing.consume(conn, uid, "ai_tests_new", "d", now=late_nov_utc, plan="plus").period == "2026-11"
    finally:
        conn.close()


def test_p42_05_solution_author_really_deletes_foreign_comments_in_the_service(world):
    """Dienst-Weg: Der Loesungsautor entfernt einen fremden Kommentar; Status `deleted`, der Text ist in der Datenbank
    weg. Darum bleibt dort "Löschen" ehrlich (die Oberflaechentexte kommen aus den Apps, nicht vom Dienst; die Antwort
    ist {"deleted": true})."""
    from app import community
    sol_c = world["ids"]["c_solution"]
    st, c = _cm(world, world["ha"], "POST", f"/solutions/{sol_c}/comments", {"text": "Text von A unter C"})
    assert st in (200, 201), c
    st, d = _cm(world, world["hc"], "DELETE", f"/comments/{c['id']}")             # C ist Loesungsautor
    assert st == 200 and d == {"deleted": True, "id": c["id"]}, d
    with community.cursor() as conn:
        row = conn.execute("SELECT status, text FROM comments WHERE id=?", (c["id"],)).fetchone()
    assert (row["status"], row["text"]) == ("deleted", ""), dict(row)
