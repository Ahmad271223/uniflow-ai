"""Geteilte Karteikarten-Stapel im Dienst: was aus der Cloud-Sitzung vom 04.11.2026 (app/community_decks.py dort) in das
Stapel-Modell (app/community_cards.py, app/community_cards_api.py) uebernommen wurde - Ersetzen der geteilten Kopie,
Zahl der Stapel je Woche in der Liste, Tagesgrenze `deck_user`, gebannte Autoren teilen nicht, Moderation (Liste und
Freigabe), Bann/Konto loeschen zieht sofort zurueck, Datenexport. Teilen, Liste, Uebernehmen, Like und Melden selbst
pinnt tests/test_flashcard_share.py."""
import io
import json
import zipfile

from conftest import asgi_call
from test_flashcard_share import _call, _member, _seed_user, _stack_with_cards
from test_subscriptions import hosted, user  # noqa: F401 - hosted ist eine Fixture

CARDS = (("Was ist eine Reihe?", "Folge der Partialsummen"), ("Quotientenkriterium?", "lim |a_{n+1}/a_n| < 1"))


def _setup(app, email, plan="plus"):
    from app.solution_format import community_module_key
    u, h = user(app, email, plan=plan)
    _seed_user(app, h)
    key = community_module_key("luh", "Analysis I")
    _member(app, h, key)
    return u, h, key


def test_replace_shared_copy_and_week_counts(hosted):
    ada, ha, key = _setup(hosted, "ada-ersetzt@beispiel.de")
    ben, hb, _ = _setup(hosted, "ben-liest@beispiel.de")
    w5 = _stack_with_cards(hosted, ha, "Analysis I", name="Woche 5", week=5, cards=CARDS)
    gen = _stack_with_cards(hosted, ha, "Analysis I", name="Formeln", cards=CARDS[:1])
    sh = _call(hosted, "POST", f"/api/flashcard-stacks/{w5['id']}/share", headers=ha)
    _call(hosted, "POST", f"/api/flashcard-stacks/{gen['id']}/share", headers=ha)
    # Zahlen je Woche unabhaengig vom Filter ("0" = Allgemein)
    lst = _call(hosted, "GET", f"/api/community/card-stacks?module={key}&week=5", headers=hb)
    assert lst["weeks"] == {"5": 1, "0": 1} and [x["id"] for x in lst["stacks"]] == [sh["id"]]
    # Ben uebernimmt, Ada ergaenzt eine Karte und ersetzt die geteilte Kopie: Kennung, Uebernahmen bleiben
    ad = _call(hosted, "POST", f"/api/community/card-stacks/{sh['id']}/adopt", headers=hb)
    _call(hosted, "POST", "/api/flashcards", {"cards": [{"question": "Wurzelkriterium?", "answer": "lim sup < 1"}], "stack_id": w5["id"]}, headers=ha)
    _call(hosted, "PATCH", f"/api/flashcard-stacks/{w5['id']}", {"name": "Woche 5: Reihen"}, headers=ha)
    up = _call(hosted, "PUT", f"/api/flashcard-stacks/{w5['id']}/share", headers=ha)
    assert (up["id"], up["cards"], up["name"], up["adopt_count"]) == (sh["id"], 3, "Woche 5: Reihen", 1) and up["updated_at"]
    assert up["stack"]["shared_id"] == sh["id"]
    full = _call(hosted, "GET", f"/api/community/card-stacks/{sh['id']}", headers=hb)
    assert [c["question"] for c in full["cards_list"]][-1] == "Wurzelkriterium?"
    assert len(_call(hosted, "GET", f"/api/flashcards?stack_id={ad['stack']['id']}", headers=hb)) == 2, "Bens Kopie bleibt"
    # nur geteilte Stapel, nur der Autor, nur mit Plus
    own_b = _stack_with_cards(hosted, hb, "Analysis I", name="Ben")
    assert _call(hosted, "PUT", f"/api/flashcard-stacks/{own_b['id']}/share", headers=hb, status=404)["code"] == "not_shared"
    from app import accounts
    accounts.set_plan(ada["id"], "free")
    # Community (05.11.2026) und eigene Karteikarten sind beide ab Plus; die Community-Pruefung kommt zuerst
    assert _call(hosted, "PUT", f"/api/flashcard-stacks/{w5['id']}/share", headers=ha, status=403)["required_plan"] == "plus"


