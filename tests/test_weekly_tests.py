"""Gemeinsamer Wochentest je Kursgruppe (app/weekly_tests.py, 28.10.2026): ein Test fuer alle einer Gruppe und Woche,
eigene Versuche, Bewertung im Dienst, Loesungen erst nach Abgabe, freiwillige Rangliste. Die Studora-KI ist eine
Attrappe, die mitzaehlt, wie oft sie gerufen wird."""
import hashlib
import json
import threading
from datetime import datetime, timedelta, timezone

import pytest
from conftest import asgi_call

KEY = hashlib.sha256(b"uniflow.community.course.v1\x00luh\x00vl-analysis-1").hexdigest()
WEEK, TERM = "2026-W44", "WiSe 26/27"
MATS = [{"kind": "vorlesung", "title": "VL 3 Folgen", "sha256": "a" * 64, "pages": [{"page": 1, "text": "Folgen, Grenzwert, Konvergenz, Sandwich-Lemma"}]},
        {"kind": "uebung", "title": "Blatt 3", "pages": [{"page": 1, "text": "Aufgabe 1: Zeigen Sie die Konvergenz der Folge 1/n."}]},
        {"kind": "altklausur", "title": "Klausur WS24", "pages": [{"page": 3, "text": "Aufgabe 4: Grenzwert von (1+1/n)^n"}]}]


def make_test(n_short=5, n_medium=6, n_hard=4, broken=0):
    qs = []
    for lv, n in (("short", n_short), ("medium", n_medium), ("hard", n_hard)):
        for i in range(n):
            k = len(qs)
            if k % 3 == 0:
                qs.append({"level": lv, "type": "mc", "question": f"Aufgabe {k}: Welche Folge konvergiert gegen 0?", "options": ["A 1/n", "B n", "C (-1)^n"],
                           "answer": "A", "points": 6, "sources": [{"q": "Q1", "page": 1}]})
            elif k % 3 == 1:
                qs.append({"level": lv, "type": "number", "question": f"Aufgabe {k}: Berechnen Sie den Grenzwert von 2+1/n.", "value": 2, "tolerance": 0.01,
                           "answer": "2", "points": 7, "sources": [{"q": "Q2", "page": 1}]})
            else:
                qs.append({"level": lv, "type": "text", "question": f"Aufgabe {k}: Erklaeren Sie das Sandwich-Lemma.", "answer": "Eingeschlossen zwischen zwei Folgen mit gleichem Grenzwert",
                           "rubric": "volle Punkte fuer korrekte Aussage", "points": 7, "sources": [{"q": "Q1", "page": 1}]})
    for _ in range(broken):
        qs.append({"level": "hard", "type": "mc", "question": "Kaputte Aufgabe ohne passende Loesung", "options": ["A", "B"], "answer": "D", "points": 5})
    return {"title": "Folgen und Grenzwerte", "topics": ["Folgen", "Grenzwerte"], "questions": qs}


class FakeAI:
    def __init__(self, test=None, reject=()):
        self.calls, self.test, self.reject, self.lock = [], test or make_test(), set(reject), threading.Lock()

    def complete(self, system, prompt, schema=None):
        from app.ai_backend import Completion
        with self.lock:
            kind = "review" if "Pruefe jede Aufgabe" in prompt else "grade" if "Bewerte die Antworten" in prompt else "generate"
            self.calls.append(kind)
        if kind == "generate":
            return Completion(json.dumps(self.test), 1000, 2000, "fake")
        if kind == "review":
            qs = json.loads(prompt.split("AUFGABEN:\n", 1)[1])
            return Completion(json.dumps({"verdicts": [{"i": i, "ok": i not in self.reject} for i in range(len(qs))]}), 100, 100, "fake")
        items = json.loads(prompt.split("\n\n", 1)[1])
        return Completion(json.dumps({"grades": [{"id": it["id"], "points": it["max"] if "eingeschlossen" in it["answer"].lower() else 0,
                                                   "feedback": "ok", "confidence": 0.9} for it in items]}), 100, 100, "fake")


@pytest.fixture
def hosted(app, monkeypatch):
    from app import accounts, ai_backend, community, config
    monkeypatch.setattr(config, "MODE", "hosted")
    for p in (accounts.db_path(), community.db_path()):
        p.unlink(missing_ok=True)
    monkeypatch.setattr(accounts, "LIMITS", dict(accounts.LIMITS) | {"register_ip": (1000, 60)})   # 100 Testkonten von einer IP
    fake = FakeAI()
    ai_backend.set_provider(fake)
    yield app, fake
    ai_backend.set_provider(None)
    for p in (accounts.db_path(), community.db_path()):
        p.unlink(missing_ok=True)


def _j(r):
    st, _, b = r
    return st, (json.loads(b) if b else None)


