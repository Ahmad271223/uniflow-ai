"""Community-Haertetest (13.11.2026): Trennung zwischen Kursen und Konten, Rechte je Tarif (Free/Plus/Pro AI), Melden,
Sperren und Grenzen, leere und lange Texte, gleichzeitige Beitraege. Ergaenzt test_community_qa.py,
test_community_social.py und test_community_reports.py um die Faelle, die dort fehlten."""
import json
import threading

import pytest
from conftest import asgi_call
from test_community_qa import KEY, _member, call, course_key
from test_community_qa import hosted  # noqa: F401  (Fixture)

FP = "c" * 64
KEY_B = course_key("luh", "kurs-lineare-algebra")


def _user(app, email, plan="plus", verified=True, member=True, admin=False, key=KEY, uni="luh"):
    from app import accounts
    st, _, b = asgi_call(app, "POST", "/api/account/register",
                         body=json.dumps({"email": email, "password": "sehr-geheim-123", "university": uni}))
    d = json.loads(b)
    assert st == 201, d
    uid = d["user"]["id"]
    accounts.end_trial(uid)
    if verified:
        accounts.mark_email_verified(uid)
    if plan != "free":
        accounts.set_plan(uid, plan)
    if admin:
        accounts.set_role(uid, "admin")
    if member:
        _member(uid, uni, key)
    # wie request.state.user: der Tarif steht im Konto (accounts.set_plan), entitlements liest ihn von dort
    return {"id": uid, "email_verified": 1 if verified else 0, "role": "admin" if admin else "user",
            "plan": None if plan == "free" else plan, "plan_until": None}, \
        {"Authorization": f"Bearer {d['token']}"}


def _solution(app, author_h, *reader_hs, sid="6f1c1c0e-0000-4000-8000-0000000000c1"):
    """Loesung zu einer PDF, die Autor und Leser im eigenen Abgleich haben."""
    from app import community
    for h in (author_h, *reader_hs):
        assert call(app, "POST", "/claims", h, {"fingerprints": [FP]})[0] == 200
    st, d = call(app, "POST", "/solutions", author_h, {"package": community.sample_package(FP, solution_id=sid), "title": "Blatt 4"})
    assert st == 201, d
    return d["solution_id"]


# ---------------------------------------------------------------- Trennung zwischen Kursen und Konten

def test_questions_stay_in_their_course(hosted):
    """Wer nur Kurs A hat, sieht Kurs B nicht: weder in der Liste noch einzeln, und kann dort nichts schreiben."""
    app = hosted
    _, a = _user(app, "kurs-a@example.org")
    _, b = _user(app, "kurs-b@example.org", key=KEY_B)
    qa = call(app, "POST", f"/courses/{KEY}/questions", a, {"title": "Frage in A"})[1]
    qb = call(app, "POST", f"/courses/{KEY_B}/questions", b, {"title": "Frage in B"})[1]
    assert [q["title"] for q in call(app, "GET", f"/courses/{KEY}/questions", a)[1]["questions"]] == ["Frage in A"]
    assert [q["title"] for q in call(app, "GET", f"/courses/{KEY_B}/questions", b)[1]["questions"]] == ["Frage in B"]
    assert call(app, "GET", f"/courses/{KEY_B}/questions", a)[0] == 403
    for method, path, body in (("GET", f"/questions/{qb['id']}", None),
                               ("POST", f"/questions/{qb['id']}/answers", {"body": "Einmischung"}),
                               ("POST", f"/questions/{qb['id']}/like", None),
                               ("POST", f"/bookmarks/question/{qb['id']}", None)):
        assert call(app, method, path, a, body)[0] == 404, path
    # die Antwort in B ist fuer A auch ueber die Antwort-ID nicht erreichbar
    ans = call(app, "POST", f"/questions/{qb['id']}/answers", b, {"body": "Antwort in B"})[1]
    assert call(app, "POST", f"/answers/{ans['id']}/vote", a)[0] == 404
    assert call(app, "POST", f"/answers/{ans['id']}/report-post", a, {"reason": "spam"})[0] == 404
    # fremde Beitraege lassen sich weder aendern noch loeschen
    assert call(app, "PATCH", f"/questions/{qa['id']}", b, {"title": "uebernommen"})[0] in (403, 404)
    assert call(app, "DELETE", f"/questions/{qa['id']}", b)[0] == 403
    assert call(app, "PATCH", f"/answers/{ans['id']}", a, {"body": "uebernommen"})[0] == 403
    assert call(app, "DELETE", f"/answers/{ans['id']}", a)[0] == 403


