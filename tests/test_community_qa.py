"""Community Teil 2 (app/community_qa.py, 28.10.2026): Fragen je Kurs mit Antworten, hilfreich-Stimmen, Loesung
markieren, Benachrichtigungen, Lesezeichen, seitenweises Laden, Spam-Grenzen, Melden, Konto loeschen."""
import hashlib
import json

import pytest
from conftest import asgi_call

FP = "b" * 64


def course_key(uni: str, course_id: str) -> str:
    """Wie CommunityKeys.courseKey auf dem iPad."""
    return hashlib.sha256(("uniflow.community.course.v1\0" + uni + "\0" + course_id).encode()).hexdigest()


KEY = course_key("luh", "kurs-analysis-1")


@pytest.fixture
def hosted(app, monkeypatch):
    from app import accounts, community, config
    monkeypatch.setattr(config, "MODE", "hosted")
    accounts.db_path().unlink(missing_ok=True)
    community.db_path().unlink(missing_ok=True)
    monkeypatch.setattr(accounts, "LIMITS", dict(accounts.LIMITS))
    yield app
    accounts.db_path().unlink(missing_ok=True)
    community.db_path().unlink(missing_ok=True)


def _j(r):
    st, _, b = r
    return st, (json.loads(b) if b else None)


def _user(app, email, plus=True, verified=True, uni="luh", member=True):
    from app import accounts
    st, d = _j(asgi_call(app, "POST", "/api/account/register", body=json.dumps({"email": email, "password": "sehr-geheim-123", "university": uni})))
    assert st == 201, d
    accounts.end_trial(d["user"]["id"])             # Tarif-Tests meinen den Stand nach der 7-Tage-Probe
    if verified:
        accounts.mark_email_verified(d["user"]["id"])
    if plus:
        accounts.set_plan(d["user"]["id"], "plus")
    if member:
        _member(d["user"]["id"], uni)
    return d["user"], {"Authorization": f"Bearer {d['token']}"}


def _member(user_id, uni="luh", key=None):
    """Mitglied der Kurs-Community (im Betrieb: Geraet meldet den Kurs, Konto tritt bei; hier direkt, damit auch
    unbestaetigte Konten die Regeln dahinter erreichen). Fragen gibt es nur fuer Mitglieder (04.11.2026)."""
    from app import community
    with community.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO community_members(user_id, community_key, university, kind, joined_at) VALUES (?,?,?,?,?)",
                     (user_id, key or KEY, uni, "course", "2026-11-04T00:00:00Z"))


def call(app, method, path, h, body=None):
    return _j(asgi_call(app, method, "/api/community" + path, body=json.dumps(body) if body is not None else None, headers=h))


def test_key_matches_the_ipad_formula():
    # gleiche Bildung wie SolutionSHA256.hex(Data(("uniflow.community.course.v1\u{0}" + uni + "\u{0}" + id).utf8))
    assert KEY == hashlib.sha256(b"uniflow.community.course.v1\x00luh\x00kurs-analysis-1").hexdigest()


def test_questions_answers_votes_accept_and_notifications(hosted):
    app = hosted
    _, asker = _user(app, "frage@example.org")
    _, helper = _user(app, "hilfe@example.org")
    _, other = _user(app, "noch@example.org")
    st, q = call(app, "POST", f"/courses/{KEY}/questions", asker, {"title": "Wie zeige ich Konvergenz?", "body": "Aufgabe 2b", "fingerprint": FP, "page": 3})
    assert st == 201 and q["mine"] and q["page"] == 3, q
    st, lst = call(app, "GET", f"/courses/{KEY}/questions", helper)
    assert st == 200 and [x["title"] for x in lst["questions"]] == ["Wie zeige ich Konvergenz?"] and not lst["questions"][0]["mine"]
    assert call(app, "GET", f"/courses/{course_key('luh', 'anderer')}/questions", helper)[0] == 403, "anderer Kurs: nur fuer dessen Mitglieder"
    st, a = call(app, "POST", f"/questions/{q['id']}/answers", helper, {"body": "Sandwich-Lemma benutzen."})
    assert st == 201 and a["mine"] and not a["by_asker"], a
    st, a2 = call(app, "POST", f"/questions/{q['id']}/answers", other, {"body": "Monotonie und Beschränktheit."})
    assert call(app, "POST", f"/answers/{a['id']}/vote", other)[1]["votes"] == 1
    assert call(app, "POST", f"/answers/{a['id']}/vote", helper)[0] == 400, "eigene Antwort nicht"
    assert call(app, "POST", f"/questions/{q['id']}/accept", helper, {"answer_id": a["id"]})[0] == 403, "nur wer gefragt hat"
    assert call(app, "POST", f"/questions/{q['id']}/accept", asker, {"answer_id": a2["id"]})[0] == 200
    st, full = call(app, "GET", f"/questions/{q['id']}", other)
    assert [x["id"] for x in full["answer_list"]] == [a2["id"], a["id"]], "markierte Loesung zuerst"
    assert full["answers"] == 2 and full["accepted_answer"] == a2["id"]
    st, n = call(app, "GET", "/notifications", asker)
    assert n["unread"] == 2 and {x["kind"] for x in n["notifications"]} == {"answer"}
    st, n = call(app, "GET", "/notifications?unread=true", other)
    assert [x["kind"] for x in n["notifications"]] == ["accepted"]
    assert call(app, "POST", "/notifications/read", asker, {})[1]["unread"] == 0
    assert call(app, "GET", "/notifications", helper)[1]["unread"] == 0, "nie ueber sich selbst, Stimme ohne Nachricht"


