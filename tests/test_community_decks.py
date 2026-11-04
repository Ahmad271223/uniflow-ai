"""Karteikarten teilen und nutzen im Dienst (04.11.2026, app/community_decks.py): Stapel je Lehrwoche oder fuers ganze
Modul in einer Kurs-Community, nur fuer Mitglieder, Pseudonyme statt Konto-IDs, Tarif Plus, bestaetigte E-Mail,
Tagesgrenze, Groessengrenzen, ein Stapel je Woche und Konto (Aktualisieren), Uebernehmen (einmal gezaehlt), Zurueckziehen,
Melden (ab 3 verborgen), Moderation, Konto loeschen und Datenexport."""
import io
import json
import zipfile

import pytest
from conftest import asgi_call
from test_community_qa import KEY, _j, _member, call, course_key


@pytest.fixture
def hosted(app, monkeypatch):
    from app import accounts, community, config
    monkeypatch.setattr(config, "MODE", "hosted")
    accounts.db_path().unlink(missing_ok=True)
    community.db_path().unlink(missing_ok=True)
    yield app
    accounts.db_path().unlink(missing_ok=True)
    community.db_path().unlink(missing_ok=True)


def _user(app, email, plan="plus", verified=True, member=True):
    from app import accounts
    st, d = _j(asgi_call(app, "POST", "/api/account/register", body=json.dumps({"email": email, "password": "sehr-geheim-123", "university": "luh"})))
    assert st == 201, d
    accounts.end_trial(d["user"]["id"])
    if verified:
        accounts.mark_email_verified(d["user"]["id"])
    if plan != "free":
        accounts.set_plan(d["user"]["id"], plan)
    if member:
        _member(d["user"]["id"])
    return d["user"], {"Authorization": f"Bearer {d['token']}"}


CARDS = [{"question": "Was ist eine Reihe?", "answer": "Folge der Partialsummen"},
         {"question": "Quotientenkriterium?", "answer": "lim |a_{n+1}/a_n| < 1"},
         {"question": " was ist eine REIHE? ", "answer": "doppelt, faellt weg"},
         {"question": "", "answer": "leer, faellt weg"}]


def publish(app, h, week=5, cards=CARDS, title="Woche 5: Reihen", key=KEY):
    return call(app, "POST", f"/communities/{key}/decks", h, {"title": title, "lecture_week": week, "cards": cards})


def test_publish_list_view_adopt_update_withdraw(hosted):
    app = hosted
    author, ha = _user(app, "autor@example.org")
    reader, hr = _user(app, "leser@example.org")
    _, hfree = _user(app, "frei@example.org", plan="free")
    _, hout = _user(app, "fremd@example.org", member=False)
    st, d = publish(app, ha)
    assert st == 201 and d["card_count"] == 2 and d["mine"] and d["lecture_week"] == 5, d
    assert d["cards"] == CARDS[:2] and d["pseudonym"].startswith("Studi-") and d["uses"] == 0
    did = d["id"]
    st, mod = publish(app, ha, week=None, title="")
    assert st == 201 and mod["title"] == "Karteikarten zum Modul" and mod["lecture_week"] is None
    # Liste fuer Mitglieder (auch Free darf lesen), Filter je Woche, Zahlen je Woche
    st, lst = call(app, "GET", f"/communities/{KEY}/decks", hr)
    assert st == 200 and lst["weeks"] == {"5": 1, "module": 1} and len(lst["decks"]) == 2
    assert not lst["decks"][0]["mine"] and lst["decks"][0]["preview"] and "cards" not in lst["decks"][0]
    assert [x["id"] for x in call(app, "GET", f"/communities/{KEY}/decks?week=5", hr)[1]["decks"]] == [did]
    assert [x["id"] for x in call(app, "GET", f"/communities/{KEY}/decks?week=module", hfree)[1]["decks"]] == [mod["id"]]
    assert call(app, "GET", f"/communities/{KEY}/decks?week=99", hr)[1]["code"] == "week_invalid"
    # Nicht-Mitglieder sehen weder Liste noch Stapel
    st, e = call(app, "GET", f"/communities/{KEY}/decks", hout)
    assert (st, e["code"]) == (403, "not_a_member")
    assert call(app, "GET", f"/decks/{did}", hout)[0] == 404 and call(app, "POST", f"/decks/{did}/adopt", hout)[0] == 404
    assert call(app, "GET", f"/communities/{course_key('luh', 'anderer')}/decks", hr)[0] == 403
    # ansehen, uebernehmen (einmal gezaehlt; Free darf nicht uebernehmen)
    st, full = call(app, "GET", f"/decks/{did}", hr)
    assert st == 200 and full["cards"] == CARDS[:2]
    st, e = call(app, "POST", f"/decks/{did}/adopt", hfree)
    assert (st, e["code"]) == (403, "plan_required")
    st, a = call(app, "POST", f"/decks/{did}/adopt", hr)
    assert st == 200 and a["cards"] == CARDS[:2] and a["origin"] == f"community:{did}" and a["deck"]["uses"] == 1 and a["deck"]["used_by_me"]
    assert call(app, "POST", f"/decks/{did}/adopt", hr)[1]["deck"]["uses"] == 1, "jedes Konto zaehlt einmal"
    assert call(app, "POST", f"/decks/{did}/adopt", ha)[1]["deck"]["uses"] == 1, "der Autor zaehlt nicht"
    # ein Stapel je Konto, Community und Woche: 409 mit deck_id, dann ersetzen
    st, e = publish(app, ha)
    assert (st, e["code"], e["deck_id"]) == (409, "already_published", did)
    st, up = call(app, "PUT", f"/decks/{did}", ha, {"cards": CARDS[:1], "title": "Neu"})
    assert st == 200 and up["card_count"] == 1 and up["title"] == "Neu" and up["updated_at"] and up["uses"] == 1
    assert call(app, "PUT", f"/decks/{did}", hr, {"cards": CARDS[:1]})[1]["code"] == "not_owner"
    st, mine = call(app, "GET", "/decks/mine", ha)
    assert st == 200 and {x["id"] for x in mine["decks"]} == {did, mod["id"]}
    # zurueckziehen: nur der Autor; danach weg und die Karten geleert
    assert call(app, "DELETE", f"/decks/{did}", hr)[1]["code"] == "not_owner"
    assert call(app, "DELETE", f"/decks/{did}", ha)[1] == {"withdrawn": True, "already": False}
    assert call(app, "GET", f"/decks/{did}", hr)[0] == 404 and call(app, "GET", f"/decks/{did}", ha)[0] == 404
    from app import community
    with community.cursor() as conn:
        assert tuple(conn.execute("SELECT cards, card_count FROM flashcard_decks WHERE id=?", (did,)).fetchone()) == ("[]", 0)
    assert publish(app, ha)[0] == 201, "nach dem Zurueckziehen wieder teilen"
    # nie Konto-ID oder E-Mail nach aussen
    for path in (f"/communities/{KEY}/decks", "/decks/mine", f"/decks/{mod['id']}"):
        raw = json.dumps(call(app, "GET", path, hr)[1])
        assert author["id"] not in raw and "autor@example.org" not in raw and reader["id"] not in raw, path