def user(app, email, plan="plus", uni="luh"):
    from app import accounts
    st, d = _j(asgi_call(app, "POST", "/api/account/register", body=json.dumps({"email": email, "password": "sehr-geheim-123", "university": uni})))
    accounts.mark_email_verified(d["user"]["id"])
    accounts.set_plan(d["user"]["id"], plan)
    return {"Authorization": f"Bearer {d['token']}"}


def call(app, method, path, h, body=None):
    return _j(asgi_call(app, method, "/api/community" + path, body=json.dumps(body) if body is not None else None, headers=h))


def generate(app, h, week=WEEK, term=TERM):
    from app import weekly_tests
    from app import accounts
    u = accounts.authenticate(h["Authorization"][7:])
    return weekly_tests.request(u, u["university"], KEY, term, week, MATS, run_async=False)


def test_one_test_for_the_whole_group_generated_once(hosted):
    app, fake = hosted
    students = [user(app, f"s{i}@example.org") for i in range(100)]
    t = generate(app, students[0])
    assert t["status"] == "published" and len(t["questions"]) == 15 and t["levels"] == {"short": 5, "medium": 6, "hard": 4}
    assert round(t["max_points"]) == 100 and "solutions" not in t
    assert all("answer" not in q and "rubric" not in q for q in t["questions"]), "keine Loesungen vor der Abgabe"
    for h in students[1:]:
        st, again = call(app, "POST", f"/weekly/{KEY}/{WEEK}", h, {"term": TERM, "materials": MATS})
        assert st == 202 and again["id"] == t["id"]
    assert fake.calls == ["generate", "review"], "fuer 100 Studierende genau eine Erstellung"
    # andere Woche, anderes Semester, andere Hochschule: eigene Tests
    assert generate(app, students[0], week="2026-W45")["id"] != t["id"]
    assert generate(app, students[0], term="SoSe 27")["id"] != t["id"]
    hi = user(app, "h@example.org", uni="hildesheim")
    assert generate(app, hi)["id"] != t["id"]


def test_concurrent_requests_create_one_test(hosted):
    app, fake = hosted
    from app import accounts, weekly_tests
    hs = [user(app, f"p{i}@example.org") for i in range(8)]
    ids, lock = [], threading.Lock()

    def go(h):
        u = accounts.authenticate(h["Authorization"][7:])
        r = weekly_tests.request(u, "luh", KEY, TERM, WEEK, MATS, run_async=False)
        with lock:
            ids.append(r["id"])
    ts = [threading.Thread(target=go, args=(h,)) for h in hs]
    [t.start() for t in ts]; [t.join() for t in ts]
    assert len(set(ids)) == 1 and fake.calls.count("generate") == 1


def test_attempts_grading_solutions_and_manipulation(hosted):
    app, fake = hosted
    a, b = user(app, "a@example.org"), user(app, "b@example.org")
    t = generate(app, a)
    st, s = call(app, "POST", f"/weekly/tests/{t['id']}/attempt", a, {})
    aid = s["attempt"]["id"]
    assert s["attempt"]["official"] and "solutions" not in s
    qs = t["questions"]
    answers = {q["id"]: ("A" if q["type"] == "mc" else "2,001" if q["type"] == "number" else "Die Folge ist eingeschlossen") for q in qs}
    half = dict(list(answers.items())[:5])
    assert call(app, "PUT", f"/weekly/attempts/{aid}", a, {"answers": half})[0] == 200
    # zweites Geraet setzt fort: derselbe Versuch, Antworten da
    st, s2 = call(app, "POST", f"/weekly/tests/{t['id']}/attempt", a, {})
    assert s2["attempt"]["id"] == aid and s2["attempt"]["answers"] == half
    st, r = call(app, "POST", f"/weekly/attempts/{aid}/submit", a, {"answers": answers, "score": 9999, "leaderboard": True, "display_name": "Ana"})
    assert st == 200 and r["attempt"]["status"] == "graded" and r["attempt"]["score"] == pytest.approx(100, abs=0.5), "Punkte rechnet der Dienst"
    assert r["solutions"][qs[0]["id"]]["answer"] == "A", "Loesungen nach der Abgabe"
    assert fake.calls.count("grade") == 1, "eine KI-Anfrage fuer alle offenen Antworten"
    st, again = call(app, "POST", f"/weekly/attempts/{aid}/submit", a, {"answers": {qs[0]["id"]: "C"}})
    assert again["attempt"]["score"] == r["attempt"]["score"], "zweite Abgabe aendert nichts"
    assert call(app, "PUT", f"/weekly/attempts/{aid}", a, {"answers": {}})[1]["code"] == "already_submitted"
    # fremder Versuch nicht erreichbar, Uebungsversuch zaehlt nicht
    assert call(app, "PUT", f"/weekly/attempts/{aid}", b, {"answers": {}})[0] == 404
    st, p = call(app, "POST", f"/weekly/tests/{t['id']}/attempt", a, {"practice": True})
    assert p["attempt"]["official"] is False
    # Free darf nicht teilnehmen
    free = user(app, "free@example.org", plan="free")
    assert call(app, "POST", f"/weekly/tests/{t['id']}/attempt", free, {})[1]["code"] == "plan_required"


