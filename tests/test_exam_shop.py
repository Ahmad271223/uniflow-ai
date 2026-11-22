"""Klausur-Generator im Dienst (app/exam_shop.py): einmal erzeugen, an alle verkaufen, 15 Credits je Probeklausur,
bei Fehlschlag nichts berechnen (Auftrag des Inhabers 17./18.11.2026)."""
import json
import threading

import pytest
from conftest import asgi_call
from test_subscriptions import _j, ent, hosted, user  # noqa: F401

pytest.importorskip("reportlab")

SHA_VL, SHA_UB, SHA_AK = "a" * 64, "b" * 64, "c" * 64
FILES = [{"sha256": SHA_VL, "doc_type": "vorlesung", "pages": 3},
         {"sha256": SHA_UB, "doc_type": "uebung", "pages": 1},
         {"sha256": SHA_AK, "doc_type": "klausur", "pages": 2}]
TEXTS = [{"sha256": SHA_VL, "title": "VL01 Folgen", "pages": ["Folgen und Grenzwerte", "Konvergenz", "Reihen"]},
         {"sha256": SHA_UB, "title": "Blatt 1", "pages": ["Aufgabe 1: Zeigen Sie, dass 1/n gegen 0 geht."]},
         {"sha256": SHA_AK, "title": "Altklausur WS 24", "pages": ["Aufgabe 1 (4 Punkte): Grenzwert", "Aufgabe 2 (6 Punkte): Reihe"]}]


class ShopFake:
    """Schein-KI: Analyse, Probeklausur, Pruefen, Nachbessern; zaehlt die Aufrufe je Art"""

    def __init__(self, fail_exam=False, wrong_once=False):
        self.lock = threading.Lock()
        self.calls: list[str] = []
        self.fail_exam, self.wrong_once = fail_exam, wrong_once
        self.prompts: list[str] = []

    def exam(self, n, fixed=False):
        return {"typ": "klausur", "fach": "Analysis I", "titel": f"Probeklausur {n}", "untertitel": "Format wie die echte Klausur",
                "meta": {"dauer": "90 Minuten", "punkte": 10, "hilfsmittel": "keine", "semester": "WS 2026/27"},
                "hinweis": "Bitte geben Sie bei allen Lösungen den Rechenweg an.",
                "aufgaben": [{"nr": 1, "punkte": "4", "text": f"Bestimmen Sie lim 1/n (Variante {n}).", "teile": []},
                             {"nr": 2, "punkte": "6", "text": "Konvergiert Σ 1/n²?", "teile": []}],
                "loesungen": [{"nr": 1, "merke": "Grenzwert einsetzen", "wichtig": "Nicht 1 schreiben",
                               "teile": [{"label": "", "schritte": ["1/n wird beliebig klein"], "ergebnis": "0" if fixed or not self.wrong_once else "1"}]},
                              {"nr": 2, "merke": "Vergleich mit 1/n²", "wichtig": "",
                               "teile": [{"label": "", "schritte": ["Σ 1/n² = π²/6"], "ergebnis": "konvergent"}]}]}

    def complete(self, system, prompt, schema=None):
        from app.ai_backend import Completion
        with self.lock:
            self.prompts.append(prompt)
            if prompt.startswith("Analysiere"):
                kind, out = "analyse", {"format": {"aufgaben": 2, "punkte": 10, "dauer": "90 Minuten", "fach": "Analysis I"},
                                        "themen": [{"name": "Grenzwerte", "haeufigkeit": "1 von 1"}], "muster": ["Aufgabe 1 Grenzwert"]}
            elif prompt.startswith("Erstelle Probeklausur"):
                if self.fail_exam:
                    raise RuntimeError("Anbieter gestört")
                n = int(prompt.split("Nummer ")[1].split(" ")[0])
                kind, out = "probeklausur", self.exam(n)
            elif prompt.startswith("Prüfe"):
                wrong = self.wrong_once and '"ergebnis": "1"' in prompt
                kind, out = "pruefen", {"fehler": [{"nr": 1, "label": "", "problem": "lim 1/n ist 0", "richtig": "0"}] if wrong else []}
            elif prompt.startswith("Bessere"):
                kind, out = "nachbessern", self.exam(int(prompt.split('"titel": "Probeklausur ')[1].split('"')[0]), fixed=True)
            else:
                raise AssertionError(prompt[:80])
            self.calls.append(kind)
        return Completion(json.dumps(out, ensure_ascii=False), 1000, 500, "fake")


@pytest.fixture
def fake():
    import shutil

    from app import ai_backend, exam_shop
    shutil.rmtree(exam_shop.base_dir(), ignore_errors=True)       # jede Probe mit leerem Laden
    f = ShopFake()
    ai_backend.set_provider(f)
    yield f
    ai_backend.set_provider(None)
    shutil.rmtree(exam_shop.base_dir(), ignore_errors=True)


def call(app, method, path, h, body=None):
    st, _, b = asgi_call(app, method, path, headers=h, body=json.dumps(body) if body is not None else None)
    return st, b