def test_rules_plan_email_member_limits(hosted, monkeypatch):
    app = hosted
    _, hfree = _user(app, "frei2@example.org", plan="free")
    _, hunv = _user(app, "unbestaetigt@example.org", verified=False)
    _, hout = _user(app, "drausen@example.org", member=False)
    _, h = _user(app, "ok@example.org")
    assert publish(app, hfree)[1]["code"] == "plan_required"
    assert publish(app, hunv)[1]["code"] == "email_unverified"
    st, e = publish(app, hout)
    assert (st, e["code"]) == (403, "not_a_member")
    assert publish(app, h, cards=[{"question": "q", "answer": "a"}] * 501)[1]["code"] == "too_many_cards"
    assert publish(app, h, cards=[{"question": "q", "answer": "x" * 1001}])[1]["code"] == "text_too_long"
    assert publish(app, h, cards=[{"question": "", "answer": "a"}])[1]["code"] == "cards_invalid"
    assert publish(app, h, title="t" * 121)[1]["code"] == "text_too_long"
    assert publish(app, h, week=0)[1]["code"] == "week_invalid"
    assert call(app, "POST", "/communities/kein-schluessel/decks", h, {"cards": CARDS})[1]["code"] == "community_invalid"
    many = [{"question": f"Frage {i}", "answer": f"Antwort {i}"} for i in range(500)]
    st, d = publish(app, h, week=1, cards=many)
    assert st == 201 and d["card_count"] == 500
    # Tagesgrenze neuer Stapel
    monkeypatch.setenv("LERNAPP_LIMIT_DECK_USER", "2/1440")
    assert publish(app, h, week=2)[0] == 201
    st, e = publish(app, h, week=3)
    assert (st, e["code"]) == (429, "rate_limited"), e