def test_leaderboard_optin_ties_and_visibility(hosted):
    app, fake = hosted
    from app import weekly_tests, accounts
    hs = [user(app, f"r{i}@example.org") for i in range(4)]
    t = generate(app, hs[0])
    qs = t["questions"]
    good = {q["id"]: ("A" if q["type"] == "mc" else "2" if q["type"] == "number" else "eingeschlossen") for q in qs}
    weak = {q["id"]: ("B" if q["type"] == "mc" else "2" if q["type"] == "number" else "eingeschlossen") for q in qs}
    for h, ans, lb, name in ((hs[0], good, True, "Ana"), (hs[1], good, True, "Ben"), (hs[2], weak, True, "Cem"), (hs[3], good, False, None)):
        aid = call(app, "POST", f"/weekly/tests/{t['id']}/attempt", h, {})[1]["attempt"]["id"]
        call(app, "POST", f"/weekly/attempts/{aid}/submit", h, {"answers": ans, "leaderboard": lb, "display_name": name})
    st, lb = call(app, "GET", f"/weekly/tests/{t['id']}/leaderboard", hs[2])
    assert st == 200 and lb["visible"] is False and lb["participants"] == 4 and "entries" not in lb and lb["mine"]["score"] < 100
    assert lb["my_rank"] is None, "eigener Platz erst nach der Frist"
    u = accounts.authenticate(hs[2]["Authorization"][7:])
    later = datetime.now(timezone.utc) + timedelta(days=8)
    full = weekly_tests.leaderboard(u, t["id"], now=later)
    assert [(e["rank"], e["name"]) for e in full["entries"]] == [(1, "Ana"), (1, "Ben"), (4, "Cem")], "gleiche Punkte gleicher Platz, ohne Opt-in nicht sichtbar"
    assert full["my_rank"] == 4 and not any("@" in e["name"] for e in full["entries"])


def test_bad_generation_is_not_published_and_can_be_retried(hosted):
    app, fake = hosted
    fake.reject = set(range(5))                                    # Pruefung lehnt 5 Aufgaben ab -> nur 10
    h = user(app, "x@example.org")
    t = generate(app, h)
    assert t["status"] == "failed" and "nicht veröffentlicht" in t["error"]
    st, _ = call(app, "POST", f"/weekly/tests/{t['id']}/attempt", h, {})
    assert st == 404
    fake.reject = set()
    t2 = generate(app, h)
    assert t2["id"] == t["id"] and t2["status"] == "published"


def test_broken_questions_are_filtered_by_code(hosted):
    app, fake = hosted
    fake.test = make_test(broken=3)
    t = generate(app, user(app, "y@example.org"))
    assert t["status"] == "published" and len(t["questions"]) == 15
    assert not any("Kaputte" in q["question"] for q in t["questions"])


def test_missing_materials_and_bad_keys(hosted):
    app, fake = hosted
    h = user(app, "z@example.org")
    assert call(app, "POST", f"/weekly/{KEY}/{WEEK}", h, {"term": TERM, "materials": []})[1]["code"] == "materials_missing"
    assert call(app, "POST", f"/weekly/{KEY}/{WEEK}", h, {"term": TERM, "materials": [MATS[2]]})[1]["code"] == "materials_missing", "nur Altklausur reicht nicht"
    assert call(app, "POST", f"/weekly/kaputt/{WEEK}", h, {"term": TERM, "materials": MATS})[1]["code"] == "course_invalid"
    assert call(app, "GET", f"/weekly/{KEY}/2026-44?term={TERM}", h)[1]["code"] == "week_invalid"
    assert call(app, "GET", f"/weekly/{KEY}/{WEEK}?term=x", h)[1]["code"] == "not_generated"


def test_ai_unavailable_marks_grading_pending(hosted):
    app, fake = hosted
    from app import ai_backend
    h = user(app, "k@example.org")
    t = generate(app, h)

    class Down:
        def complete(self, *a, **k):
            raise ai_backend.AIUnavailable("ai_provider_unreachable", "weg", 502)
    ai_backend.set_provider(Down())
    aid = call(app, "POST", f"/weekly/tests/{t['id']}/attempt", h, {})[1]["attempt"]["id"]
    st, r = call(app, "POST", f"/weekly/attempts/{aid}/submit", h, {"answers": {q["id"]: "etwas" for q in t["questions"]}, "leaderboard": True})
    assert r["attempt"]["status"] == "grading_pending" and r["attempt"]["needs_review"]


def test_points_sum_to_exactly_100_after_filtering(hosted):
    app, fake = hosted
    fake.test = make_test(n_short=4, n_medium=5, n_hard=4)          # 13 Aufgaben: ohne Ausgleich 100,1 statt 100
    t = generate(app, user(app, "p@example.org"))
    assert len(t["questions"]) == 13 and t["max_points"] == 100.0
    assert round(sum(q["points"] for q in t["questions"]), 1) == 100.0