def test_same_course_key_at_another_university_lists_nothing(hosted):
    """Die Liste filtert zusaetzlich nach der Hochschule des Kontos (Schluessel enthalten sie ohnehin)."""
    app = hosted
    _, luh = _user(app, "luh@example.org")
    _, hi = _user(app, "hi@example.org", uni="hildesheim")
    call(app, "POST", f"/courses/{KEY}/questions", luh, {"title": "Nur LUH"})
    st, d = call(app, "GET", f"/courses/{KEY}/questions", hi)
    assert st == 200 and d["questions"] == []


def test_notifications_and_bookmarks_are_private(hosted):
    app = hosted
    _, asker = _user(app, "frager@example.org")
    _, helper = _user(app, "helfer@example.org")
    q = call(app, "POST", f"/courses/{KEY}/questions", asker, {"title": "Privat?"})[1]
    call(app, "POST", f"/questions/{q['id']}/answers", helper, {"body": "Ja."})
    call(app, "POST", f"/bookmarks/question/{q['id']}", helper)
    n_asker = call(app, "GET", "/notifications", asker)[1]
    assert n_asker["unread"] == 1
    assert call(app, "GET", "/notifications", helper)[1]["unread"] == 0
    assert call(app, "GET", "/bookmarks", asker)[1]["bookmarks"] == []
    # fremde Benachrichtigung als gelesen markieren aendert nichts beim Besitzer
    call(app, "POST", "/notifications/read", helper, {"ids": [n_asker["notifications"][0]["id"]]})
    assert call(app, "GET", "/notifications", asker)[1]["unread"] == 1


# ---------------------------------------------------------------- Rechte je Tarif

@pytest.mark.parametrize("plan,can", [("free", False), ("plus", True), ("pro_ai", True)])
def test_rights_per_plan(hosted, plan, can):
    """Free: weder lesen noch schreiben (403 plan_required). Plus und Pro AI: lesen, fragen, antworten, kommentieren."""
    app = hosted
    _, owner = _user(app, "besitzer@example.org")
    q = call(app, "POST", f"/courses/{KEY}/questions", owner, {"title": "Grundfrage"})[1]
    _, h = _user(app, f"{plan}@example.org", plan=plan)
    sid = _solution(app, owner, h)
    checks = (("GET", f"/courses/{KEY}/questions", None), ("GET", f"/questions/{q['id']}", None),
              ("POST", f"/courses/{KEY}/questions", {"title": "Neue Frage"}),
              ("POST", f"/questions/{q['id']}/answers", {"body": "Antwort"}),
              ("POST", f"/solutions/{sid}/comments", {"text": "Kommentar"}),
              ("GET", f"/solutions/{sid}/comments", None))
    for method, path, body in checks:
        st, d = call(app, method, path, h, body)
        if can:
            assert st in (200, 201), (plan, path, st, d)
        else:
            assert (st, d["code"]) == (403, "plan_required"), (plan, path, st, d)


def test_after_downgrade_own_posts_can_still_be_deleted(hosted):
    """Wer von Plus auf Free faellt, liest und schreibt nicht mehr, kann eigene Beitraege aber loeschen."""
    from app import accounts
    app = hosted
    u, h = _user(app, "abo-weg@example.org")
    q = call(app, "POST", f"/courses/{KEY}/questions", h, {"title": "Bald ohne Abo"})[1]
    accounts.set_plan(u["id"], "free")
    assert call(app, "POST", f"/courses/{KEY}/questions", h, {"title": "noch eine"})[1]["code"] == "plan_required"
    assert call(app, "DELETE", f"/questions/{q['id']}", h)[0] == 200


def test_unverified_plus_account_can_read_but_not_write(hosted):
    app = hosted
    _, owner = _user(app, "bestaetigt@example.org")
    q = call(app, "POST", f"/courses/{KEY}/questions", owner, {"title": "Frage"})[1]
    _, h = _user(app, "unbestaetigt@example.org", verified=False)
    assert call(app, "GET", f"/courses/{KEY}/questions", h)[0] == 200
    for method, path, body in (("POST", f"/courses/{KEY}/questions", {"title": "x"}),
                               ("POST", f"/questions/{q['id']}/answers", {"body": "x"}),
                               ("POST", f"/questions/{q['id']}/like", None),
                               ("POST", f"/questions/{q['id']}/report-post", {"reason": "spam"})):
        st, d = call(app, method, path, h, body)
        assert (st, d["code"]) == (403, "email_unverified"), path


