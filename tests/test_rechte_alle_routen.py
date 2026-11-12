"""Rechte-Test ueber ALLE Routen der App im Dienstmodus (Audit-Paket 38/39, 08.11.2026,
docs/audit/AUDIT-2026-11-08-PAKET-38-39.md).

1. Inventar: Die Routenliste kommt aus `app.routes` (auch eingebundene Router). Oeffentlich (ohne Anmeldung) sind
   genau `PUBLIC_API` (Methode + Pfad) und die Oberflaechenseiten `PUBLIC_PAGES`. Eine neue Route ist automatisch
   geschuetzt (hosted_guard); eine neue oeffentliche Route oder eine neue Methode auf einem oeffentlichen Pfad macht
   den Test rot, bis sie hier eingetragen ist.
2. Ohne Sitzung, mit erfundenem Token und mit widerrufener Sitzung antwortet jede andere /api-Route 401
   (`unauthenticated`) bzw. 501 (`not_available_hosted`, Pfade, die es im Dienst nicht gibt) - die Endpunkte laufen
   nie.
3. Zwei Konten A und B (beide Pro AI, bestaetigt, gleiche Hochschule). A hat Daten jedes Ressourcentyps: jede Tabelle
   der Konto-Datenbank, dazu Community (Loesung, Kommentar, Frage, Antwort, Korrektur, geteilter Stapel,
   Lerngruppe), geteilte Wochentests, Bibliotheksfrage, Sitzungen, Index-Auftrag. B ruft JEDE Route mit A's IDs in
   Pfad, Abfrage und Rumpf auf. Erwartet: Routen mit Pfad-ID antworten 403/404 (Ausnahmen mit Grund in
   `B_MAY_SUCCEED`), keine Antwort enthaelt Daten von A, nichts von A aendert sich (Konto-Datenbank byte-gleich,
   gemeinsame Datenbanken: keine Zeile von A geaendert, keine neue Zeile an A's Objekten) und keine Anfrage oeffnet
   im Dienst die Datenbank des Einzelplatzes (P38-04).
4. Dasselbe mit identischen lokalen IDs in B (Plan Schritt 2): B sieht nur eigene Daten, A bleibt unveraendert.
"""
from __future__ import annotations

import hashlib
import json
import re
import socket
import sqlite3
import time
from pathlib import Path

import pytest
from conftest import asgi_call
from test_subscriptions import FakeAI, _j, hosted, user  # noqa: F401 - hosted ist eine Fixture

A_MARK, B_MARK = "AGEHEIM7", "BGEHEIM7"
KEY_A = hashlib.sha256(b"uniflow.community.course.v1\x00luh\x00kurs-rechte-a").hexdigest()
GROUP_A = hashlib.sha256(b"rechte-gruppe-a").hexdigest()
FP_A = hashlib.sha256(b"rechte-pdf-a").hexdigest()
SHARE_KEY_A = "wt3:" + hashlib.sha256(b"rechte-wochentest-a").hexdigest()
FILE_KEY_A = hashlib.sha256(b"rechte-erklaerung-a").hexdigest()

# ---------------------------------------------------------------- 1. Inventar

# Ohne Anmeldung erreichbar (hosted_guard: account_api.PUBLIC_PATHS, billing_api.PUBLIC, app_login_api.PUBLIC).
# Jeder Eintrag ist eine bewusste Entscheidung; die Endpunkte pruefen selbst (Passwort, Signatur, Token, Code).
PUBLIC_API = {
    ("POST", "/api/account/register"): "Konto anlegen",
    ("POST", "/api/account/login"): "Anmelden (Passwort, Sperre nach Fehlversuchen)",
    ("POST", "/api/account/login/apple"): "Anmelden mit Apple (id_token wird geprueft)",
    ("POST", "/api/account/login/google"): "Anmelden mit Google (id_token wird geprueft)",
    ("POST", "/api/account/password/reset-request"): "Reset-Mail anfordern (Antwort immer gleich)",
    ("POST", "/api/account/password/reset"): "Passwort mit Reset-Token setzen",
    ("GET", "/api/account/info"): "Dienst-Infos (Hochschulen, Regeln), keine Kontodaten",
    ("GET", "/api/account/providers"): "verfuegbare Anmeldeanbieter",
    ("POST", "/api/account/verify-email"): "E-Mail mit Token bestaetigen",
    ("GET", "/api/billing/plans"): "Tarife und Preise",
    ("POST", "/api/billing/apple/notifications"): "App Store Server Notifications (signiert, app/apple_store.py)",
    ("POST", "/api/billing/stripe/webhook"): "Stripe-Webhook (Signatur, app/stripe_billing.py)",
    ("POST", "/api/app-login/token"): "Windows-App tauscht Code + PKCE-Verifier gegen Sitzung",
}
# Oberflaeche und Rechtstexte (keine /api-Pfade); `/`, `/index.html` leiten ohne Sitzung zur Anmeldung um
PUBLIC_PAGES = {"/login", "/abo-fertig", "/datenschutz", "/nutzungsbedingungen", "/impressum", "/konto-loeschen", "/konto/rueckkehr",
                # Domain-Bestaetigung fuer "Mit Apple anmelden" im Browser (12.11.2026): Apple holt sie ohne Anmeldung;
                # liefert nur die vom Inhaber abgelegte Datei, sonst 404 (tests/test_windows_fertigstellung_2026_11_12.py)
                "/.well-known/apple-developer-domain-association.txt"}
# Eingebaute Schnittstellenbeschreibung von FastAPI: im Dienst 404 (hosted_guard, _FASTAPI_DOC_PATHS)
DOC_PAGES = {"/openapi.json", "/docs", "/docs/oauth2-redirect", "/redoc"}