def test_comment_reply_and_like_notifications_and_bookmarks(hosted):
    from app import community
    app = hosted
    author, ah = _user(app, "autor@example.org")
    _, fan = _user(app, "fan@example.org")
    for h in (ah, fan):
        assert call(app, "POST", "/claims", h, {"fingerprints": [FP]})[0] == 200
    st, pub = call(app, "POST", "/solutions", ah, {"package": community.sample_package(FP), "title": "Blatt 2"})
    sid = pub["solution_id"]
    st, c = call(app, "POST", f"/solutions/{sid}/comments", fan, {"text": "Danke!"})
    call(app, "POST", f"/solutions/{sid}/comments", ah, {"text": "Gern", "parent_id": c["id"]})
    call(app, "POST", f"/solutions/{sid}/like", fan)
    kinds = sorted(x["kind"] for x in call(app, "GET", "/notifications", ah)[1]["notifications"])
    assert kinds == ["comment", "like"]
    assert [x["kind"] for x in call(app, "GET", "/notifications", fan)[1]["notifications"]] == ["reply"]
    # Lesezeichen
    assert call(app, "POST", f"/bookmarks/solution/{sid}", fan)[0] == 200
    assert call(app, "POST", "/bookmarks/question/gibt-es-nicht", fan)[0] == 404
    bm = call(app, "GET", "/bookmarks", fan)[1]["bookmarks"]
    assert [(b["kind"], b["id"], b["title"]) for b in bm] == [("solution", sid, "Blatt 2")]
    assert call(app, "DELETE", f"/bookmarks/solution/{sid}", fan)[1] == {"bookmarked": False}


def test_paging_limits_reports_and_plan(hosted, monkeypatch):
    from app import accounts
    app = hosted
    _, a = _user(app, "viel@example.org")
    _, free = _user(app, "frei@example.org", plus=False)
    _, r1 = _user(app, "r1@example.org")
    _, r2 = _user(app, "r2@example.org")
    _, r3 = _user(app, "r3@example.org")
    assert call(app, "POST", f"/courses/{KEY}/questions", free, {"title": "x"})[1]["code"] == "plan_required"
    assert call(app, "GET", f"/courses/{KEY}/questions", free)[0] == 200, "lesen geht immer"
    ids = []
    for i in range(5):
        st, q = call(app, "POST", f"/courses/{KEY}/questions", a, {"title": f"Frage {i}"})
        ids.append(q["id"])
        with __import__("app.community", fromlist=["cursor"]).cursor() as conn:   # verschiedene Zeitpunkte erzwingen
            conn.execute("UPDATE questions SET last_activity=? WHERE id=?", (f"2026-10-2{i}T10:00:00Z", q["id"]))
    p1 = call(app, "GET", f"/courses/{KEY}/questions?limit=2", a)[1]
    assert [x["title"] for x in p1["questions"]] == ["Frage 4", "Frage 3"] and p1["next"]
    p2 = call(app, "GET", f"/courses/{KEY}/questions?limit=2&before={p1['next']}", a)[1]
    assert [x["title"] for x in p2["questions"]] == ["Frage 2", "Frage 1"]
    p3 = call(app, "GET", f"/courses/{KEY}/questions?limit=2&before={p2['next']}", a)[1]
    assert [x["title"] for x in p3["questions"]] == ["Frage 0"] and p3["next"] is None
    # Spam-Grenze Fragen je Stunde
    monkeypatch.setitem(accounts.LIMITS, "question_user", (5, 60))
    assert call(app, "POST", f"/courses/{KEY}/questions", a, {"title": "sechste"})[0] == 429
    # ab 3 Meldungen verborgen
    for h in (r1, r2, r3):
        assert call(app, "POST", f"/questions/{ids[0]}/report-post", h, {"reason": "spam"})[0] == 200
    assert "Frage 0" not in [x["title"] for x in call(app, "GET", f"/courses/{KEY}/questions?limit=50", r1)[1]["questions"]]
    assert call(app, "POST", f"/questions/{ids[1]}/report-post", a, {"reason": "spam"})[1]["code"] == "own_post"


