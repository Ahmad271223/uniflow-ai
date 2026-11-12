"""Externer statischer Audit vom 09.11.2026, Pakete 58, 66, 74 (Server-Seite), 80 und 81
(docs/audit/AUDIT-2026-11-09-PAKET-58-66-74-80-81.md).

58 API-Angriffsschutz/Uploads/XSS/SQL, 66 und 74 Community (Freigaben, Moderation, Datenschutz), 80 Datenschutz/IDOR/
SSRF/Logs, 81 Kontoloeschung/Export/Aufbewahrung. Das meiste ist in frueheren Paketen schon belegt (Verweise im
Bericht); hier stehen die neu bestaetigten Befunde (erst rot, dann der kleinste Fix) und Tests, die eine bisher nur
behauptete Aussage festnageln. Alles im Temp-Datenordner der Suite, kein Netz, keine echten Konten.
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import os
import re
import time
import uuid
from pathlib import Path

import pytest
from conftest import asgi_call
from test_security import _add_file, _multipart
from test_subscriptions import _j, hosted, user  # noqa: F401 - Fixtures

ROOT = Path(__file__).resolve().parents[1]
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64
JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 64
EVIL = "https://evil.example"


def _h(hdrs, name: str) -> str:
    return next((v.decode() for k, v in hdrs if k.decode().lower() == name), "")


def _in_user(headers_or_user, app=None):
    """Datenordner des Kontos als Kontext (wie im Dienst je Anfrage)."""
    from app import config
    u = headers_or_user
    return config.set_user_context(u["id"], u.get("university") or "luh")


def _upload_asset(app, h, file_id: str, name: str, data: bytes):
    body, ctype = _multipart("upload", name, data)
    return asgi_call(app, "POST", f"/api/files/{file_id}/assets", body=body, content_type=ctype, headers=h)


def _file_for(u, file_id="f-p58"):
    from app import config, db
    tok = _in_user(u)
    try:
        db.init_db()
        _add_file(file_id)
    finally:
        config.reset_user_context(tok)


# ================================================================ Paket 58

def test_p58_f1_asset_content_must_be_an_image_or_pdf(hosted):
    """Bestaetigt: Bild-Uploads im Editor wurden nur nach der Endung angenommen - eine HTML-/Skriptdatei als `a.png`
    oder Text als `a.pdf` lag danach als Asset im Konto. Die Auslieferung war schon entschaerft (nosniff, Sandbox,
    nur das eigene Konto), jetzt prueft der Dienst zusaetzlich die Anfangsbytes. Ein JPEG mit Endung .png bleibt
    erlaubt (Browser dekodieren Bilder nach Inhalt), ebenso echtes SVG."""
    from app import config, server
    u, h = user(hosted, "asset-a@beispiel.de", plan="pro_ai")
    _file_for(u)
    bad = [("a.png", b"<html><script>alert(1)</script></html>"), ("a.gif", b"GIF-nicht <script>"),
           ("a.pdf", b"<!doctype html><p>keine PDF"), ("a.svg", b"\x89PNG\r\n\x1a\n kein svg"),
           ("a.webp", b"RIFF\x00\x00\x00\x00WAVEfmt "), ("a.jpg", b"")]
    for name, data in bad:
        st, _, b = _upload_asset(hosted, h, "f-p58", name, data)
        assert st == 400, (name, st, b)
    tok = _in_user(u)
    try:
        left = list((server._assets_dir() / "f-p58").glob("*")) if (server._assets_dir() / "f-p58").exists() else []
    finally:
        config.reset_user_context(tok)
    assert left == [], f"abgewiesene Uploads duerfen nicht liegen bleiben: {left}"
    good = [("a.png", PNG), ("b.png", JPEG), ("c.jpg", JPEG), ("d.gif", b"GIF89a" + b"\x00" * 20),
            ("e.webp", b"RIFF\x10\x00\x00\x00WEBPVP8 " + b"\x00" * 20), ("f.pdf", b"%PDF-1.7\n%\xe2\xe3\n"),
            ("g.svg", b'<?xml version="1.0"?>\n<svg xmlns="http://www.w3.org/2000/svg"/>'),
            ("h.svg", b'\xef\xbb\xbf  <svg xmlns="http://www.w3.org/2000/svg"><rect/></svg>')]
    for name, data in good:
        st, _, b = _upload_asset(hosted, h, "f-p58", name, data)
        assert st == 200, (name, st, b)


def test_p58_02_svg_assets_never_run_in_the_app_origin(hosted):
    """Festgenagelt (P58-F1, SVG): jede SVG-Variante (Skript, Ereignis, foreignObject mit HTML, externe Referenz,
    javascript:-Link) kommt als image/svg+xml mit nosniff und `sandbox; default-src 'none'` - keine Skripte, keine
    fremden Ladequellen, auch bei direktem Aufruf. Im Editor laedt das Bild nur ueber <img>/Konva (dort laufen nie
    Skripte). Assets liegen je Konto: ein anderes Konto bekommt die Adresse nie ausgeliefert (P58-10)."""
    u, h = user(hosted, "svg-a@beispiel.de", plan="pro_ai")
    _file_for(u)
    variants = [b'<svg xmlns="http://www.w3.org/2000/svg"><script>fetch("/api/account/me")</script></svg>',
                b'<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"/>',
                b'<svg xmlns="http://www.w3.org/2000/svg"><foreignObject><body xmlns="http://www.w3.org/1999/xhtml">'
                b'<iframe src="javascript:alert(1)"/></body></foreignObject></svg>',
                b'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">'
                b'<image xlink:href="https://evil.example/x.png"/><a xlink:href="javascript:alert(1)"><text>x</text></a></svg>']
    for data in variants:
        st, _, b = _upload_asset(hosted, h, "f-p58", "x.svg", data)
        assert st == 200, b
        url = json.loads(b)["url"]
        st, hd, body = asgi_call(hosted, "GET", url, headers=h)
        assert st == 200 and body == data
        assert _h(hd, "content-type").startswith("image/svg+xml")
        assert _h(hd, "x-content-type-options") == "nosniff"
        csp = _h(hd, "content-security-policy")
        assert csp.startswith("sandbox;") and "default-src 'none'" in csp and "script-src" not in csp, csp


def test_p58_03_file_routes_never_serve_an_executable_type(app):
    """Festgenagelt (Polyglott/MIME): Dateien unter /api/files/…/content, /api/assets/ usw. tragen nosniff; HTML, SVG,
    JS aus Hochschulordnern werden als application/octet-stream + attachment geliefert, nie als Skript- oder
    HTML-Typ. Mit `script-src 'self'` der Oberflaeche kann eine hochgeladene Datei so nie als <script> laufen."""
    from app import config, db
    cases = {"a.js": b"alert(1)", "a.html": b"<script>alert(1)</script>", "a.svg": b"<svg onload=alert(1)/>",
             "a.xhtml": b"<html/>", "a.mjs": b"export{}"}
    with db.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, created_at) VALUES ('c1', 'Testkurs', 'uebung', '2026-10-24')")
        for i, (name, data) in enumerate(cases.items()):
            p = Path(config.DATA_DIR) / f"p58-03-{i}-{name}"
            p.write_bytes(data)
            conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status, local_path) VALUES (?,?,?,?,'neu',?)",
                         (f"f-p5803-{i}", "c1", name, "pdf", str(p)))
    for i in range(len(cases)):
        st, hd, _ = asgi_call(app, "GET", f"/api/files/f-p5803-{i}/content")
        assert st == 200
        assert _h(hd, "content-type") == "application/octet-stream", _h(hd, "content-type")
        assert _h(hd, "content-disposition").startswith("attachment")
        assert _h(hd, "x-content-type-options") == "nosniff" and _h(hd, "content-security-policy").startswith("sandbox")


def test_p58_05_every_write_route_refuses_a_foreign_origin(hosted):
    """CSRF-Matrix ueber ALLE schreibenden Routen (Erweiterung von P25-02, dort 6 Pfade): mit Sitzungs-Cookie und
    fremder, `null`- oder Same-Site-Subdomain-Herkunft antwortet jede POST/PUT/PATCH/DELETE-Route 403, bevor Anmeldung,
    Koerper oder Handler etwas tun. Ohne Origin (native App) und mit eigener Herkunft entscheidet die Route selbst.
    Das Cookie ist HttpOnly und SameSite=Lax (P25-05), Browser senden bei Cross-Site-POST immer Origin."""
    from app import server
    st, hd, b = asgi_call(hosted, "POST", "/api/account/register",
                          body=json.dumps({"email": "csrf@beispiel.de", "password": "sehr-geheim-123", "university": "luh"}))
    assert st == 201
    cookie = _h(hd, "set-cookie")
    assert "HttpOnly" in cookie and "SameSite=lax" in cookie.replace("Lax", "lax"), cookie
    jar = cookie.split(";", 1)[0]
    routes = []
    for r in server.app.routes:
        for m in sorted(getattr(r, "methods", None) or ()):
            if m in ("POST", "PUT", "PATCH", "DELETE"):
                routes.append((m, re.sub(r"\{[^}]+\}", "x1", r.path)))
    assert len(routes) >= 90, len(routes)
    for m, p in routes:
        for origin in (EVIL, "null", "https://evil.test", "http://test.evil.example"):
            st, _, b = asgi_call(hosted, m, p, body="{}", cookies=jar, headers={"Origin": origin})
            assert st == 403 and b"fremder Seite" in b, (m, p, origin, st, b[:120])
    # eigene Herkunft: der Guard laesst durch (Logout als Beispiel, der Rest entscheidet die Route)
    assert asgi_call(hosted, "POST", "/api/account/logout", cookies=jar, headers={"Origin": "http://test"})[0] == 200


def test_p58_08_dynamic_sql_columns_come_from_allowlists():
    """Festgenagelt (P58-F5): jede Stelle in server.py, die einen Spaltennamen in SQL einsetzt (`SET {k}=?`), filtert
    die Schluessel des Rumpfs vorher gegen eine feste Menge (`allowed = {...}` oder ein festes Tupel). Werte sind immer
    Parameter. Eine neue Stelle ohne Allowlist laesst den Test fallen."""
    src = (ROOT / "app" / "server.py").read_text(encoding="utf-8").split("\n")
    sites = [i for i, line in enumerate(src) if re.search(r'f"UPDATE \w+ SET \{k\}=\?', line)]
    assert len(sites) >= 7, sites
    for i in sites:
        start = max(j for j in range(i + 1) if src[j].startswith("def ") or src[j].startswith("async def "))
        fn = "\n".join(src[start:i + 1])
        assert re.search(r"allowed = \{|for k in \(\"", fn), f"server.py:{i + 1} ohne Allowlist:\n{fn}"
    # sync.push setzt Spaltennamen nur aus PRAGMA table_info (Allowlist der Tabelle)
    sync = (ROOT / "app" / "sync.py").read_text(encoding="utf-8")
    assert "if k in cols and k != pk" in sync and 'pk, cols = ENTITIES[table]["pk"], _columns(conn, table)' in sync


def test_p58_08_injection_shaped_keys_change_nothing(hosted):
    """SQL-Injection ueber Schluesselnamen und Werte: PATCH eines Planeintrags mit Spaltennamen wie `title=?, id` oder
    `x; DROP TABLE files` - keine 500, nichts geaendert ausser erlaubten Feldern, Tabellen unveraendert."""
    from app import config, db
    u, h = user(hosted, "sqli@beispiel.de", plan="pro_ai")
    st, item = _j(asgi_call(hosted, "POST", "/api/plan/items", body="{}", headers=h))
    assert st == 200, item
    tok = _in_user(u)
    try:
        with db.cursor() as conn:
            before = sorted(r[0] for r in conn.execute("SELECT name FROM sqlite_master"))
    finally:
        config.reset_user_context(tok)
    evil = {"title=?, id": 1, "x; DROP TABLE files--": "y", "title": "'); DROP TABLE plan_items;--", "id": 999}
    st, out = _j(asgi_call(hosted, "PATCH", f"/api/plan/items/{item['id']}", body=json.dumps(evil), headers=h))
    assert st in (200, 400), (st, out)
    tok = _in_user(u)
    try:
        with db.cursor() as conn:
            after = sorted(r[0] for r in conn.execute("SELECT name FROM sqlite_master"))
            row = db.row(conn, "SELECT id, title FROM plan_items WHERE id=?", (item["id"],))
    finally:
        config.reset_user_context(tok)
    assert after == before and row is not None and row["id"] == item["id"]
    assert row["title"] in ("'); DROP TABLE plan_items;--", "Lernen")


async def _stream(app, path: str, chunks: list[bytes]):
    """POST ohne Content-Length (chunked wie bei uvicorn): der Koerper kommt stueckweise."""
    hdrs = [(b"host", b"test"), (b"content-type", b"application/json")]
    scope = {"type": "http", "asgi": {"version": "3.0", "spec_version": "2.4"}, "http_version": "1.1", "method": "POST",
             "scheme": "http", "path": path, "raw_path": path.encode(), "query_string": b"", "headers": hdrs,
             "client": ("127.0.0.1", 5000), "server": ("test", 80)}
    q = list(chunks)
    read = {"n": 0}
    out = {"status": None, "body": b""}

    async def receive():
        if q:
            c = q.pop(0)
            read["n"] += 1
            return {"type": "http.request", "body": c, "more_body": bool(q)}
        return {"type": "http.disconnect"}

    async def send(m):
        if m["type"] == "http.response.start":
            out["status"] = m["status"]
        elif m["type"] == "http.response.body":
            out["body"] += m.get("body", b"")
    await app(scope, receive, send)
    return out["status"], out["body"], read["n"]


PUBLIC_POSTS = ["/api/account/register", "/api/account/login", "/api/account/login/apple", "/api/account/login/google",
                "/api/account/password/reset-request", "/api/account/password/reset", "/api/account/verify-email",
                "/api/app-login/token"]


def test_p58_09_public_json_bodies_are_capped_before_they_are_read(hosted):
    """Neu bestaetigt (P58-F6, oeffentliche Endpunkte): ohne Anmeldung nahm jede oeffentliche Route (Registrieren,
    Anmelden, Reset, Social Login, App-Login, Abo-Benachrichtigungen) einen JSON-Koerper bis zur Caddy-Grenze von
    320 MB an - Starlette liest ihn ganz in den Speicher und parst ihn. Zwoelf solche Anfragen genuegten fuer einen
    Speicherengpass des einen Servers. Jetzt 64 KB (Konto/App-Login) bzw. 1 MB (Apple/Stripe) schon in der
    ASGI-Schicht, mit und ohne Content-Length; normale Anfragen unveraendert."""
    big = json.dumps({"email": "a@b.de", "password": "x" * (70 << 10)})
    for p in PUBLIC_POSTS:
        st, _, b = asgi_call(hosted, "POST", p, body=big)
        assert (st, json.loads(b).get("code")) == (413, "too_large"), (p, st, b[:200])
    for p in ("/api/billing/apple/notifications", "/api/billing/stripe/webhook"):
        st, _, b = asgi_call(hosted, "POST", p, body=json.dumps({"signedPayload": "x" * (1100 << 10)}))
        assert (st, json.loads(b).get("code")) == (413, "too_large"), (p, st, b[:200])
    # ohne Content-Length: Abbruch nach dem ersten Stueck ueber der Grenze, nicht erst nach 320 MB
    st, b, n = asyncio.run(_stream(hosted, "/api/account/login", [b"{" + b" " * (40 << 10)] * 50))
    assert st == 413 and n <= 3, (st, n, b[:100])
    # normal: Anmelden und Registrieren wie bisher
    st, _, _ = asgi_call(hosted, "POST", "/api/account/register",
                         body=json.dumps({"email": "pub@beispiel.de", "password": "sehr-geheim-123", "university": "luh"}))
    assert st == 201
    assert asgi_call(hosted, "POST", "/api/account/login", body=json.dumps({"email": "pub@beispiel.de", "password": "sehr-geheim-123"}))[0] == 200
    # Apple-Benachrichtigung in realistischer Groesse (~20 KB) kommt bis zur Pruefung durch (400 ohne gueltige Signatur)
    st, _, b = asgi_call(hosted, "POST", "/api/billing/apple/notifications", body=json.dumps({"signedPayload": "x" * 20000}))
    assert st != 413, (st, b[:100])


def test_p58_09_unknown_key_ids_cannot_force_a_download_per_request(monkeypatch):
    """Neu bestaetigt (oeffentlicher Social Login): ein Token mit unbekannter `kid` erzwang bei JEDER Anfrage einen
    frischen JWKS-Abruf bei Apple/Google - ohne Anmeldung, ohne Grenze, unter der prozessweiten Sperre `_jwks_lock`
    (bis 10 s Zeitlimit je Abruf). Wer erfundene Tokens schickt, liess den Dienst Apple/Google im Takt seiner Anfragen
    anfragen und blockierte echte Anmeldungen. Jetzt hoechstens ein erzwungener Abruf je Anbieter und Minute;
    Schluesselrotation funktioniert weiter (test_social_login.py: einmal frisch laden)."""
    from app import social_login
    from test_social_login import GOOGLE_ID, Keys, google_claims
    k = Keys()

    def fetch(url):
        k.fetches += 1
        return k.jwks
    monkeypatch.setattr(social_login, "fetch_jwks", fetch)
    monkeypatch.setenv(social_login.PROVIDERS["google"]["env"], GOOGLE_ID)
    social_login.clear_cache()
    assert social_login.verify("google", k.token(google_claims()))["subject"] == "g-1"
    assert k.fetches == 1
    for i in range(40):
        with pytest.raises(social_login.TokenError, match="nicht bekannt"):
            social_login.verify("google", k.token(google_claims(), kid=f"erfunden-{i}"))
    assert k.fetches <= 2, f"{k.fetches} Abrufe fuer 40 erfundene Schluessel-IDs"
    # gueltige Tokens laufen dabei weiter aus dem Zwischenspeicher
    assert social_login.verify("google", k.token(google_claims(sub="g-2")))["subject"] == "g-2"
    # nach der Minute darf eine neue kid (Rotation) wieder einen frischen Abruf ausloesen
    social_login._jwks_forced.clear()
    with pytest.raises(social_login.TokenError):
        social_login.verify("google", k.token(google_claims(), kid="neu-rotiert"))
    assert k.fetches <= 3


def test_p58_10_assets_of_another_account_are_404(hosted):
    """IDOR auf Assets: A laedt ein Bild hoch; B ruft dieselbe Adresse auf -> 404 (Ordner je Konto), ohne Sitzung 401,
    erfundene und manipulierte Namen 400/404. Gilt auch fuer Aufnahmen (gleicher Ordner)."""
    ua, ha = user(hosted, "idor-a@beispiel.de", plan="pro_ai")
    _, hb = user(hosted, "idor-b@beispiel.de", plan="pro_ai")
    _file_for(ua)
    st, _, b = _upload_asset(hosted, ha, "f-p58", "a.png", PNG)
    assert st == 200, b
    url = json.loads(b)["url"]
    assert asgi_call(hosted, "GET", url, headers=ha)[0] == 200
    assert asgi_call(hosted, "GET", url, headers=hb)[0] == 404
    assert asgi_call(hosted, "GET", url)[0] == 401
    fid, name = url.rsplit("/", 2)[-2:]
    for bad in (f"/api/assets/{fid}/..%2F..%2Faccounts.db", f"/api/assets/{fid}/{name}%0A", f"/api/assets/..%2F{fid}/{name}",
                f"/api/assets/{fid}/{uuid.uuid4().hex}.png"):
        assert asgi_call(hosted, "GET", bad, headers=hb)[0] in (400, 404), bad


# ================================================================ Pakete 66 und 74 (Server)

def _member(user_id, key):
    from app import community
    with community.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO community_members(user_id, community_key, university, kind, joined_at) VALUES (?,?,?,?,?)",
                     (user_id, key, "luh", "course", "2026-11-09T00:00:00Z"))


def test_p66_09_control_and_direction_characters_are_removed(hosted):
    """Neu bestaetigt (P66-F8/P66-09): Fragen, Antworten, Kommentare, Titel, Lerngruppen- und Stapelnamen nahmen
    Steuerzeichen (NUL, ESC, C1) und Unicode-Richtungszeichen (U+202E "RIGHT-TO-LEFT OVERRIDE", Isolates) an. Andere
    Mitglieder sahen damit verdrehte Texte (z. B. "Lösung.pdf" als "fdp.gnusöL"-Spoofing) oder unsichtbare Zeichen.
    HTML/Skript ist kein Thema des Dienstes (JSON, die Oberflaechen escapen, CSP `script-src 'self'`) und bleibt
    unveraendert gespeichert. Jetzt entfernt `community.plain_text` diese Zeichen; Zeilenumbruch und Tab bleiben."""
    from app import community, community_cards
    key = hashlib.sha256(b"uniflow.community.course.v1\x00luh\x00p66-09").hexdigest()
    ua, ha = user(hosted, "ctl-a@beispiel.de", plan="plus")
    _member(ua["id"], key)
    raw = "Aufgabe‮ fdp.1⁦x⁩\x00\x1b[31m\x85 <b>fett</b>\r\nZeile 2\tTab"
    clean = "Aufgabe fdp.1x[31m <b>fett</b>\nZeile 2\tTab"
    assert community.plain_text(raw) == clean
    st, q = _j(asgi_call(hosted, "POST", f"/api/community/courses/{key}/questions", headers=ha,
                         body=json.dumps({"title": raw[:60], "body": raw})))
    assert st == 201, q
    assert q["title"] == community.plain_text(raw[:60]).strip() and q["body"] == clean, q
    st, a = _j(asgi_call(hosted, "POST", f"/api/community/questions/{q['id']}/answers", headers=ha, body=json.dumps({"body": raw})))
    assert st == 201 and a["body"] == clean, a
    gkey = hashlib.sha256(b"gruppe-p66-09").hexdigest()
    st, g = _j(asgi_call(hosted, "POST", "/api/community/groups", headers=ha, body=json.dumps({"group_key": gkey, "name": "Mathe‮AG\x07"})))
    assert st == 201, g
    with community.cursor() as conn:
        assert conn.execute("SELECT name FROM study_groups WHERE group_key=?", (gkey,)).fetchone()[0] == "MatheAG"
    me = _j(asgi_call(hosted, "GET", "/api/account/me", headers=ha))[1]["user"]
    out = community_cards.share(me, "luh", key, "Stapel‮1", "eigene", None,
                                [{"question": "Was​ ist\x00 1+1?", "answer": "2‮"}])
    with community.cursor() as conn:
        r = conn.execute("SELECT name, cards FROM card_stacks WHERE id=?", (out["id"],)).fetchone()
    assert r["name"] == "Stapel1" and json.loads(r["cards"]) == [{"question": "Was​ ist 1+1?", "answer": "2"}], dict(r)
    # nur Steuerzeichen -> leer -> abgelehnt wie ein leerer Text
    st, d = _j(asgi_call(hosted, "POST", f"/api/community/questions/{q['id']}/answers", headers=ha, body=json.dumps({"body": "‮\x00"})))
    assert st == 400 and d["code"] == "text_empty", (st, d)


def test_p66_f3_privacy_policy_names_plaintext_card_stacks_and_kept_copies():
    """Bestaetigt (Text, P66-F3/F6, P74-F4, P81-F8): Abschnitt 8 der Datenschutzerklaerung (Community im Dienst) nannte
    geteilte Karteikarten-Stapel gar nicht - sie liegen im Dienst im Klartext hinter der Mitgliedschaft
    (community_cards.py), und wer einen Stapel uebernommen hat, behaelt seine Kopie nach Zurueckziehen oder Aendern.
    Ebenso fehlte, dass geladene Loesungen beim Ladenden bleiben. Pauschale Ende-zu-Ende-Zusagen gibt es keine."""
    from app import community_cards
    assert "im Klartext" in (community_cards.__doc__ or "")
    md = (ROOT / "docs" / "release" / "DATENSCHUTZ.md").read_text(encoding="utf-8")
    sec8 = md.split("## 8. Community", 1)[1].split("## 8a.", 1)[0]
    assert "Karteikarten-Stapel" in sec8 and "Klartext" in sec8, "Stapel im Dienst: Klartext nennen"
    assert re.search(r"übernommen[^.]*behält[^.]*Kopie", sec8), "Kopien nach Zurueckziehen nennen"
    assert re.search(r"geladen[^.]*behält", sec8), "geladene Loesungen bleiben beim Ladenden"
    assert "Ende-zu-Ende" not in md
    html = (ROOT / "site" / "datenschutz.html").read_text(encoding="utf-8")
    assert "Karteikarten-Stapel" in html and "Klartext" in html, "site/ mit tools/gen-site.py neu erzeugen"


# ================================================================ Paket 80

def test_p80_05_06_ai_code_never_logs_prompts_and_the_usage_log_holds_no_text():
    """Festgenagelt (P80-F3/F4): die KI-Module schreiben nichts in Protokolle (kein print/logging) - weder Prompt noch
    Antwort, Seitentext oder Schluessel; das Nutzungsprotokoll `ai_usage_log` hat nur Zahlen und Kennzeichen (Zweck,
    Anbieter, Modell, Tokens, Kosten), keine Textspalte. Antworten im Abrechnungsbuch leert retention nach 24 h (P57-10),
    den Zwischenspeicher nach 30 Tagen. Zugriffsprotokoll ohne Query und ohne Koerper (Paket 3-4 Nr. 86, P57-10)."""
    for name in ("ai_relay", "ai_backend", "ai_providers", "ai_router", "ai_async"):
        src = (ROOT / "app" / f"{name}.py").read_text(encoding="utf-8")
        assert not re.search(r"^\s*(print\(|logging\.|log\.(info|warning|error|exception|debug)\(|logger\.)", src, re.M), name
    m = re.search(r"CREATE TABLE IF NOT EXISTS ai_usage_log \((.*?)\n\);", (ROOT / "app" / "ai_backend.py").read_text(encoding="utf-8"), re.S)
    cols = [line.strip().split()[0] for line in m.group(1).split("\n") if line.strip() and not line.strip().startswith("--")]
    assert not {c for c in cols if re.search(r"prompt|text|content|answer|result|system|question", c)}, cols


# ================================================================ Paket 81

def test_p81_01_ipad_deletion_names_the_service_account_and_the_card_deletes_it(hosted):
    """P81-F1 (Produktentscheidung 08.11.2026, P35-01): "Konto löschen" auf dem iPad loescht Geraetedaten und die
    Anmeldung; mit angemeldetem StudiNow-Konto zeigt die Rueckfrage, dass das Dienst-Konto bleibt und wo es geloescht
    wird. Die Karte "StudiNow-Konto" ruft POST /api/account/delete (sofort gesperrt, 30 Tage). Hier ohne Xcode
    festgenagelt: Texte und Aufruf im Swift-Quelltext, dazu der Server-Weg mit Bearer-Token (wie das iPad)."""
    settings = (ROOT / "apps/apple/UniFlow/Views/Settings/SettingsPage.swift").read_text(encoding="utf-8")
    # seit 12.11.2026 (eine Apple-Anmeldung fuer alles, Entscheidung des Inhabers): "Konto löschen" loescht auch das
    # Dienst-Konto (vorher P35-01: es blieb bestehen und liess sich nur in der Karte loeschen)
    assert "Dein StudiNow-Konto beim StudiNow-Dienst wird ebenfalls gelöscht" in settings
    assert "shows(serviceSignedIn: containers.account.user != nil)" in settings
    # der eigene Loesch-Knopf der Karte ist seit 12.11.2026 weg; die Rueckfrage in den Einstellungen nennt die Frist
    assert "sofort gesperrt, nach 30 Tagen endgültig" in settings
    link = (ROOT / "apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/Account/StudoraAccount.swift").read_text(encoding="utf-8")
    assert '"POST", "/api/account/delete"' in link
    u, h = user(hosted, "ipad-del@beispiel.de")
    st, d = _j(asgi_call(hosted, "POST", "/api/account/delete", headers=h, body=json.dumps({"password": "sehr-geheim-123"})))
    assert st == 200 and d.get("purge_after_days") == 30, d
    assert asgi_call(hosted, "GET", "/api/account/me", headers=h)[0] == 401


def test_p81_11_service_check_alarms_when_the_deletion_run_is_overdue(tmp_path):
    """Neu bestaetigt (P81-F4/P81-11): der taegliche Loeschlauf (retention.run: Endloeschung nach 30 Tagen, Fristen
    der Protokolle) schreibt nach Erfolg eine Zeile in /logs/retention.log; scheiterte er immer wieder, wiederholte
    `schedule_due` ihn stuendlich, aber niemand erfuhr davon - deploy/dienst-check.sh pruefte das nicht. Jetzt Kennung
    `loeschlauf`: retention.log aelter als DIENST_CHECK_RETENTION_H (30 h) -> Befund und Mail. Fehlt die Datei (neuer
    Server vor dem ersten Lauf), kein Befund."""
    import shutil
    if shutil.which("bash") is None:
        pytest.skip("bash fehlt")
    from test_dienst_check import Umgebung
    u = Umgebung(tmp_path)
    u.gesund()
    out = u.lauf("--no-mail", "--verbose", erwartet=0)
    assert "loeschlauf" in out, out
    log = u.logs / "retention.log"
    log.write_text('{"purged_accounts": 0}\n')
    u.lauf("--no-mail", erwartet=0)
    alt = time.time() - 31 * 3600
    os.utime(log, (alt, alt))
    out = u.lauf("--no-mail", erwartet=1)
    assert "PROBLEM loeschlauf" in u.protokoll() and "retention" in u.protokoll(), u.protokoll()
    os.utime(log, None)
    u.lauf("--no-mail", erwartet=0)
    assert "ERHOLT loeschlauf" in u.protokoll()