def all_routes(app) -> list[tuple[str, str]]:
    """(Methode, Pfadmuster) aller HTTP-Routen, auch aus eingebundenen Routern (FastAPI ab 0.13x: _IncludedRouter)."""
    out = set()

    def walk(routes, prefix=""):
        for r in routes:
            inner = getattr(r, "original_router", None)
            if inner is not None:
                walk(inner.routes, prefix + (r.include_context.prefix or ""))
                continue
            for m in getattr(r, "methods", None) or ():
                if m != "HEAD":
                    out.add((m, prefix + r.path))
    walk(app.routes)
    return sorted(out, key=lambda x: (x[1], x[0]))


def _matching(app, method: str, path: str) -> list[tuple[str, str]]:
    """Routenmuster, die ein konkreter Pfad mit dieser Methode trifft."""
    out = []
    for m, p in all_routes(app):
        rx = "^" + re.sub(r"\\\{[^}]+\\\}", "[^/]+", re.escape(p)) + "$"
        if m == method and re.match(rx, path):
            out.append((m, p))
    return out


def test_route_inventory_has_no_unreviewed_public_route(app):
    from app import account_api, app_login_api, billing_api
    routes = all_routes(app)
    assert len(routes) > 350, len(routes)
    bypass = account_api.PUBLIC_PATHS | billing_api.PUBLIC | app_login_api.PUBLIC
    assert bypass == {p for _, p in PUBLIC_API}, "oeffentliche Pfade in hosted_guard und PUBLIC_API muessen gleich sein"
    # jede Methode auf einem oeffentlichen Pfad ist eingetragen (hosted_guard prueft nur den Pfad, nicht die Methode)
    for p in bypass:
        hit = {m for m in ("GET", "POST", "PUT", "PATCH", "DELETE") if _matching(app, m, p)}
        assert hit == {m for m, q in PUBLIC_API if q == p}, (p, hit)
    pages = {p for _, p in routes if not p.startswith("/api/")}
    assert pages == PUBLIC_PAGES | DOC_PAGES, pages - PUBLIC_PAGES - DOC_PAGES


def _dummy(path: str) -> str:
    return re.sub(r"\{[^}]+\}", "1", path)


def _protected(app):
    return [(m, p) for m, p in all_routes(app) if p.startswith("/api/") and (m, p) not in PUBLIC_API]


def _hosted_unavailable(m, p):
    from app import server
    return server.hosted_unavailable(m, _dummy(p))


@pytest.mark.parametrize("token", [None, "Bearer erfunden-123", "revoked"])
def test_every_protected_route_needs_a_session(hosted, token):
    headers = {}
    if token == "revoked":
        _, h = user(hosted, "widerrufen@beispiel.de", plan="pro_ai")
        assert _j(asgi_call(hosted, "POST", "/api/account/logout", headers=h))[0] == 200
        headers = h
    elif token:
        headers = {"Authorization": token}
    wrong = []
    for m, p in _protected(hosted):
        st, _, b = asgi_call(hosted, m, _dummy(p), body="{}", headers=headers)
        code = (json.loads(b) if b else {}).get("code")
        want = (501, "not_available_hosted") if _hosted_unavailable(m, p) else (401, "unauthenticated")
        if (st, code) != want:
            wrong.append((m, p, st, code))
    assert not wrong, wrong
    # Cookie statt Bearer ebenso
    st, _, _ = asgi_call(hosted, "GET", "/api/files", cookies="uniflow_session=erfunden")
    assert st == 401


@pytest.mark.parametrize("path", ["/api/files/", "//api/files", "/api/account/info/../../api/files", "/API/files", "/api/files%2F",
                                  "/api/account/info/", "/api/account/register/x"])
def test_path_variants_do_not_bypass_the_guard(hosted, path):
    """hosted_guard vergleicht genaue Pfade: Varianten treffen keine Route ohne Anmeldung (401 oder 404, nie Daten)."""
    st, _, b = asgi_call(hosted, "GET", path)
    assert st in (401, 404, 405, 307), (path, st, b[:200])
    assert b"files" not in b or st == 401


def test_public_routes_answer_without_a_session(hosted):
    """Die oeffentlichen Routen sind wirklich ohne Sitzung erreichbar (sonst stuende hier ein falscher Eintrag)."""
    for (m, p) in PUBLIC_API:
        st, _, _ = asgi_call(hosted, m, p, body="{}")
        assert st != 401 or p == "/api/account/login", (m, p, st)       # falsches Passwort ist ebenfalls 401
    for p in PUBLIC_PAGES:
        st, _, _ = asgi_call(hosted, "GET", p)
        assert st != 401 and st < 500, (p, st)              # /konto/rueckkehr gibt es nur am PC (404 im Dienst)
    for p in DOC_PAGES:
        assert asgi_call(hosted, "GET", p)[0] == 404


# ---------------------------------------------------------------- 3. Zwei Konten: Daten von A

def _ctx(app, headers):
    from app import config
    st, me = _j(asgi_call(app, "GET", "/api/account/me", headers=headers))
    return me["user"]["id"], me["user"]["university"]


def in_user(app, headers, fn):
    from app import config, db
    uid, uni = _ctx(app, headers)
    t = config.set_user_context(uid, uni)
    try:
        db.init_db()
        with db.cursor() as conn:
            return fn(conn)
    finally:
        config.reset_user_context(t)


def _id_like(col: str) -> bool:
    return col == "id" or col.endswith("_id") or col.endswith("_key") or col in ("key", "gid", "sha", "uid")