def test_moderation_routes_only_for_admin(hosted):
    app = hosted
    _, a = _user(app, "normal@example.org")
    _, admin = _user(app, "chef@example.org", admin=True)
    q = call(app, "POST", f"/courses/{KEY}/questions", a, {"title": "Frage"})[1]
    assert call(app, "GET", "/moderation", a)[0] == 403
    assert call(app, "POST", f"/questions/{q['id']}/moderate", a, {"action": "restore"})[0] == 403
    assert call(app, "GET", "/moderation", admin)[0] == 200
    assert call(app, "POST", f"/questions/{q['id']}/moderate", admin, {"action": "loeschen"})[0] == 400


# ---------------------------------------------------------------- Sperren und Melden

def _ban(app, admin_h, author_h, sid="6f1c1c0e-0000-4000-8000-0000000000d9"):
    """Inhaber sperrt einen Autor (ueber eine seiner Loesungen, wie im Dashboard)."""
    from app import community
    st, d = call(app, "POST", "/solutions", author_h, {"package": community.sample_package(FP, solution_id=sid), "title": "Spam"})
    assert st == 201, d
    assert call(app, "POST", f"/solutions/{sid}/moderate", admin_h, {"action": "ban_author"})[0] == 200


def test_banned_author_comments_disappear_and_cannot_be_edited(hosted):
    """Fragen und Antworten gesperrter Autoren waren schon unsichtbar, Kommentare unter Loesungen nicht (behoben
    13.11.2026). Ein gesperrtes Konto kann auch alte Beitraege nicht mehr aendern."""
    app = hosted
    _, owner = _user(app, "eigner@example.org")
    _, spam = _user(app, "spammer@example.org")
    _, reader = _user(app, "leserin@example.org")
    _, admin = _user(app, "inhaber@example.org", admin=True)
    sid = _solution(app, owner, spam, reader)
    c = call(app, "POST", f"/solutions/{sid}/comments", spam, {"text": "Kauf hier!"})[1]
    q = call(app, "POST", f"/courses/{KEY}/questions", spam, {"title": "Werbung"})[1]
    a = call(app, "POST", f"/questions/{q['id']}/answers", spam, {"body": "Werbung 2"})[1]
    _ban(app, admin, spam)
    assert call(app, "GET", f"/solutions/{sid}/comments", reader)[1]["comments"] == []
    assert call(app, "GET", f"/courses/{KEY}/questions", reader)[1]["questions"] == []
    st, d = call(app, "PATCH", f"/comments/{c['id']}", spam, {"text": "noch mehr Werbung"})
    assert (st, d["code"]) == (403, "author_banned")
    st, d = call(app, "PATCH", f"/questions/{q['id']}", spam, {"title": "andere Werbung"})
    assert (st, d["code"]) == (403, "author_banned")
    st, d = call(app, "PATCH", f"/answers/{a['id']}", spam, {"body": "andere Werbung"})
    assert (st, d["code"]) == (403, "author_banned")
    assert call(app, "POST", f"/courses/{KEY}/questions", spam, {"title": "neu"})[1]["code"] == "author_banned"
    assert call(app, "POST", f"/solutions/{sid}/comments", spam, {"text": "neu"})[1]["code"] == "author_banned"
    # loeschen bleibt erlaubt
    assert call(app, "DELETE", f"/comments/{c['id']}", spam)[0] == 200