def jcall(app, method, path, h, body=None):
    st, b = call(app, method, path, h, body)
    return st, (json.loads(b) if b else None)


def used(app, h):
    return ent(app, h)["credits"]["used"]


def test_first_buyer_creates_everyone_else_buys_ready(hosted, fake):
    from app import exam_shop
    ua, ha = user(hosted, "pk-a@beispiel.de", plan="pro_ai")
    ub, hb = user(hosted, "pk-b@beispiel.de", plan="pro_ai")

    st, d = jcall(hosted, "POST", "/api/exam-shop/offer", ha, {"files": FILES})
    assert st == 200 and d["price"] == 15 and d["ready"] == 0 and len(d["variants"]) == 10, d

    # ohne Seitentexte geht es beim ersten Mal nicht, und es kostet nichts
    st, d = jcall(hosted, "POST", "/api/exam-shop/buy", ha, {"files": FILES, "count": 2})
    assert st == 409 and d["code"] == "needs_texts" and used(hosted, ha) == 0

    st, d = jcall(hosted, "POST", "/api/exam-shop/buy", ha, {"files": FILES, "count": 2, "texts": TEXTS, "wait_s": 30})
    assert st == 200, d
    assert [v["status"] for v in d["variants"][:3]] == ["ready", "ready", "none"]
    assert [v["paid"] for v in d["variants"][:3]] == [True, True, False]
    assert d["variants"][0]["title"] == "Probeklausur 1"
    assert fake.calls == ["analyse", "probeklausur", "pruefen", "probeklausur", "pruefen"], "Analyse einmal je Unterlagen"
    assert used(hosted, ha) == 30, "2 x 15 Credits"
    assert "Andere Aufgaben als in diesen früheren" in fake.prompts[3], "Probeklausur 2 kennt Nummer 1"

    # PDF: Aufgaben und Lösungen fuer den Kaeufer, fuer andere nicht
    key = d["variants"][0]["key"]
    st, b = call(hosted, "GET", f"/api/exam-shop/item/{key}/pdf/aufgaben", ha)
    assert st == 200 and b.startswith(b"%PDF-")
    st, b = call(hosted, "GET", f"/api/exam-shop/item/{key}/pdf/loesungen", ha)
    assert st == 200 and b.startswith(b"%PDF-")
    assert call(hosted, "GET", f"/api/exam-shop/item/{key}/pdf/aufgaben", hb)[0] == 404

    # Seitentexte sind nach dem Erzeugen weg, in der Ablage stehen keine Namen
    assert not exam_shop.material_path(d["set_key"]).exists()
    c = exam_shop.connect()
    stored = c.execute("SELECT files FROM sets").fetchone()["files"]
    c.close()
    assert "Folgen" not in stored and "Altklausur WS 24" not in stored

    # zweites Konto, dieselben Dateien: sofort fertig, keine KI, gleiche Probeklausuren
    calls = len(fake.calls)
    st, d = jcall(hosted, "POST", "/api/exam-shop/offer", hb, {"files": list(reversed(FILES))})
    assert d["ready"] == 2 and not any(v["owned"] for v in d["variants"])
    st, d = jcall(hosted, "POST", "/api/exam-shop/buy", hb, {"files": FILES, "count": 2})
    assert st == 200 and [v["paid"] for v in d["variants"][:2]] == [True, True], d
    assert len(fake.calls) == calls and used(hosted, hb) == 30
    assert call(hosted, "GET", f"/api/exam-shop/item/{key}/pdf/aufgaben", hb)[0] == 200

    # eine dritte braucht wieder die Seitentexte (der Dienst hat sie geloescht)
    st, d = jcall(hosted, "POST", "/api/exam-shop/buy", hb, {"files": FILES, "count": 1})
    assert st == 409 and d["code"] == "needs_texts" and used(hosted, hb) == 30


def test_mine_lists_bought_exams_of_the_account_only(hosted, fake):
    """22.11.2026: das Geraet holt Gekauftes von selbst ab und braucht dafuer die Liste des Kontos ohne Auswahl."""
    ua, ha = user(hosted, "pk-mine-a@beispiel.de", plan="pro_ai")
    ub, hb = user(hosted, "pk-mine-b@beispiel.de", plan="pro_ai")
    st, d = jcall(hosted, "GET", "/api/exam-shop/mine", ha)
    assert st == 200 and d == {"items": []}

    st, d = jcall(hosted, "POST", "/api/exam-shop/buy", ha, {"files": FILES, "count": 2, "texts": TEXTS, "wait_s": 30})
    assert st == 200, d
    st, m = jcall(hosted, "GET", "/api/exam-shop/mine", ha)
    assert st == 200 and [(i["variant"], i["status"], i["paid"], i["title"]) for i in m["items"]] == \
        [(1, "ready", True, "Probeklausur 1"), (2, "ready", True, "Probeklausur 2")], m
    assert m["items"][0]["key"] == d["variants"][0]["key"] and m["items"][0]["set_key"] == d["set_key"]
    assert m["items"][0]["files"] == sorted([SHA_VL, SHA_UB, SHA_AK]), "Fingerabdruecke der Unterlagen, sonst nichts"
    assert "Folgen" not in json.dumps(m) and "doc_type" not in json.dumps(m)

    # ein anderes Konto sieht davon nichts; ohne Pro AI gibt es die Liste nicht
    assert jcall(hosted, "GET", "/api/exam-shop/mine", hb)[1] == {"items": []}
    up, hp = user(hosted, "pk-mine-plus@beispiel.de", plan="plus")
    assert call(hosted, "GET", "/api/exam-shop/mine", hp)[0] == 403