def test_report_hides_after_three_and_moderation_restores(hosted):
    from app import accounts
    app = hosted
    author, ha = _user(app, "autor3@example.org")
    did = publish(app, ha)[1]["id"]
    assert call(app, "POST", f"/decks/{did}/report", ha, {"reason": "spam"})[1]["code"] == "own_post"
    reporters = [_user(app, f"melder{i}@example.org")[1] for i in range(3)]
    _, hunv = _user(app, "melder-unbestaetigt@example.org", verified=False)
    assert call(app, "POST", f"/decks/{did}/report", hunv, {"reason": "spam"})[1]["code"] == "email_unverified"
    assert call(app, "POST", f"/decks/{did}/report", reporters[0], {"reason": "quatsch"})[1]["code"] == "reason_invalid"
    assert call(app, "POST", f"/decks/{did}/report", reporters[0], {"reason": "spam"})[1] == {"reported": True, "hidden": False, "reports": 1}
    assert call(app, "POST", f"/decks/{did}/report", reporters[0], {"reason": "spam"})[1]["code"] == "already_reported"
    call(app, "POST", f"/decks/{did}/report", reporters[1], {"reason": "offensive"})
    assert call(app, "POST", f"/decks/{did}/report", reporters[2], {"reason": "other"})[1]["hidden"] is True
    assert call(app, "GET", f"/communities/{KEY}/decks", reporters[0])[1]["decks"] == []
    assert call(app, "GET", f"/decks/{did}", reporters[0])[0] == 404
    assert call(app, "GET", f"/decks/{did}", ha)[1]["status"] == "hidden", "der Autor sieht seinen verborgenen Stapel"
    assert call(app, "PUT", f"/decks/{did}", ha, {"cards": CARDS})[1]["code"] == "deck_blocked"
    # Moderation
    admin, hadm = _user(app, "admin@example.org")
    accounts.set_role(admin["id"], "admin")
    st, mod = call(app, "GET", "/moderation", hadm)
    assert st == 200 and [d["id"] for d in mod["decks"]] == [did] and mod["decks"][0]["report_count"] == 3
    assert "Was ist eine Reihe?" in mod["decks"][0]["text"] and len(mod["decks"][0]["reports"]) == 3
    assert author["id"] not in json.dumps(mod["decks"])
    assert call(app, "POST", f"/decks/{did}/moderate", reporters[0], {"action": "restore"})[0] == 403
    st, r = call(app, "POST", f"/decks/{did}/moderate", hadm, {"action": "restore"})
    assert st == 200 and r["status"] == "active" and r["kind"] == "deck"
    assert [d["id"] for d in call(app, "GET", f"/communities/{KEY}/decks", reporters[0])[1]["decks"]] == [did]
    # gesperrte Autoren sind unsichtbar
    from app import community
    with community.cursor() as conn:
        conn.execute("INSERT INTO bans(author_id, created_at) VALUES (?, '2026-11-04T00:00:00Z')", (author["id"],))
    assert call(app, "GET", f"/communities/{KEY}/decks", reporters[0])[1]["decks"] == []
    assert publish(app, ha, week=7)[1]["code"] == "author_banned"


def test_account_deletion_and_export(hosted):
    from app import accounts, community
    app = hosted
    u, h = _user(app, "weg@example.org")
    _, other = _user(app, "bleibt@example.org")
    did = publish(app, h)[1]["id"]
    keep = publish(app, other)[1]["id"]
    call(app, "POST", f"/decks/{keep}/adopt", h)
    call(app, "POST", f"/decks/{keep}/report", h, {"reason": "spam"})
    st, _, raw = asgi_call(app, "GET", "/api/account/export", headers=h)
    assert st == 200
    exp = json.loads(zipfile.ZipFile(io.BytesIO(raw)).read("community/meine-karteikarten.json"))
    assert [x["id"] for x in exp] == [did] and exp[0]["cards"] == CARDS[:2] and "author_id" not in exp[0]
    # Konto loeschen: sofort unsichtbar, beim endgueltigen Loeschen weg samt Meldungen und Nutzungen
    accounts.delete_account(u["id"], "sehr-geheim-123")
    assert [d["id"] for d in call(app, "GET", f"/communities/{KEY}/decks", other)[1]["decks"]] == [keep]
    community.forget_author(u["id"])
    with community.cursor() as conn:
        assert conn.execute("SELECT COUNT(*) FROM flashcard_decks WHERE author_id=?", (u["id"],)).fetchone()[0] == 0
        assert conn.execute("SELECT COUNT(*) FROM deck_reports WHERE reporter_id=?", (u["id"],)).fetchone()[0] == 0
        assert conn.execute("SELECT COUNT(*) FROM deck_uses WHERE user_id=?", (u["id"],)).fetchone()[0] == 0
        assert conn.execute("SELECT COUNT(*) FROM flashcard_decks").fetchone()[0] == 1


def test_adopted_cards_land_in_the_own_stack_with_origin(hosted):
    """Uebernehmen im Browser: Karten aus /decks/{id}/adopt mit POST /api/flashcards/stack in den eigenen Stapel
    (Herkunft community:<id>); doppelt uebernehmen legt nichts doppelt an."""
    from app import config, db
    app = hosted
    _, ha = _user(app, "teilt@example.org")
    reader, hr = _user(app, "nutzt@example.org")
    did = publish(app, ha)[1]["id"]
    tok = config.set_user_context(reader["id"], "luh")
    try:
        db.init_db()
        with db.cursor() as conn:
            mid = conn.execute("INSERT INTO modules(name) VALUES ('Analysis')").lastrowid
    finally:
        config.reset_user_context(tok)
    a = call(app, "POST", f"/decks/{did}/adopt", hr)[1]
    for expect in (2, 0):
        st, _, raw = asgi_call(app, "POST", "/api/flashcards/stack", headers=hr,
                               body=json.dumps({"module_id": mid, "lecture_week": a["deck"]["lecture_week"], "cards": a["cards"], "origin": a["origin"]}))
        assert st == 200 and json.loads(raw)["added"] == expect, raw
    st, _, raw = asgi_call(app, "GET", "/api/flashcards/stacks", headers=hr)
    s = next(x for x in json.loads(raw)["stacks"] if x["module_id"] == mid)
    assert (s["lecture_week"], s["count"], s["origins"]["community"]) == (5, 2, 2)