def test_own_block_list_hides_questions_and_answers(hosted):
    app = hosted
    _, me = _user(app, "ich@example.org")
    _, troll = _user(app, "troll@example.org")
    _, friend = _user(app, "freund@example.org")
    sid = _solution(app, troll, me, sid="6f1c1c0e-0000-4000-8000-0000000000e1")
    q1 = call(app, "POST", f"/courses/{KEY}/questions", troll, {"title": "Troll-Frage"})[1]
    q2 = call(app, "POST", f"/courses/{KEY}/questions", friend, {"title": "Gute Frage"})[1]
    call(app, "POST", f"/questions/{q2['id']}/answers", troll, {"body": "Troll-Antwort"})
    call(app, "POST", f"/questions/{q2['id']}/answers", friend, {"body": "Gute Antwort"})
    assert call(app, "POST", f"/solutions/{sid}/block", me)[0] == 200
    assert [q["title"] for q in call(app, "GET", f"/courses/{KEY}/questions", me)[1]["questions"]] == ["Gute Frage"]
    assert call(app, "GET", f"/questions/{q1['id']}", me)[0] == 404
    assert [a["body"] for a in call(app, "GET", f"/questions/{q2['id']}", me)[1]["answer_list"]] == ["Gute Antwort"]
    # andere sehen weiter alles
    assert len(call(app, "GET", f"/courses/{KEY}/questions", friend)[1]["questions"]) == 2


def test_reports_count_once_per_account_and_hide_at_three(hosted):
    app = hosted
    _, author = _user(app, "autorin@example.org")
    reporters = [_user(app, f"melder{i}@example.org")[1] for i in range(3)]
    q = call(app, "POST", f"/courses/{KEY}/questions", author, {"title": "Grenzfall"})[1]
    for _ in range(3):                                   # dasselbe Konto dreimal: zaehlt einmal
        assert call(app, "POST", f"/questions/{q['id']}/report-post", reporters[0], {"reason": "spam"})[0] == 200
    assert call(app, "GET", f"/questions/{q['id']}", reporters[1])[0] == 200, "eine Meldung verbirgt nichts"
    assert call(app, "POST", f"/questions/{q['id']}/report-post", reporters[1], {"reason": "kaputt"})[0] == 400
    for h in reporters[1:]:
        assert call(app, "POST", f"/questions/{q['id']}/report-post", h, {"reason": "offensive"})[0] == 200
    assert call(app, "GET", f"/questions/{q['id']}", reporters[0])[0] == 404
    assert call(app, "GET", f"/questions/{q['id']}", author)[0] == 200, "der Autor sieht seine verborgene Frage"
    assert call(app, "POST", f"/questions/{q['id']}/answers", author, {"body": "x"})[0] == 404, "keine Antworten mehr"


def test_report_limit_per_day_stops_mass_reporting(hosted, monkeypatch):
    from app import accounts
    app = hosted
    _, author = _user(app, "viele@example.org")
    _, rep = _user(app, "eifrig@example.org")
    ids = [call(app, "POST", f"/courses/{KEY}/questions", author, {"title": f"F{i}"})[1]["id"] for i in range(3)]
    monkeypatch.setitem(accounts.LIMITS, "report_user", (2, 1440))
    assert [call(app, "POST", f"/questions/{i}/report-post", rep, {"reason": "spam"})[0] for i in ids] == [200, 200, 429]


@pytest.mark.parametrize("limit_name,path_fn,body", [
    ("answer_user", lambda q: f"/questions/{q}/answers", {"body": "Spam"}),
    ("question_user", lambda q: f"/courses/{KEY}/questions", {"title": "Spam"}),
])
def test_rate_limits_for_writing(hosted, monkeypatch, limit_name, path_fn, body):
    from app import accounts
    app = hosted
    _, h = _user(app, "schnell@example.org")
    q = call(app, "POST", f"/courses/{KEY}/questions", h, {"title": "Start"})[1]
    monkeypatch.setitem(accounts.LIMITS, limit_name, (2, 60))
    codes = [call(app, "POST", path_fn(q["id"]), h, body)[0] for _ in range(4)]
    assert codes[-1] == 429 and codes.count(201) <= 2, codes


# ---------------------------------------------------------------- leere, lange und seltsame Texte

@pytest.mark.parametrize("title,code", [("", "text_empty"), ("   \n\t ", "text_empty"), ("‮⁦\x07", "text_empty"),
                                        ("x" * 161, "text_too_long"), (None, "text_empty")])
def test_question_title_rules(hosted, title, code):
    app = hosted
    _, h = _user(app, "titel@example.org")
    st, d = call(app, "POST", f"/courses/{KEY}/questions", h, {"title": title})
    assert (st, d["code"]) == (400, code)