def seed_every_table(conn, mark: str, files_dir: Path) -> dict:
    """Eine Zeile je Tabelle der Konto-Datenbank. ID-Spalten deterministisch (in A und B gleich), alle anderen Texte
    mit der Markierung des Kontos. Liefert {tabelle: rowid}."""
    conn.commit()
    conn.execute("PRAGMA foreign_keys=OFF")
    out = {}
    tables = [r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' "
                                         "AND name NOT LIKE '%_fts%' ORDER BY name")]
    pdf = files_dir / f"{mark}-skript.pdf"
    pdf.write_bytes(b"%PDF-1.4\n% " + mark.encode() + b" Geheimes Skript\n%%EOF\n")
    for t in tables:
        cols = list(conn.execute(f"PRAGMA table_info({t})"))
        names, vals = [], []
        for _cid, name, typ, _nn, _dflt, pk in cols:
            typ = (typ or "").upper()
            if pk and "INT" in typ and sum(1 for c in cols if c[5]) == 1:
                continue                                        # rowid: 1 in einer frischen Datenbank
            if name == "local_path":
                v = str(pdf)
            elif "INT" in typ:
                v = 1
            elif "REAL" in typ or "FLOA" in typ:
                v = 0.5
            elif _id_like(name):
                v = f"r-{t}"[:60] if name == "id" or pk else ("r-files" if name == "file_id" else f"r-{name}")
            elif name in ("questions", "answers", "messages", "cards", "options", "data", "payload", "pages", "items", "meta",
                          "objects", "json", "value_json", "feedback"):
                v = json.dumps([{"text": f"{mark} {t}.{name}"}])
            elif name in ("status",):
                v = "neu" if t == "files" else "active"
            else:
                v = f"{mark} {t}.{name}"
            names.append(name)
            vals.append(v)
        try:
            cur = conn.execute(f"INSERT OR IGNORE INTO {t}({','.join(names)}) VALUES ({','.join('?' * len(vals))})", vals)
            out[t] = cur.lastrowid
        except sqlite3.Error as e:                              # z. B. CHECK-Bedingung: Tabelle bleibt leer
            out[t] = f"leer: {e}"
    conn.commit()
    conn.execute("PRAGMA foreign_keys=ON")
    return out


def _package(fp, key_material="community-secret"):
    from app import community
    return community.sample_package(fp, display_name=f"{A_MARK} Autor", key_material=key_material)


def _week_test():
    """15 Aufgaben 4/6/5 (ai.check_week_test)"""
    qs = []
    for i, d in enumerate(["leicht"] * 4 + ["mittel"] * 6 + ["schwer"] * 5):
        qs.append({"question": f"{A_MARK} Aufgabe {i}: Was gilt?", "type": "mc", "options": ["a", "b", "c", "d"], "answer": "b",
                   "explanation": "weil", "difficulty": d, "points": 2})
    return qs