def test_delete_account_removes_questions_answers_and_notifications(hosted):
    from app import accounts, community
    app = hosted
    u, h = _user(app, "weg@example.org")
    _, other = _user(app, "bleibt@example.org")
    st, q = call(app, "POST", f"/courses/{KEY}/questions", h, {"title": "Weg damit"})
    st, q2 = call(app, "POST", f"/courses/{KEY}/questions", other, {"title": "Bleibt"})
    call(app, "POST", f"/questions/{q2['id']}/answers", h, {"body": "Antwort vom Konto, das geht"})
    call(app, "POST", f"/bookmarks/question/{q2['id']}", h)
    community.forget_author(u["id"])
    with community.cursor() as conn:
        for t in ("questions", "answers", "bookmarks", "notifications"):
            col = "user_id" if t in ("bookmarks", "notifications") else "author_id"
            assert conn.execute(f"SELECT COUNT(*) FROM {t} WHERE {col}=?", (u["id"],)).fetchone()[0] == 0, t
        assert conn.execute("SELECT COUNT(*) FROM questions").fetchone()[0] == 1


def test_questions_only_for_members_of_the_course(hosted):
    """Wie auf dem iPad: Fragen eines Kurses lesen und schreiben nur Leute, die den Kurs haben oder hatten (Beitritt
    nur fuer Kurse aus dem eigenen Abgleich, Entscheidung des Inhabers vom 04.11.2026). Wer nicht Mitglied ist, sieht
    fremde Fragen nicht einmal einzeln, kann sie nicht beantworten, liken, melden oder merken."""
    app = hosted
    _, asker = _user(app, "mitglied@example.org")
    qid = call(app, "POST", f"/courses/{KEY}/questions", asker, {"title": "Frage im Kurs"})[1]["id"]
    _, out = _user(app, "fremd@example.org", member=False)
    st, d = call(app, "GET", f"/courses/{KEY}/questions", out)
    assert (st, d["code"]) == (403, "not_a_member")
    st, d = call(app, "POST", f"/courses/{KEY}/questions", out, {"title": "Ich rate den Schluessel"})
    assert (st, d["code"]) == (403, "not_a_member")
    for method, path, body in (("GET", f"/questions/{qid}", None), ("POST", f"/questions/{qid}/answers", {"body": "x"}),
                               ("POST", f"/questions/{qid}/like", None), ("POST", f"/questions/{qid}/report-post", {"reason": "spam"}),
                               ("POST", f"/bookmarks/question/{qid}", None)):
        st, d = call(app, method, path, out, body)
        assert st == 404, (path, st, d)
    # Beitritt nur mit dem Kurs aus dem eigenen Abgleich: ohne Meldung abgelehnt, mit Meldung erlaubt
    st, d = call(app, "POST", f"/communities/{KEY}/join", out, {"kind": "course"})
    assert (st, d["code"]) == (403, "course_not_owned")
    assert call(app, "POST", "/claims", out, {"fingerprints": [], "course_keys": [KEY]})[0] == 200
    assert call(app, "POST", f"/communities/{KEY}/join", out, {"kind": "course"})[0] == 200
    st, d = call(app, "GET", f"/courses/{KEY}/questions", out)
    assert st == 200 and [q["id"] for q in d["questions"]] == [qid]
    assert call(app, "GET", f"/questions/{qid}", out)[0] == 200
    # wer austritt, sieht die Fragen nicht mehr; die eigene Frage bleibt fuer den Autor sichtbar
    assert call(app, "DELETE", f"/communities/{KEY}/join", asker)[0] == 200
    assert call(app, "GET", f"/courses/{KEY}/questions", asker)[0] == 403
    assert call(app, "GET", f"/questions/{qid}", asker)[0] == 200