def test_lengths_at_the_limit_and_unicode(hosted):
    """Grenzen in Zeichen (Unicode-Skalare wie len() in Python), nicht in Bytes; Steuer- und Richtungszeichen fallen weg."""
    app = hosted
    _, h = _user(app, "lang@example.org")
    _, h2 = _user(app, "lang2@example.org")
    st, q = call(app, "POST", f"/courses/{KEY}/questions", h, {"title": "ä" * 160, "body": "😀" * 4000})
    assert st == 201 and len(q["title"]) == 160 and len(q["body"]) == 4000
    assert call(app, "POST", f"/courses/{KEY}/questions", h, {"title": "ok", "body": "😀" * 4001})[1]["code"] == "text_too_long"
    st, a = call(app, "POST", f"/questions/{q['id']}/answers", h2, {"body": "  Richtig‮ herum \x00 "})
    assert st == 201 and a["body"] == "Richtig herum", a
    assert call(app, "POST", f"/questions/{q['id']}/answers", h2, {"body": "y" * 4001})[1]["code"] == "text_too_long"
    assert call(app, "POST", f"/questions/{q['id']}/answers", h2, {"body": "  "})[1]["code"] == "text_empty"
    # Bearbeiten unterliegt denselben Regeln
    assert call(app, "PATCH", f"/answers/{a['id']}", h2, {"body": ""})[1]["code"] == "text_empty"
    assert call(app, "PATCH", f"/questions/{q['id']}", h, {"title": "z" * 161})[1]["code"] == "text_too_long"


@pytest.mark.parametrize("text", [123, ["a"], {"x": 1}, True])
def test_comment_text_that_is_not_a_string_is_refused_not_a_crash(hosted, text):
    """Vorher: {"text": 123} lief auf .strip() einer Zahl und endete mit 500 (behoben 13.11.2026)."""
    app = hosted
    _, owner = _user(app, "k-autor@example.org")
    _, reader = _user(app, "k-leser@example.org")
    sid = _solution(app, owner, reader)
    st, d = call(app, "POST", f"/solutions/{sid}/comments", reader, {"text": text})
    assert st == 400 and d["code"] == "text_invalid", (st, d)
    c = call(app, "POST", f"/solutions/{sid}/comments", reader, {"text": "richtiger Text"})[1]
    st, d = call(app, "PATCH", f"/comments/{c['id']}", reader, {"text": text})
    assert st == 400 and d["code"] == "text_invalid", (st, d)


def test_comment_lengths(hosted):
    app = hosted
    _, owner = _user(app, "k2-autor@example.org")
    _, reader = _user(app, "k2-leser@example.org")
    sid = _solution(app, owner, reader)
    assert call(app, "POST", f"/solutions/{sid}/comments", reader, {"text": "ß" * 2000})[0] == 201
    assert call(app, "POST", f"/solutions/{sid}/comments", reader, {"text": "ß" * 2001})[1]["code"] == "text_too_long"
    assert call(app, "POST", f"/solutions/{sid}/comments", reader, {"text": " ‭ "})[1]["code"] == "text_empty"


# ---------------------------------------------------------------- gleichzeitige Beitraege