@pytest.fixture
def world(hosted, monkeypatch):
    """Konten A, B (Pro AI, bestaetigt, LUH) und C (Mitglied in A's Kurs); A hat Daten jedes Typs."""
    from app import ai_backend, community, config, test_library
    monkeypatch.setenv("LERNAPP_LIMIT_API_PER_MIN", "1000000")
    ai_backend.set_provider(FakeAI())
    real_connect = socket.socket.connect

    def no_network(self, addr):                         # keine echten Hochschul-, Mail- oder KI-Server
        host = addr[0] if isinstance(addr, tuple) else addr
        if host not in ("127.0.0.1", "::1", "localhost") and not str(host).startswith("/"):
            raise OSError(f"Netz im Rechte-Test gesperrt: {host}")
        return real_connect(self, addr)
    monkeypatch.setattr(socket.socket, "connect", no_network)
    for k in list(__import__("app.accounts", fromlist=["LIMITS"]).LIMITS):
        monkeypatch.setenv(f"LERNAPP_LIMIT_{k.upper()}", "100000/1")
    import shutil
    shutil.rmtree(community.package_dir(), ignore_errors=True)
    ua, ha = user(hosted, "konto-a@beispiel.de", plan="pro_ai")
    ub, hb = user(hosted, "konto-b@beispiel.de", plan="pro_ai")
    uc, hc = user(hosted, "konto-c@beispiel.de", plan="pro_ai")
    # zweite Sitzung von A (ein Geraet), deren ID B kennen koennte
    st, la = _j(asgi_call(hosted, "POST", "/api/account/login", body=json.dumps(
        {"email": "konto-a@beispiel.de", "password": "sehr-geheim-123", "device_name": f"{A_MARK} iPad"})))
    assert st == 200, la
    ha2 = {"Authorization": f"Bearer {la['token']}"}

    def files_dir(h):
        uid, uni = _ctx(hosted, h)
        t = config.set_user_context(uid, uni)
        try:
            return config.files_dir()
        finally:
            config.reset_user_context(t)
    seeded = in_user(hosted, ha, lambda conn: seed_every_table(conn, A_MARK, files_dir(ha)))

    def call(h, m, p, body=None):
        st, d = _j(asgi_call(hosted, m, p, headers=h, body=json.dumps(body) if body is not None else None))
        return st, d
    # Konto-Daten ueber die API (wie die Apps)
    st, stack = call(ha, "POST", "/api/flashcard-stacks", {"name": f"{A_MARK} Stapel"})
    assert st == 200, stack
    assert call(ha, "POST", "/api/flashcards", {"stack_id": stack["id"], "cards": [{"question": f"{A_MARK} F", "answer": "x"}]})[0] == 200
    assert call(ha, "POST", "/api/plan/items", {"day": 1, "title": f"{A_MARK} lernt"})[0] == 200
    assert call(ha, "PUT", "/api/tutor-conversations/r-files:1", {"file_name": f"{A_MARK}.pdf",
                                                                 "messages": [{"role": "user", "content": f"{A_MARK} Frage"}]})[0] == 200
    # Community: A und C im Kurs KEY_A, A mit Loesung, Kommentar, Frage, Antwort, Lerngruppe, geteiltem Stapel
    for h in (ha, hc):
        assert call(h, "POST", "/api/community/claims", {"fingerprints": [FP_A], "course_keys": [KEY_A]})[0] == 200
        assert call(h, "POST", f"/api/community/communities/{KEY_A}/join", {"kind": "course"})[0] == 200
    st, sol = call(ha, "POST", "/api/community/solutions", {"package": _package(FP_A), "title": f"{A_MARK} Loesung", "community_key": KEY_A})
    assert st == 201, sol
    st, sol_c = call(hc, "POST", "/api/community/solutions", {"package": _package(FP_A), "title": "C Loesung", "community_key": KEY_A})
    assert st == 201, sol_c
    st, com = call(ha, "POST", f"/api/community/solutions/{sol['solution_id']}/comments", {"text": f"{A_MARK} Kommentar"})
    assert st == 201, com
    st, q = call(ha, "POST", f"/api/community/courses/{KEY_A}/questions", {"title": f"{A_MARK} Frage", "body": f"{A_MARK} Text"})
    assert st == 201, q
    st, ans = call(hc, "POST", f"/api/community/questions/{q['id']}/answers", {"body": "C antwortet"})
    assert st == 201, ans
    st, ans_a = call(ha, "POST", f"/api/community/questions/{q['id']}/answers", {"body": f"{A_MARK} Antwort"})
    assert st == 201, ans_a
    import uuid
    corr_id = str(uuid.uuid4())
    import base64
    st, corr = call(ha, "POST", f"/api/community/solutions/{sol_c['solution_id']}/corrections",
                    {"id": corr_id, "payload": base64.b64encode(bytes([1]) + b"x" * 80).decode()})
    assert st == 201, corr
    corr_to_a = str(uuid.uuid4())
    assert call(hc, "POST", f"/api/community/solutions/{sol['solution_id']}/corrections",
                {"id": corr_to_a, "payload": base64.b64encode(bytes([1]) + b"y" * 80).decode()})[0] == 201
    assert call(ha, "POST", "/api/community/groups", {"group_key": GROUP_A, "name": f"{A_MARK} Gruppe"})[0] == 201
    st, cs = call(ha, "POST", "/api/community/card-stacks", {"community_key": KEY_A, "name": f"{A_MARK} geteilt", "kind": "eigene",
                                                             "cards": [{"question": f"{A_MARK} q", "answer": "a"}]})
    assert st == 201, cs
    assert call(hc, "POST", f"/api/community/solutions/{sol['solution_id']}/like")[0] == 200       # Benachrichtigung an A
    # Geteilter Wochentest: A belegt Variante 0 und veroeffentlicht, Variante 1 bleibt belegt
    assert call(ha, "POST", f"/api/v2/shared-tests/{SHARE_KEY_A}/claim", {"variant": 0})[1]["claimed"] is True
    st, pub = call(ha, "POST", f"/api/v2/shared-tests/{SHARE_KEY_A}/0", {"title": f"{A_MARK} Wochentest", "questions": _week_test()})
    assert st == 200, pub
    assert call(ha, "POST", f"/api/v2/shared-tests/{SHARE_KEY_A}/claim", {"variant": 1})[1]["claimed"] is True
    # Bibliotheksfrage zur Moderation (eigener Test von A)
    lib = test_library.submit_for_sharing(test_library.owner_hash(ua["id"]), [{"question": f"{A_MARK} Bibliotheksfrage: Was ist 2+2?",
                                          "options": ["3", "4", "5", "6"], "answer": "4", "explanation": "Rechnen", "difficulty": 2}],
                                          {"subject": "Mathe", "topic": f"{A_MARK} Thema", "university": "luh", "difficulty": 2})
    with test_library.cursor() as conn:
        lib_q = conn.execute("SELECT id FROM questions ORDER BY rowid DESC LIMIT 1").fetchone()[0]
    # Geteilte Erklaerung von A (Chiffrat, Erklaerungsspeicher app/page_explain.py)
    st, ex = call(ha, "POST", "/api/explain", {"file_key": FILE_KEY_A, "page": 1, "mode": "explain",
                                               "payload": base64.b64encode(bytes([1]) + b"e" * 80).decode()})
    assert st == 201, ex
    # Einladung von A
    st, inv = call(ha, "POST", "/api/invites")
    assert st == 201, inv
    # Index-Auftrag von A (PDF hochladen)
    pdf = b"%PDF-1.4\n% " + A_MARK.encode() + b"\n%%EOF\n"
    boundary = "rechteXgrenze"
    form = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file_sha\"\r\n\r\n{hashlib.sha256(pdf).hexdigest()}\r\n"
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"file_name\"\r\n\r\n{A_MARK}.pdf\r\n"
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"upload\"; filename=\"a.pdf\"\r\n"
            "Content-Type: application/pdf\r\n\r\n").encode() + pdf + f"\r\n--{boundary}--\r\n".encode()
    st, _, b = asgi_call(hosted, "POST", "/api/index/file", body=form, headers=ha, content_type=f"multipart/form-data; boundary={boundary}")
    assert st == 202, b
    job = json.loads(b)
    sessions_a = call(ha, "GET", "/api/account/me")[1]
    from app import accounts
    sid_a = [s["id"] for s in accounts.sessions(ua["id"])]
    pseudo_a = community.pseudonym(ua["id"])
    ids = {
        "solution_id": sol["solution_id"], "comment_id": com["id"], "qid": q["id"], "aid": ans_a["id"], "correction_id": corr_id,
        "correction_to_a": corr_to_a, "card_stack": cs["id"], "community_key": KEY_A, "course_key": KEY_A, "group_key": GROUP_A,
        "share_key": SHARE_KEY_A, "library_question": lib_q, "invite": inv["invite"]["code"] if isinstance(inv.get("invite"), dict) else None,
        "job_id": job["job_id"], "session_ids": sid_a, "pseudonym": pseudo_a, "local_stack": stack["id"], "fingerprint": FP_A,
        "user_id": ua["id"], "c_solution": sol_c["solution_id"],
    }
    return {"app": hosted, "a": ua, "ha": ha, "ha2": ha2, "b": ub, "hb": hb, "c": uc, "hc": hc, "ids": ids, "seeded": seeded,
            "lib": lib, "me_a": sessions_a}