def test_daily_limit_and_banned_authors(hosted, monkeypatch):
    from app import community
    ada, ha, key = _setup(hosted, "ada-grenze@beispiel.de")
    monkeypatch.setenv("LERNAPP_LIMIT_DECK_USER", "2/1440")
    stacks = [_stack_with_cards(hosted, ha, "Analysis I", name=f"S{i}", week=i + 1) for i in range(3)]
    for s in stacks[:2]:
        _call(hosted, "POST", f"/api/flashcard-stacks/{s['id']}/share", headers=ha)
    assert _call(hosted, "POST", f"/api/flashcard-stacks/{stacks[2]['id']}/share", headers=ha, status=429)["code"] == "rate_limited"
    bob, hb, _ = _setup(hosted, "bob-gebannt@beispiel.de")
    with community.cursor() as conn:
        conn.execute("INSERT INTO bans(author_id, created_at) VALUES (?, '2026-11-04T00:00:00Z')", (bob["id"],))
    s = _stack_with_cards(hosted, hb, "Analysis I", name="Bann")
    assert _call(hosted, "POST", f"/api/flashcard-stacks/{s['id']}/share", headers=hb, status=403)["code"] == "author_banned"


def test_moderation_lists_and_restores_hidden_stacks(hosted):
    from app import accounts
    ada, ha, key = _setup(hosted, "ada-mod@beispiel.de")
    own = _stack_with_cards(hosted, ha, "Analysis I", name="Gemeldet", week=2, cards=CARDS)
    sh = _call(hosted, "POST", f"/api/flashcard-stacks/{own['id']}/share", headers=ha)
    reporters = [_setup(hosted, f"melder{i}@beispiel.de")[1] for i in range(3)]
    for h, reason in zip(reporters, ("spam", "offensive", "other")):
        _call(hosted, "POST", f"/api/community/card-stacks/{sh['id']}/report", {"reason": reason}, headers=h)
    assert _call(hosted, "GET", f"/api/community/card-stacks?module={key}", headers=reporters[0])["stacks"] == []
    assert _call(hosted, "PUT", f"/api/flashcard-stacks/{own['id']}/share", headers=ha, status=403)["code"] == "stack_hidden"
    admin, hadm = user(hosted, "admin-karten@beispiel.de", plan="plus")
    accounts.set_role(admin["id"], "admin")
    mod = _call(hosted, "GET", "/api/community/moderation", headers=hadm)
    items = mod["card_stacks"]
    assert [x["id"] for x in items] == [sh["id"]] and items[0]["report_count"] == 3 and len(items[0]["reports"]) == 3
    assert "Was ist eine Reihe?" in items[0]["text"] and ada["id"] not in json.dumps(items)
    assert _call(hosted, "POST", f"/api/community/card-stacks/{sh['id']}/moderate", {"action": "restore"}, headers=reporters[0], status=403)
    r = _call(hosted, "POST", f"/api/community/card-stacks/{sh['id']}/moderate", {"action": "restore"}, headers=hadm)
    assert (r["status"], r["kind"]) == ("active", "card_stack")
    assert [x["id"] for x in _call(hosted, "GET", f"/api/community/card-stacks?module={key}", headers=reporters[0])["stacks"]] == [sh["id"]]


def test_export_and_withdraw_all_on_account_deletion(hosted):
    from app import accounts
    ada, ha, key = _setup(hosted, "ada-weg@beispiel.de")
    ben, hb, _ = _setup(hosted, "ben-bleibt@beispiel.de")
    own = _stack_with_cards(hosted, ha, "Analysis I", name="Export", week=4, cards=CARDS)
    sh = _call(hosted, "POST", f"/api/flashcard-stacks/{own['id']}/share", headers=ha)
    st, _, raw = asgi_call(hosted, "GET", "/api/account/export", headers=ha)
    assert st == 200
    exp = json.loads(zipfile.ZipFile(io.BytesIO(raw)).read("community/meine-karteikarten.json"))
    assert [x["id"] for x in exp] == [sh["id"]] and [c["question"] for c in exp[0]["cards"]] == [q for q, _ in CARDS]
    assert "author_id" not in exp[0] and ada["id"] not in json.dumps(exp)
    accounts.delete_account(ada["id"], "sehr-geheim-123")
    assert _call(hosted, "GET", f"/api/community/card-stacks?module={key}", headers=hb)["stacks"] == [], "sofort zurueckgezogen"