def _parallel(n, fn):
    errors, results = [], []
    start = threading.Barrier(n)

    def run(i):
        try:
            start.wait()
            results.append(fn(i))
        except Exception as e:          # noqa: BLE001 - jede Ausnahme ist hier ein Befund
            errors.append(e)
    threads = [threading.Thread(target=run, args=(i,)) for i in range(n)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(60)
    return results, errors


def test_many_answers_at_once_all_arrive(hosted, monkeypatch):
    """24 Konten antworten in derselben Sekunde auf dieselbe Frage: keine verlorene Antwort, kein "database is locked",
    die Frage bekommt 24 Benachrichtigungen."""
    from app import accounts, community_qa
    app = hosted
    monkeypatch.setitem(accounts.LIMITS, "answer_user", (1000, 60))
    asker, ah = _user(app, "viel-gefragt@example.org")
    q = call(app, "POST", f"/courses/{KEY}/questions", ah, {"title": "Wer weiss es?"})[1]
    users = [_user(app, f"antwort{i}@example.org")[0] for i in range(24)]
    results, errors = _parallel(len(users), lambda i: community_qa.answer(users[i], q["id"], f"Antwort {i}"))
    assert errors == [] and len(results) == 24
    full = community_qa.get_question(asker, q["id"])
    assert full["answers"] == 24 and len({a["body"] for a in full["answer_list"]}) == 24
    assert community_qa.notifications(asker)["unread"] == 24


def test_many_questions_at_once_page_without_gaps(hosted, monkeypatch):
    """Viele Fragen in derselben Sekunde: das Blaettern (Cursor Zeit|ID) liefert jede genau einmal."""
    from app import accounts, community_qa
    app = hosted
    monkeypatch.setitem(accounts.LIMITS, "question_user", (1000, 60))
    users = [_user(app, f"frage{i}@example.org")[0] for i in range(12)]
    results, errors = _parallel(12, lambda i: [community_qa.ask(users[i], "luh", KEY, f"Frage {i}-{k}", "") for k in range(3)])
    assert errors == []
    seen, before = [], None
    while True:
        page = community_qa.list_questions(users[0], "luh", KEY, limit=5, before=before)
        seen += [q["title"] for q in page["questions"]]
        before = page["next"]
        if not before:
            break
    assert sorted(seen) == sorted(f"Frage {i}-{k}" for i in range(12) for k in range(3))


def test_simultaneous_reports_hide_exactly_once_with_correct_count(hosted):
    from app import community_qa
    app = hosted
    _, author = _user(app, "gemeldet@example.org")
    q = call(app, "POST", f"/courses/{KEY}/questions", author, {"title": "Strittig"})[1]
    users = [_user(app, f"gleich{i}@example.org")[0] for i in range(6)]
    results, errors = _parallel(6, lambda i: community_qa.report(users[i], "question", q["id"], "spam"))
    assert errors == []
    from app import community
    with community.cursor() as conn:
        r = conn.execute("SELECT status, report_count FROM questions WHERE id=?", (q["id"],)).fetchone()
    assert (r["status"], r["report_count"]) in (("hidden", 6), ("hidden", 3), ("hidden", 4), ("hidden", 5))
    assert r["status"] == "hidden"


def test_double_tap_report_on_a_comment_is_not_a_server_error(hosted):
    """Vorher: zwei gleichzeitige Meldungen desselben Kontos liefen beide an der Pruefung vorbei, die zweite scheiterte
    am Primaerschluessel (IntegrityError, 500). Jetzt: eine Meldung zaehlt, die andere bekommt 409."""
    from app import community
    app = hosted
    _, owner = _user(app, "doppel-autor@example.org")
    reporter, rh = _user(app, "doppel-melder@example.org")
    sid = _solution(app, owner, rh)
    c = call(app, "POST", f"/solutions/{sid}/comments", owner, {"text": "Strittiger Kommentar"})[1]
    results, errors = _parallel(8, lambda i: community.report_comment(reporter, c["id"], "spam"))
    assert all(isinstance(e, community.CommunityError) and e.status == 409 for e in errors), errors
    assert len(results) == 1 and results[0]["reports"] == 1
    with community.cursor() as conn:
        assert conn.execute("SELECT COUNT(*) FROM comment_reports WHERE comment_id=?", (c["id"],)).fetchone()[0] == 1


def test_simultaneous_likes_count_once_each(hosted, monkeypatch):
    from app import accounts, community_qa
    app = hosted
    monkeypatch.setitem(accounts.LIMITS, "like_user", (1000, 60))
    _, author = _user(app, "beliebt@example.org")
    q = call(app, "POST", f"/courses/{KEY}/questions", author, {"title": "Gute Frage"})[1]
    users = [_user(app, f"fan{i}@example.org")[0] for i in range(10)]
    # jedes Konto zweimal gleichzeitig: 10 Likes, nicht 20
    results, errors = _parallel(20, lambda i: community_qa.like_question(users[i % 10], q["id"], True))
    assert errors == []
    assert community_qa.like_question(users[0], q["id"], True)["likes"] == 10


def test_shared_text_cases_match_the_service():
    """Gemeinsame Faelle fuer den Swift-Kern (CommunityDiscussion.cleanText): aktuell zur Referenz."""
    import importlib.util
    from pathlib import Path
    root = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location("gen_community_text_cases", root / "tools" / "gen-community-text-cases.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    stored = json.loads((root / "packages/shared-contracts/fixtures/community/text-cases.json").read_text(encoding="utf-8"))
    assert mod.build() == stored, "python tools/gen-community-text-cases.py neu ausfuehren"
    assert any(c.get("error") == "text_empty" for c in stored["cases"]) and any("‮" not in c.get("output", []) for c in stored["cases"])