def test_failure_costs_nothing_and_can_be_retried(hosted, fake):
    u, h = user(hosted, "pk-fehler@beispiel.de", plan="pro_ai")
    fake.fail_exam = True
    st, d = jcall(hosted, "POST", "/api/exam-shop/buy", h, {"files": FILES, "count": 1, "texts": TEXTS, "wait_s": 30})
    assert st == 200 and d["variants"][0]["status"] == "failed" and not d["variants"][0]["owned"], d
    assert used(hosted, h) == 0, "nichts berechnet"
    assert jcall(hosted, "GET", "/api/exam-shop/mine", h)[1] == {"items": []}, "Gescheitertes steht nicht in der Liste"
    fake.fail_exam = False
    st, d = jcall(hosted, "POST", "/api/exam-shop/buy", h, {"files": FILES, "count": 1, "texts": TEXTS, "wait_s": 30})
    assert st == 200 and d["variants"][0]["status"] == "ready" and d["variants"][0]["paid"], d
    assert used(hosted, h) == 15
    assert fake.calls.count("analyse") == 1, "die Analyse vom ersten Versuch bleibt"


def test_wrong_result_is_fixed_before_selling(hosted, fake):
    from app import exam_shop
    fake.wrong_once = True
    u, h = user(hosted, "pk-pruefen@beispiel.de", plan="pro_ai")
    st, d = jcall(hosted, "POST", "/api/exam-shop/buy", h, {"files": FILES, "count": 1, "texts": TEXTS, "wait_s": 30})
    assert st == 200 and d["variants"][0]["status"] == "ready", d
    assert fake.calls == ["analyse", "probeklausur", "pruefen", "nachbessern"]
    c = exam_shop.connect()
    exam = json.loads(c.execute("SELECT result FROM items").fetchone()["result"])
    c.close()
    assert exam["loesungen"][0]["teile"][0]["ergebnis"] == "0", "nachgebessert"


def test_limits_plan_and_credits(hosted, fake):
    u, h = user(hosted, "pk-plus@beispiel.de", plan="plus")
    st, d = jcall(hosted, "POST", "/api/exam-shop/offer", h, {"files": FILES})
    assert st == 403 and d["detail"]["code"] == "plan_required" if isinstance(d.get("detail"), dict) else d["code"] == "plan_required"

    u, h = user(hosted, "pk-grenzen@beispiel.de", plan="pro_ai")
    many = [{"sha256": f"{i:064x}", "doc_type": "vorlesung", "pages": 31} for i in range(10)]
    st, d = jcall(hosted, "POST", "/api/exam-shop/offer", h, {"files": many})
    assert st == 422 and d["code"] == "too_many_pages"
    exams = [{"sha256": f"{i:064x}", "doc_type": "klausur", "pages": 5} for i in range(11)] + FILES[:1]
    assert jcall(hosted, "POST", "/api/exam-shop/offer", h, {"files": exams})[1]["code"] == "too_many_exams"
    only_exams = [{"sha256": SHA_AK, "doc_type": "klausur", "pages": 2}]
    assert jcall(hosted, "POST", "/api/exam-shop/offer", h, {"files": only_exams})[1]["code"] == "no_lecture"
    st, d = jcall(hosted, "POST", "/api/exam-shop/buy", h, {"files": FILES, "count": 11, "texts": TEXTS})
    assert st == 422 and d["code"] == "bad_count"

    # 100 Monats-Credits reichen fuer 6 Probeklausuren, die siebte nicht: 429 und nichts reserviert
    st, d = jcall(hosted, "POST", "/api/exam-shop/buy", h, {"files": FILES, "count": 6, "texts": TEXTS, "wait_s": 60})
    assert st == 200 and sum(v["paid"] for v in d["variants"]) == 6, d
    assert used(hosted, h) == 90
    st, d = jcall(hosted, "POST", "/api/exam-shop/buy", h, {"files": FILES, "count": 1, "texts": TEXTS})
    assert st == 429 and d["code"] == "credits_exhausted", d
    assert used(hosted, h) == 90 and ent(hosted, h)["credits"]["reserved"] == 0


def test_unknown_pdf_paths(hosted, fake):
    u, h = user(hosted, "pk-pfad@beispiel.de", plan="pro_ai")
    assert call(hosted, "GET", "/api/exam-shop/item/../../etc/pdf/aufgaben", h)[0] == 404
    assert call(hosted, "GET", f"/api/exam-shop/item/pk-{'0' * 40}-01/pdf/aufgaben", h)[0] == 404