# ---------------------------------------------------------------- Werte fuer Pfad, Abfrage, Rumpf

def path_values(ids: dict, path: str) -> dict:
    """A's IDs je Platzhalter; lokale IDs wie in seed_every_table (Zahl 1 bzw. r-<tabelle>)."""
    v = {
        "file_id": "r-files", "course_id": "r-courses", "module_id": "1", "stack_id": str(ids["local_stack"]), "card_id": "1",
        "test_id": "1", "task_id": "1", "package_id": "1", "marker_id": "1", "event_id": "1", "item_id": "1", "folder_id": "1",
        "def_id": "1", "rec_id": "1", "doc_id": "1", "text_id": "1", "thread_id": "r-studip_blubber", "entry_id": "r-studip_bulletin",
        "message_id": "r-studip_messages", "gid": "r-gid", "cert_id": "1", "window_id": "1", "version": "1", "page": "1", "nr": "1",
        "week": "1", "kind": "vorlesung", "mode": "explain", "variant": "0", "name": "a.png", "sha": ids["fingerprint"],
        "service": "studip", "provider": "apple", "user_id": ids["user_id"], "cmid": "1", "file_key": FILE_KEY_A,
        "key": "r-files:1", "solution_id": ids["solution_id"], "comment_id": ids["comment_id"], "qid": ids["qid"], "aid": ids["aid"],
        "correction_id": ids["correction_id"], "community_key": ids["community_key"], "course_key": ids["course_key"],
        "group_key": ids["group_key"], "pseudonym": ids["pseudonym"], "job_id": ids["job_id"], "session_id": str(ids["session_ids"][0]),
        "question_id": ids["library_question"], "target_id": ids["qid"],
    }
    if path.startswith("/api/community/card-stacks/"):
        v["stack_id"] = ids["card_stack"]
    if path.startswith("/api/community/bookmarks/"):
        v["kind"], v["target_id"] = "solution", ids["solution_id"]
    if path.startswith("/api/community/{kind}/"):
        v["kind"], v["target_id"] = "questions", ids["qid"]
    if path.startswith("/api/explain/"):
        v["variant"] = "1"
    if path.startswith("/api/v2/shared-tests/") or path.startswith("/api/library/week-keys/"):
        v["key"] = ids["share_key"]
    return v


def fill(path: str, values: dict) -> str:
    return re.sub(r"\{([^}:]+)(?::path)?\}", lambda m: str(values.get(m.group(1), "1")), path)


def universal_body(ids: dict) -> dict:
    """Rumpf mit A's IDs unter allen gaengigen Namen (Rumpf-IDs)."""
    return {
        "id": ids["correction_id"], "ids": [ids["correction_id"]], "file_id": "r-files", "file_ids": ["r-files"], "course_id": "r-courses",
        "module_id": 1, "stack_id": ids["local_stack"], "move_to": ids["local_stack"], "card_id": 1, "test_id": 1, "task_id": 1,
        "package_id": 1, "item_id": 1, "folder_id": 1, "parent_id": ids["comment_id"], "answer_id": ids["aid"],
        "solution_id": ids["solution_id"], "question_id": ids["qid"], "community_key": ids["community_key"],
        "course_key": ids["course_key"], "group_key": ids["group_key"], "key": ids["share_key"], "share_key": ids["share_key"],
        "session_id": ids["session_ids"][0], "user_id": ids["user_id"], "owner_id": ids["user_id"], "author_id": ids["user_id"],
        "code": ids["invite"], "fingerprint": ids["fingerprint"], "fingerprints": [ids["fingerprint"]], "job_id": ids["job_id"],
        "source_ref": ids["card_stack"], "variant": 0, "week": 1, "kind": "vorlesung", "status": "seen", "action": "restore",
        "reason": "spam", "text": "B war hier", "title": "B war hier", "name": "B war hier", "body": "B war hier", "confirm": True,
        "questions": [], "answers": {}, "items": [], "deletes": [{"entity": "flashcards", "id": 1}, {"entity": "files", "id": "r-files"}],
        "device_id": "geraet-b", "file_key": FILE_KEY_A, "page": 1, "mode": "explain", "role": "admin", "plan": "pro_ai",
        "university": "hildesheim", "email": "konto-a@beispiel.de",
    }


def universal_query(ids: dict) -> str:
    from urllib.parse import urlencode
    return urlencode({"fingerprint": ids["fingerprint"], "file_key": FILE_KEY_A, "module": ids["community_key"], "file_id": "r-files",
                      "key": ids["share_key"], "course_key": ids["course_key"], "community_key": ids["community_key"],
                      "module_id": 1, "week": 1, "page": 1, "user_id": ids["user_id"]})


# Routen mit Pfad-ID, bei denen B mit A's Wert 2xx bekommen darf - je mit Grund. Alles andere: 403/404 (bzw. 400/422,
# wenn die Eingabe vor jeder Suche abgelehnt wird). In allen Faellen gilt zusaetzlich: keine Daten von A in der Antwort,
# nichts von A geaendert (siehe sweep).
_OWN_DB = "eigene Konto-Datenbank: unbekannte ID ergibt eine leere Antwort bzw. ein idempotentes ok, A's Datenbank ist nie offen"
B_MAY_SUCCEED = {
    # Wissen = Zugang (bewusst, Produktentscheidung; Paket 3-4 Nr. 116-118, P39-03)
    ("GET", "/api/v2/shared-tests/{key}"): "P39-03: geteilte Wochentests per Kenntnis des Schluessels (Hochschule + SHA-256 der "
                                           "Dateien = wer fragt, hat die Dateien); ohne Konto-ID, nur bereinigte Aufgaben",
    ("POST", "/api/v2/shared-tests/{key}/claim"): "P39-03/04: freien Platz mit eigenem owner_hash belegen; A's Plaetze bleiben",
    ("DELETE", "/api/v2/shared-tests/{key}/{variant}"): "P39-11: gibt nur einen eigenen leeren Platz frei (sonst released: false)",
    ("GET", "/api/community/groups/{group_key}"): "Lerngruppe: wer den Code kennt, kennt den Schluessel und sieht Name und "
                                                  "Mitgliederzahl vor dem Beitritt (Paket 3-4 Nr. 116-118)",
    ("GET", "/api/explain/{file_key}/{page}/{mode}/{variant}"): "Erklaerungsspeicher: Chiffrat fuer alle mit dem Datei-Schluessel "
                                                               "(wie die oeffentliche CloudKit-Datenbank); loeschen nur der Ersteller",
    ("GET", "/api/library/week-keys/{key}"): "gemeinsame Wochenfragen per Schluessel (Pool ohne Kontodaten)",
    # wirken nur auf eigene Eintraege
    ("DELETE", "/api/community/bookmarks/{kind}/{target_id}"): "loescht nur ein eigenes Lesezeichen (idempotent)",
    ("DELETE", "/api/community/communities/{community_key}/join"): "austreten: nur die eigene Mitgliedschaft (idempotent)",
    # eigene Konto-Datenbank
    ("PUT", "/api/tutor-conversations/{key:path}"): _OWN_DB,
    ("GET", "/api/tutor-conversations/{key:path}"): _OWN_DB,
    ("DELETE", "/api/tutor-conversations/{key:path}"): _OWN_DB,
    ("GET", "/api/files/{file_id}/annotations/versions"): _OWN_DB,
    ("GET", "/api/files/{file_id}/recordings"): _OWN_DB,
    ("DELETE", "/api/folders/{folder_id}"): _OWN_DB,
    ("PATCH", "/api/library/files/{file_id}"): _OWN_DB,
    ("DELETE", "/api/modules/{module_id}"): _OWN_DB,
    ("GET", "/api/modules/{module_id}/studip"): _OWN_DB,
    ("DELETE", "/api/plan/items/{item_id}"): _OWN_DB,
    ("DELETE", "/api/timetable/events/{event_id}"): _OWN_DB,
    ("GET", "/api/weekly/module/{module_id}"): _OWN_DB,
}
# Antworten, in denen B A's Inhalte sehen darf (Wissen = Zugang)
B_MAY_SEE = {
    ("GET", "/api/community/groups/{group_key}"): "Name der Lerngruppe vor dem Beitritt",
    ("GET", "/api/v2/shared-tests/{key}"): "fertiger Wochentest (bereinigte Aufgaben, Titel) fuer alle mit dem Schluessel",
}
# Gueltige Rumpfe, damit die Eigentuemer-/Sichtbarkeitspruefung wirklich erreicht wird (sonst 400/422 vor der Suche)
BODY_FOR = {
    ("PUT", "/api/community/solutions/{solution_id}"): lambda ids: {"package": _package(ids["fingerprint"]) | {
        "header": {**_package(ids["fingerprint"])["header"], "solutionId": ids["solution_id"]}}, "community_key": ids["community_key"]},
    ("POST", "/api/community/solutions/{solution_id}/corrections"): lambda ids: {
        "id": "0b8f2a52-3f7e-4d55-9b1c-2a9e6c1d4f00", "payload": __import__("base64").b64encode(bytes([1]) + b"z" * 80).decode()},
    ("PUT", "/api/community/card-stacks/{stack_id}"): lambda ids: {"name": "B", "cards": [{"question": "q", "answer": "a"}]},
    ("POST", "/api/community/communities/{community_key}/join"): lambda ids: {"kind": "course"},
    ("POST", "/api/community/questions/{qid}/accept"): lambda ids: {"answer_id": ids["aid"]},
    ("POST", "/api/v2/shared-tests/{key}/{variant}"): lambda ids: {"title": "B", "questions": _week_test()},
    ("POST", "/api/community/solutions/{solution_id}/moderate"): lambda ids: {"action": "remove"},
    ("POST", "/api/community/{kind}/{target_id}/moderate"): lambda ids: {"action": "restore"},
}
# Routen, deren Pruefung mit dem Rumpf oben sicher erreicht wird: genau diese Antworten
MUST_REFUSE = {
    ("PUT", "/api/community/solutions/{solution_id}"): (403,),            # not_owner
    ("POST", "/api/community/solutions/{solution_id}/corrections"): (404,),
    ("PUT", "/api/community/card-stacks/{stack_id}"): (403,),
    ("DELETE", "/api/community/card-stacks/{stack_id}"): (403,),
    ("POST", "/api/community/communities/{community_key}/join"): (403,),  # course_not_owned
    ("POST", "/api/v2/shared-tests/{key}/{variant}"): (409,),             # not_claimed
    ("DELETE", "/api/explain/{file_key}/{page}/{mode}/{variant}"): (403,),
    ("DELETE", "/api/account/sessions/{session_id}"): (404,),
    ("DELETE", "/api/community/solutions/{solution_id}"): (403,),
    ("DELETE", "/api/community/comments/{comment_id}"): (403,),
    ("PATCH", "/api/community/comments/{comment_id}"): (403, 404),
    ("DELETE", "/api/community/questions/{qid}"): (403,),
    ("PATCH", "/api/community/questions/{qid}"): (403,),
    ("DELETE", "/api/community/answers/{aid}"): (403,),
    ("PATCH", "/api/community/answers/{aid}"): (403,),
    ("POST", "/api/community/questions/{qid}/accept"): (404,),
    ("DELETE", "/api/community/corrections/{correction_id}"): (403,),
    ("POST", "/api/community/corrections/{correction_id}/status"): (404,),
    ("GET", "/api/community/corrections/{correction_id}"): (404,),
    ("POST", "/api/community/solutions/{solution_id}/moderate"): (403,),
    ("POST", "/api/community/{kind}/{target_id}/moderate"): (403,),
    ("POST", "/api/library/questions/{question_id}/moderate"): (403,),
    ("GET", "/api/index/jobs/{job_id}"): (404,),
    ("POST", "/api/community/solutions/{solution_id}/block"): (404,),
    ("POST", "/api/community/bookmarks/{kind}/{target_id}"): (404,),
}
# Serverfehler, die kein Rechteproblem sind (fehlende Eingabepruefung, der Rumpf des Durchlaufs passt nicht), mit Verweis
KNOWN_500 = {
    ("POST", "/api/packages"): "api_package_create: KeyError bei fehlendem `date` (Audit-Paket 34, anderer Zweig)",
    ("POST", "/api/timetable/exceptions"): "api_tt_exception: KeyError bei fehlendem `event_id` (Audit-Paket 34, anderer Zweig)",
}
# Zeilen in gemeinsamen Datenbanken, die B an A's Objekten anlegen darf
B_MAY_ADD = {
    ("accounts", "invite_redemptions"): "Einladungscode von A einloesen ist der Zweck der Einladung (app/invites.py)",
}
# Ohne ID, wirken nur auf das eigene Konto/die eigene Sitzung: im Durchlauf ausgelassen (B bliebe sonst nicht
# angemeldet), eigene Tests in tests/test_audit_paket_38_39.py (P38-09).
SELF_ONLY = {("POST", "/api/account/logout"), ("POST", "/api/account/logout-all"), ("POST", "/api/account/delete"),
             ("POST", "/api/account/university"), ("POST", "/api/account/password")}


# ---------------------------------------------------------------- Abbild: was gehoert A?

# Zaehler, die jede berechtigte Nutzung erhoeht (B uebernimmt den fertigen Wochentest von A: `uses` + 1)
COUNTERS = {"shared_tests": {"uses"}}


def _dump(path: Path) -> dict:
    if not path.exists():
        return {}
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        out = {}
        for (t,) in conn.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"):
            cols = [c[1] for c in conn.execute(f"PRAGMA table_info({t})") if c[1] not in COUNTERS.get(t, ())]
            out[t] = (cols, sorted(repr(tuple(r)) for r in conn.execute(f"SELECT {','.join(cols)} FROM {t}")))
        return out
    finally:
        conn.close()


def account_snapshot(uid: str) -> dict:
    """Alle Datenbanken und Dateien unter users/<A>/ (Inhalt der Tabellen bzw. SHA-256 der Dateien)."""
    from app import config
    root = config.BASE_DATA_DIR / "users" / uid
    out = {}
    for p in sorted(root.rglob("*")):
        if p.is_file() and p.suffix == ".db":
            out[str(p.relative_to(root))] = _dump(p)
        elif p.is_file() and not p.name.endswith(("-wal", "-shm", "-journal")) and "logs" not in p.parts:
            out[str(p.relative_to(root))] = hashlib.sha256(p.read_bytes()).hexdigest()
    return out


def shared_dbs():
    from app import accounts, community, test_library
    return {"accounts": accounts.db_path(), "community": community.db_path(), "library": test_library.db_path()}


def shared_snapshot() -> dict:
    return {k: _dump(p) for k, p in shared_dbs().items()}


def touched_a(before: dict, after: dict, a_values: set[str]) -> list:
    """Zeilen der gemeinsamen Datenbanken mit A's Werten (Konto-ID, Objekt-IDs, Markierung), die sich geaendert haben,
    verschwunden sind oder neu dazukamen (z. B. ein Like von B an A's Loesung, eine Benachrichtigung an A)."""
    bad = []
    for dbname in before:
        for t, (cols, rows_b) in before[dbname].items():
            rows_a = after[dbname].get(t, (cols, []))[1]
            for r in set(rows_b) ^ set(rows_a):
                if (dbname, t) in B_MAY_ADD and r not in rows_b:
                    continue
                if any(v in r for v in a_values):
                    bad.append((dbname, t, "weg" if r in rows_b else "neu", r[:300]))
        for t in set(after[dbname]) - set(before[dbname]):
            for r in after[dbname][t][1]:
                if any(v in r for v in a_values):
                    bad.append((dbname, t, "neu", r[:300]))
    return bad


def sweep(world, headers, routes, check_status=True):
    """Ruft jede Route als B mit A's IDs auf. Liefert (Ergebnisse, Probleme, Hintergrundlaeufe)."""
    from app import config, db, server
    app, ids = world["app"], world["ids"]
    body = json.dumps(universal_body(ids))
    query = universal_query(ids)
    # A's Konto-ID steht absichtlich im Rumpf (user_id, owner_id, author_id): B's eigene Einstellungen spiegeln sie
    # zurueck (PUT /api/settings, P32-07). Geprueft wird sie ueber die Datenbanken (touched_a), nicht in der Antwort.
    leaks = [A_MARK, world["a"]["email"], ids["pseudonym"]]
    results, problems = [], []
    global_db, bg = [], []
    real_connect, real_bg = db.connect, server._run_bg

    def watch():
        if config.is_hosted() and not config.current_user_id():
            global_db.append(True)
        return real_connect()
    db.connect = watch
    server._run_bg = lambda name, fn: bg.append(name) or {"started": name}
    try:
        for m, p in routes:
            if (m, p) in SELF_ONLY:
                continue
            url = fill(p, path_values(ids, p))
            route_body = json.dumps({**json.loads(body), **BODY_FOR[(m, p)](ids)}) if (m, p) in BODY_FOR else body
            if m == "GET":
                url += ("&" if "?" in url else "?") + query
            n0 = len(global_db)
            t0 = time.monotonic()
            try:
                st, _, b = asgi_call(app, m, url, body=None if m == "GET" else route_body, headers=headers)
            except Exception as e:  # noqa: BLE001 - uvicorn antwortete 500
                st, b = 500, repr(e).encode()
            dt = time.monotonic() - t0
            text = b.decode("utf-8", "replace") if isinstance(b, bytes) else str(b)
            results.append((m, p, st, round(dt, 3)))
            if st == 401:
                problems.append((m, p, st, "B ist nicht mehr angemeldet?", text[:200]))
            for mark in leaks:
                if mark and mark in text and (m, p) not in B_MAY_SEE:
                    problems.append((m, p, st, f"Antwort enthaelt Daten von A ({mark[:12]})", text[:300]))
            if len(global_db) > n0:
                problems.append((m, p, st, "oeffnet die Datenbank des Einzelplatzes ohne Konto-Kontext", ""))
            if check_status and (m, p) in MUST_REFUSE and st not in MUST_REFUSE[(m, p)]:
                problems.append((m, p, st, f"erwartet {MUST_REFUSE[(m, p)]} (Pruefung erreicht)", text[:300]))
            if check_status and "{" in p and 200 <= st < 300 and (m, p) not in B_MAY_SUCCEED:
                problems.append((m, p, st, "2xx mit A's ID", text[:300]))
            if check_status and st == 500 and (m, p) not in KNOWN_500:
                problems.append((m, p, st, "Serverfehler", text[:300]))
    finally:
        db.connect, server._run_bg = real_connect, real_bg
    return results, problems, bg


def _a_values(world) -> set[str]:
    ids = world["ids"]
    vals = {world["a"]["id"], A_MARK, ids["solution_id"], ids["comment_id"], ids["qid"], ids["aid"], ids["correction_id"],
            ids["correction_to_a"], ids["card_stack"], ids["group_key"], ids["job_id"], ids["pseudonym"], ids["library_question"]}
    return {v for v in vals if v}


def _run_sweep(world, phase):
    app = world["app"]
    routes = [(m, p) for m, p in all_routes(app) if p.startswith("/api/") and (m, p) not in PUBLIC_API]
    a_before, s_before = account_snapshot(world["a"]["id"]), shared_snapshot()
    results, problems, bg = sweep(world, world["hb"], routes, check_status=(phase == 1))
    assert _j(asgi_call(app, "GET", "/api/account/me", headers=world["ha"]))[0] == 200, "A ist noch angemeldet"
    assert _j(asgi_call(app, "GET", "/api/account/me", headers=world["ha2"]))[0] == 200, "A's zweites Geraet ebenso"
    a_after, s_after = account_snapshot(world["a"]["id"]), shared_snapshot()
    changed = sorted(k for k in set(a_before) | set(a_after) if a_before.get(k) != a_after.get(k))
    return results, problems, bg, changed, touched_a(s_before, s_after, _a_values(world))


def test_account_b_cannot_reach_data_of_account_a_on_any_route(world):
    import collections
    results, problems, bg, changed, touched = _run_sweep(world, 1)
    print("Statusverteilung:", sorted(collections.Counter(st for _, _, st, _ in results).items()))
    print("Langsam:", sorted((dt, m, p) for m, p, st, dt in results if dt > 1)[-10:])
    print("Hintergrundlaeufe im Dienst:", bg)
    print("ID-Routen ohne 403/404:", [(m, p, st) for m, p, st, _ in results if "{" in p and st not in (403, 404)])
    assert len(results) > 350
    # Rolle, Hochschule und E-Mail standen im Rumpf jeder Anfrage (role=admin, university=hildesheim, A's E-Mail)
    me = _j(asgi_call(world["app"], "GET", "/api/account/me", headers=world["hb"]))[1]["user"]
    assert (me.get("role"), me["university"], me["email"]) == ("user", "luh", world["b"]["email"]), me
    assert not changed and not touched and not problems, "\n".join(map(str, [("A geaendert", changed)] + touched + problems))


def test_identical_local_ids_in_b_never_reach_a(world):
    """Plan Schritt 2: B hat dieselben lokalen IDs (jede Tabelle, gleiche Werte) - B sieht nur eigene Daten."""
    from app import config

    def files_dir():
        uid, uni = _ctx(world["app"], world["hb"])
        t = config.set_user_context(uid, uni)
        try:
            return config.files_dir()
        finally:
            config.reset_user_context(t)
    in_user(world["app"], world["hb"], lambda conn: seed_every_table(conn, B_MARK, files_dir()))
    results, problems, bg, changed, touched = _run_sweep(world, 2)
    assert not changed, ("A's Konto-Datenbank/Dateien geaendert", changed)
    assert not touched, "\n".join(map(str, touched))
    assert not problems, "\n".join(map(str, problems))
    st, _, b = asgi_call(world["app"], "GET", "/api/files/r-files/content", headers=world["hb"])
    assert st == 200 and B_MARK.encode() in b and A_MARK.encode() not in b
