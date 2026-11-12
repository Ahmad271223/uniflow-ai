"""Audit-Pakete 28 und 29 (08.11.2026, docs/audit/AUDIT-2026-11-08-PAKET-28-29.md): Upload-Grenzen, Speicher,
Hintergrundlauf, Pfadpruefung (P28) und Sync/Dateien/Notizen/Assets (P29). Dienst zuerst, PC wo es ihn betrifft.

Jeder Test traegt die Befundnummer. "Festgenagelt" heisst: Verhalten war schon richtig und bleibt es."""
import asyncio
import errno
import json
import re
import threading
import time
from pathlib import Path

import pytest
from conftest import asgi_call
from test_community import _user, hosted  # noqa: F401
from test_security import _add_file, _multipart

ROOT = Path(__file__).resolve().parents[1]


def _j(res):
    st, _h, body = res
    try:
        return st, json.loads(body) if body else None
    except ValueError:
        return st, body


def _call(app, method, path, **kw):
    """Wie asgi_call, eine Ausnahme der App (500 im Betrieb) wird zu Status 500."""
    try:
        return asgi_call(app, method, path, **kw)
    except Exception as e:  # noqa: BLE001
        return 500, [], repr(e).encode()


def _stream(app, method, path, chunks, headers=None, content_length=None, ctype="application/json"):
    """ASGI-Aufruf mit Koerper in Stuecken (chunked, ohne oder mit falscher Content-Length).
    Liefert (Status, Anzahl gelesener Stuecke)."""
    hdrs = [(b"host", b"test"), (b"content-type", ctype.encode())]
    if content_length is not None:
        hdrs.append((b"content-length", str(content_length).encode()))
    for k, v in (headers or {}).items():
        hdrs.append((k.lower().encode(), v.encode()))
    scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1", "method": method, "scheme": "http",
             "path": path, "raw_path": path.encode(), "query_string": b"", "headers": hdrs,
             "client": ("127.0.0.1", 5000), "server": ("test", 80)}
    pulled = {"n": 0}
    out = {"status": None}

    async def receive():
        if pulled["n"] < len(chunks):
            pulled["n"] += 1
            return {"type": "http.request", "body": chunks[pulled["n"] - 1], "more_body": pulled["n"] < len(chunks)}
        return {"type": "http.disconnect"}

    async def send(m):
        if m["type"] == "http.response.start":
            out["status"] = m["status"]
    asyncio.run(app(scope, receive, send))
    return out["status"], pulled["n"]


def _pieces(data: bytes, size=8 << 10):
    return [data[i:i + size] for i in range(0, len(data), size)] or [b""]


@pytest.fixture
def ctx_user(hosted):  # noqa: F811
    """Konto im Dienst plus gesetzter Kontext (wie in der Middleware) fuer direkte Aufrufe."""
    from app import config, db
    u, h = _user(hosted, "ctx@beispiel.de")
    tok = config.set_user_context(u["id"], u.get("university") or "luh")
    db.init_db()
    yield u, h
    config.reset_user_context(tok)


# ================================================================ PAKET 28

# ---------------------------------------------------------------- P28-01 Streaming-Grenze

@pytest.fixture
def tiny_limits(monkeypatch):
    from app import server
    monkeypatch.setattr(server, "_MULTIPART_SLACK", 0)
    monkeypatch.setattr(server, "_UPLOAD_LIMITS", tuple((rx, 16 << 10) for rx, _ in server._UPLOAD_LIMITS))
    monkeypatch.setattr(server, "_PUT_LIMITS", tuple((rx, 16 << 10) for rx, _ in server._PUT_LIMITS))
    return 16 << 10


def test_p28_01_chunked_and_lying_content_length_get_413_on_every_capped_post(hosted, tiny_limits):  # noqa: F811
    """Dienst: ohne Content-Length (chunked), mit zu kleiner, kaputter oder negativer Angabe - immer 413, bevor alles
    gelesen ist. Keiner der Endpunkte startet seine Antwort vor dem Lesen des Koerpers, daher nie ein halber 200."""
    from app import config, db
    u, h = _user(hosted, "strom@beispiel.de")
    tok = config.set_user_context(u["id"], "luh")
    try:
        db.init_db()
        _add_file("f-strom")
    finally:
        config.reset_user_context(tok)
    big = b"\0" * (64 << 10)
    cases = [("/api/files/f-strom/assets", *_multipart("upload", "a.png", big)),
             ("/api/files/f-strom/recordings", *_multipart("upload", "a.mp3", big)),
             ("/api/notebooks", *_multipart("upload", "a.pdf", b"%PDF" + big, {"kind": "pdf", "title": "x"})),
             ("/api/sync/push", json.dumps({"items": [{"entity": "flashcards", "local_id": "x", "front": "A" * (64 << 10)}]}).encode(),
              "application/json")]
    for path, body, ctype in cases:
        chunks = _pieces(body)
        for cl in (None, 100, "abc", "-1", ""):
            st, n = _stream(hosted, "POST", path, chunks, headers=h, content_length=cl, ctype=ctype)
            assert st == 413, (path, cl, st)
            if cl is None or cl == 100:
                assert n < len(chunks), (path, cl, "Abbruch vor dem vollstaendigen Empfang")


def test_p28_01_put_bodies_for_annotations_and_pagetext_are_capped(hosted, tiny_limits):  # noqa: F811
    """P28-01/P29-04 bestaetigt: PUT /api/files/{id}/annotations und /pagetext lasen den ganzen JSON-Koerper (bis zur
    Caddy-Grenze 320 MB) in der Ereignisschleife, UploadLimit galt nur fuer POST. Jetzt dieselbe 32-MB-Grenze wie sync/push."""
    from app import server
    assert dict((rx.pattern, n) for rx, n in server._PUT_LIMITS)  # Tabelle vorhanden
    _, h = _user(hosted, "put@beispiel.de")
    for path, body in (("/api/files/f1/annotations", json.dumps({"pages": {"x": "A" * (64 << 10)}}).encode()),
                       ("/api/files/f1/pagetext", json.dumps({"pages": ["A" * 15000] * 5}).encode())):
        st, n = _stream(hosted, "PUT", path, _pieces(body), headers=h)
        assert st == 413, (path, st)
        st, _ = _stream(hosted, "PUT", path, [body], headers=h, content_length=len(body))
        assert st == 413, (path, st)


def test_p28_01_put_limits_use_the_sync_cap_by_default():
    from app import server
    pats = {rx.pattern: n for rx, n in server._PUT_LIMITS}
    # 12.11.2026 geprueft: Abgleich eigener Dokumente mit eigenen Grenzen (Beschreibung 1 MB, Inhalt roh 75 MB wie
    # own_docs.MAX_SYNC_BYTES, Bild roh 15 MB wie die Assets im Editor); der Inhalt wird gestreamt, nie ganz gelesen
    own = {p: n for p, n in pats.items() if p.startswith("^/api/sync/")}
    assert sorted(own.values()) == sorted([1 << 20, server.MAX_OWN_DOC_SYNC_BYTES, server.MAX_ASSET_BYTES]), own
    from app import own_docs
    assert server.MAX_OWN_DOC_SYNC_BYTES == own_docs.MAX_SYNC_BYTES
    assert all(n == server.MAX_SYNC_BYTES for p, n in pats.items() if p not in own)
    assert any(re.match(p, "/api/files/abc/annotations") for p in pats)
    assert any(re.match(p, "/api/files/abc/pagetext") for p in pats)
    assert not any(re.match(p, "/api/files/abc/fingerprint") for p in pats)


def test_p28_01_index_upload_is_capped_before_starlette_spools_it():
    """POST /api/index/file (KI-Index, Dienst): Starlette schrieb den ganzen Upload (bis 320 MB) in eine Temp-Datei,
    bevor doc_index nach 60 MB abbricht. Jetzt steht der Pfad in der Tabelle von UploadLimit."""
    from app import doc_index, server
    hit = [n for rx, n in server._UPLOAD_LIMITS if rx.match("/api/index/file")]
    assert hit == [doc_index.MAX_UPLOAD_BYTES]


def test_p28_01_response_started_before_overflow_is_dropped_not_413():
    """Festgenagelt (Design): hat eine App ihre Antwort schon begonnen, als der Koerper die Grenze ueberschreitet,
    kann es kein 413 mehr geben. Die Schicht verwirft den Rest der Antwort; uvicorn schliesst die Verbindung
    ("ASGI callable returned without completing response"). Keiner der begrenzten Endpunkte antwortet vor dem Lesen."""
    from app import server

    async def early(scope, receive, send):
        await send({"type": "http.response.start", "status": 200, "headers": []})
        while (await receive())["type"] != "http.disconnect":
            pass
        await send({"type": "http.response.body", "body": b"fertig", "more_body": False})

    limited = server.UploadLimit(early)
    sent = []

    async def run():
        chunks = [b"x" * (1 << 20)] * 40
        it = iter(chunks)

        async def receive():
            c = next(it, None)
            return {"type": "http.request", "body": c, "more_body": True} if c else {"type": "http.disconnect"}

        async def send(m):
            sent.append(m)
        await limited({"type": "http", "method": "POST", "path": "/api/files/x/assets", "headers": []}, receive, send)
    asyncio.run(run())
    assert [m["type"] for m in sent] == ["http.response.start"], "kein Body nach der Grenze, kein zweites start"


# ---------------------------------------------------------------- P28-02 Ueberschreiben bestehender Dateien

def test_p28_02_every_caller_writes_a_fresh_file(app, monkeypatch):
    """Widerlegt: alle Aufrufer von _save_upload erzeugen einen neuen Namen (uuid), ueberschreiben also nie eine
    vorhandene Datei. Ein Fehler beim Upload entfernt nur die eigene, neue Datei. PC und Dienst gleich."""
    from app import server
    seen = []
    real = server._save_upload

    async def spy(upload, target, limit, head=None):
        seen.append((target, target.exists()))
        return await real(upload, target, limit, head)
    monkeypatch.setattr(server, "_save_upload", spy)
    _add_file("f-neu")
    for path, fname, extra, data in (("/api/files/f-neu/assets", "a.png", None, b"\x89PNG" + b"\0" * 100),
                                     ("/api/files/f-neu/recordings", "a.mp3", None, b"ID3" + b"\0" * 100),
                                     ("/api/notebooks", "a.pdf", {"kind": "pdf", "title": "x"}, b"%PDF-1.4\n" + b"\0" * 100),
                                     ("/api/notebooks", "a.png", {"kind": "image", "title": "x"}, b"kein bild")):
        for _ in range(2):
            body, ctype = _multipart("upload", fname, data, extra)
            st, _, b = asgi_call(app, "POST", path, body=body, content_type=ctype)
            assert st == 200, (path, b[:200])
    assert len(seen) == 8 and len({t for t, _ in seen}) == 8
    assert not any(existed for _, existed in seen), "nie ein vorhandenes Ziel"
    text = (ROOT / "app" / "server.py").read_text(encoding="utf-8")
    # 12.11.2026 geprueft: zwei neue Aufrufer im Abgleich eigener Dokumente schreiben in "<ziel>.<uuid4>.part" und
    # ersetzen erst danach (os.replace); ihr Lauf mit dem Spion steht in tests/test_own_docs_sync.py
    assert text.count("await _save_upload(") == 6, "neuer Aufrufer? dann P28-02 neu pruefen"
    assert text.count('{uuid.uuid4().hex}.part"') == 2


# ---------------------------------------------------------------- P28-03 Parallele Uploads gegen das Kontingent

class _SlowUpload:
    """UploadFile-Ersatz: liefert Stuecke und gibt dazwischen die Ereignisschleife frei (parallele Uploads)."""

    def __init__(self, total, piece=256 << 10):
        self.size, self._left, self._piece = None, total, piece

    async def read(self, n):
        await asyncio.sleep(0)
        k = min(self._left, self._piece, n)
        self._left -= k
        return b"\0" * k


def test_p28_03_parallel_uploads_cannot_overshoot_the_account_quota(ctx_user, monkeypatch):
    """Bestaetigt: das Kontingent wurde nur einmal vor dem Schreiben per Scan bestimmt; zwei gleichzeitige Uploads
    sahen denselben Rest und lagen zusammen ueber der Grenze. Jetzt prueft _save_upload waehrend des Schreibens
    erneut gegen die Platte (auch Teil-Dateien anderer Uploads und anderer Prozesse liegen dort) und am Ende."""
    from app import config, server
    monkeypatch.setenv("LERNAPP_UPLOAD_QUOTA_MB", "3")
    monkeypatch.setattr(server, "_QUOTA_RECHECK_BYTES", 1 << 20)
    d = server._assets_dir() / "f-q"
    d.mkdir(parents=True, exist_ok=True)

    async def both():
        async def one(name):
            try:
                await server._save_upload(_SlowUpload(2 << 20), d / name, 50 << 20)
                return "ok"
            except server.HTTPException as e:
                return e.detail["code"]
        return await asyncio.gather(one("a.png"), one("b.png"))
    res = asyncio.run(both())
    assert res.count("ok") <= 1, res
    assert server._own_upload_bytes() <= server._upload_quota_bytes(), "Belegung ueber dem Kontingent"
    assert config.current_user_id()


def test_p28_03_single_upload_within_quota_still_works(ctx_user, monkeypatch):
    from app import server
    monkeypatch.setenv("LERNAPP_UPLOAD_QUOTA_MB", "3")
    monkeypatch.setattr(server, "_QUOTA_RECHECK_BYTES", 1 << 20)
    d = server._assets_dir() / "f-q1"
    d.mkdir(parents=True, exist_ok=True)
    n = asyncio.run(server._save_upload(_SlowUpload(2 << 20), d / "a.png", 50 << 20))
    assert n == 2 << 20 and (d / "a.png").stat().st_size == n


# ---------------------------------------------------------------- P28-04 Platte waehrend des Streamens

def test_p28_04_disk_filling_up_during_the_stream_gives_507_and_cleans_up(ctx_user, monkeypatch):
    """Bestaetigt: die Reserve wurde nur vor dem Upload geprueft. Jetzt auch bei jeder Nachpruefung im Strom."""
    from app import server
    monkeypatch.setenv("LERNAPP_DISK_MIN_FREE_MB", "100")
    monkeypatch.setattr(server, "_QUOTA_RECHECK_BYTES", 1 << 20)
    calls = {"n": 0}

    def free(_p):
        calls["n"] += 1
        return (500 << 20) if calls["n"] == 1 else (50 << 20)      # erst genug, dann voll (anderer Prozess)
    monkeypatch.setattr(server, "disk_free_bytes", free)
    d = server._assets_dir() / "f-disk"
    d.mkdir(parents=True, exist_ok=True)
    with pytest.raises(server.HTTPException) as e:
        asyncio.run(server._save_upload(_SlowUpload(3 << 20), d / "a.png", 50 << 20))
    assert e.value.status_code == 507 and e.value.detail["code"] == "storage_full"
    assert not (d / "a.png").exists()


@pytest.mark.parametrize("hosted_mode", [False, True])
def test_p28_04_enospc_while_writing_is_507_not_500(app, hosted, monkeypatch, hosted_mode):  # noqa: F811
    """Bestaetigt (beides): eine volle Platte beim Schreiben (OSError ENOSPC/EDQUOT) wurde zur 500; jetzt 507
    storage_full, die Teil-Datei ist weg. Auf dem PC gibt es keine Reserve-Pruefung, nur diese Abbildung."""
    from app import config, server
    if not hosted_mode:
        monkeypatch.setattr(config, "MODE", "local")
    real_open = open

    class Full:
        def __init__(self, f):
            self.f = f

        def write(self, b):
            raise OSError(errno.ENOSPC, "No space left on device")

        def __enter__(self):
            return self

        def __exit__(self, *a):
            self.f.close()

    monkeypatch.setattr(server, "open", lambda p, m="r", *a, **k: Full(real_open(p, m, *a, **k)), raising=False)
    target = Path(config.DATA_DIR) / "p28-04-enospc.bin"
    with pytest.raises(server.HTTPException) as e:
        asyncio.run(server._save_upload(_SlowUpload(1 << 20), target, 50 << 20))
    assert e.value.status_code == 507 and e.value.detail["code"] == "storage_full"
    assert not target.exists()


# ---------------------------------------------------------------- P28-05 Scan-Kosten

def test_p28_05_scan_cost_and_symlinks(ctx_user, tmp_path):
    """Festgenagelt: os.walk folgt keinen Ordner-Symlinks (fremde Ordner zaehlen nicht mit), die API legt keine Links
    an. 10.000 kleine Dateien: Scan deutlich unter einer Sekunde (gemessen ~0,05-0,1 s auf dem Mac)."""
    import os
    from app import server
    d = server._assets_dir() / "f-many"
    d.mkdir(parents=True, exist_ok=True)
    for i in range(10_000):
        (d / f"{i}.png").write_bytes(b"x")
    outside = tmp_path / "fremd"
    outside.mkdir()
    (outside / "gross.bin").write_bytes(b"\0" * (1 << 20))
    os.symlink(outside, server._assets_dir() / "link")
    t0 = time.perf_counter()
    total = server._own_upload_bytes()
    dt = time.perf_counter() - t0
    assert 10_000 <= total < (1 << 20), total
    assert dt < 2.0, dt


# ---------------------------------------------------------------- P28-06 Hintergrundlauf

def _bg_idle():
    from app import server
    deadline = time.time() + 5
    while server._bg_state["running"] and time.time() < deadline:
        time.sleep(0.01)
    assert not server._bg_state["running"]


def test_p28_06_thread_start_failure_releases_the_lock(app, monkeypatch):
    """Bestaetigt (PC; im Dienst sind fast alle _run_bg-Endpunkte gesperrt): scheiterte Thread.start (z. B.
    "can't start new thread"), blieb _bg_lock fuer immer belegt - jeder weitere Abgleich 409 bis zum Neustart."""
    from app import server
    _bg_idle()

    def boom(self):
        raise RuntimeError("can't start new thread")
    monkeypatch.setattr(threading.Thread, "start", boom)
    with pytest.raises(RuntimeError):
        server._run_bg("Test", lambda: "x")
    monkeypatch.undo()
    assert not server._bg_state["running"]
    assert server._run_bg("Test2", lambda: "y") == {"started": "Test2"}
    _bg_idle()
    assert server._bg_state["message"] == "Test2: fertig (y)"


def test_p28_06_background_job_keeps_the_account_context(ctx_user):
    """Bestaetigt (Dienst): threading.Thread uebernimmt keine contextvars. Ein _run_bg-Job im Dienst (heute noch
    erreichbar: POST /api/weekly/mock-exam) lief ohne Konto, also auf dem Datenordner des Dienstes statt dem des
    Kontos. Jetzt laeuft der Job in einer Kopie des Kontexts der Anfrage."""
    from app import config, server
    _bg_idle()
    want = config.current_user_id()
    got = {}
    server._run_bg("Kontext", lambda: got.setdefault("uid", config.current_user_id()) and "ok")
    _bg_idle()
    assert got["uid"] == want


# ---------------------------------------------------------------- P28-07 Rueckgabe von run_sync

def test_p28_07_incomplete_sync_result_is_a_message_not_a_crash(app, monkeypatch):
    """Widerlegt als Fehler: alle run_sync-Wege liefern ok/new_files/message; ein unvollstaendiges Ergebnis endet
    im Worker als "FEHLER ..." in _bg_state und gibt die Sperre frei (kein haengender Abgleich)."""
    from app import server
    for mod in ("studip_sync", "hildesheim", "hsh"):
        src = (ROOT / "app" / f"{mod}.py").read_text(encoding="utf-8")
        assert '"ok": ok, "new_files": new_files, "message": message' in src, mod
    _bg_idle()
    for stub, fn in (({"ok": True}, server._full_sync), ({"ok": True}, server._sync_without_ai), ({}, server._full_sync)):
        monkeypatch.setattr(server, "run_sync", lambda s=stub: s)
        monkeypatch.setattr(server, "_after_current", lambda: None)
        monkeypatch.setattr(server.planner, "analyze_pending", lambda *a, **k: 0)
        server._run_bg("Sync", fn)
        _bg_idle()
        assert "FEHLER" in server._bg_state["message"], server._bg_state


# ---------------------------------------------------------------- P28-08 Herkunft

def test_p28_08_foreign_origin_is_refused_for_writes(app):
    """Festgenagelt (beides): fremde Origin und "null" -> 403 bei Aenderungen; ohne Origin (App, Skript) erlaubt;
    GET bleibt frei. Browser senden bei Cross-Origin-POST (fetch und Formular) immer Origin; im Dienst ist das
    Sitzungs-Cookie zusaetzlich SameSite=Lax (app/account_api.py)."""
    for origin, want in (("https://boese.example", 403), ("null", 403), ("http://test", None), (None, None)):
        hdr = {"origin": origin} if origin else {}
        st, _, _ = asgi_call(app, "POST", "/api/files/mark-seen", headers=hdr)
        assert (st == 403) == (want == 403), (origin, st)
    assert asgi_call(app, "GET", "/api/courses", headers={"origin": "https://boese.example"})[0] == 200
    src = (ROOT / "app" / "account_api.py").read_text(encoding="utf-8")
    assert 'samesite="lax"' in src


# ---------------------------------------------------------------- P28-09 Kopfzeilen fuer Dateien

def test_p28_09_file_headers(app, tmp_path):
    """Festgenagelt (Design): PDF mit nosniff, ohne Sandbox (der PDF-Betrachter des Browsers braucht Skripte und laeuft
    ohnehin getrennt vom Ursprung der App); SVG/Bilder als Asset mit Sandbox; HTML wird heruntergeladen."""
    from app import config, db, server
    d = server._assets_dir() / "f-hdr"
    d.mkdir(parents=True, exist_ok=True)
    (d / "a.svg").write_text('<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>')
    st, h, _ = asgi_call(app, "GET", "/api/assets/f-hdr/a.svg")
    hd = {k.decode(): v.decode() for k, v in h}
    assert st == 200 and hd["x-content-type-options"] == "nosniff" and hd["content-security-policy"].startswith("sandbox")
    pdf = Path(config.DATA_DIR) / "p28-09.pdf"
    pdf.write_bytes(b"%PDF-1.4\n")
    html = Path(config.DATA_DIR) / "p28-09.html"
    html.write_text("<script>alert(1)</script>")
    with db.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, created_at) VALUES ('c1', 'Testkurs', 'uebung', '2026-10-24')")
        for fid, name, p in (("f-pdf9", "a.pdf", pdf), ("f-html9", "a.html", html)):
            conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status, local_path) VALUES (?,?,?,?,'neu',?)",
                         (fid, "c1", name, "pdf", str(p)))
    st, h, _ = asgi_call(app, "GET", "/api/files/f-pdf9/content")
    hd = {k.decode(): v.decode() for k, v in h}
    assert st == 200 and hd["content-type"] == "application/pdf" and hd["x-content-type-options"] == "nosniff"
    assert "content-security-policy" not in hd
    st, h, _ = asgi_call(app, "GET", "/api/files/f-html9/content")
    hd = {k.decode(): v.decode() for k, v in h}
    assert hd["content-type"] == "application/octet-stream" and hd["content-disposition"].startswith("attachment")
    assert hd["content-security-policy"].startswith("sandbox")


# ---------------------------------------------------------------- P28-10 Zugriffsprotokoll

def test_p28_10_unwritable_access_log_keeps_the_response(hosted, monkeypatch):  # noqa: F811
    """Festgenagelt: ein nicht schreibbares Protokoll (OSError) kostet die Antwort nicht. Andere Fehler sind bei den
    Eingaben nicht erreichbar (Pfad und User-Agent kommen als str an, Steuerzeichen ersetzt _field)."""
    from app import retention

    def broken(*a, **k):
        raise OSError("Platte voll")
    monkeypatch.setattr(retention, "log_access", broken)
    assert asgi_call(hosted, "GET", "/login")[0] == 200


# ---------------------------------------------------------------- P28-11 Konfiguration

def test_p28_11_disk_reserve_and_quota_configuration(monkeypatch):
    """Bestaetigt (Dienst): ein negativer Wert fuer LERNAPP_DISK_MIN_FREE_MB schaltete die Reserve still ab (max(0, ..)).
    Jetzt gilt bei negativ oder ungueltig der Standard; 0 bleibt bewusst "aus" (Entwicklung). Kontingent 0 heisst
    "keine eigenen Uploads" (sicher), negativ ebenso."""
    from app import server
    for val, want in (("", 5120), ("abc", 5120), ("-1", 5120), ("-5120", 5120), ("0", 0), ("100", 100), ("999999", 999999)):
        monkeypatch.setenv("LERNAPP_DISK_MIN_FREE_MB", val)
        assert server._disk_min_free_bytes() == want << 20, val
    for val, want in (("", 2048), ("abc", 2048), ("0", 0), ("-3", 0), ("512", 512)):
        monkeypatch.setenv("LERNAPP_UPLOAD_QUOTA_MB", val)
        assert server._upload_quota_bytes() == want << 20, val


# ---------------------------------------------------------------- P28-12 Pfade und IDs

def test_p28_12_safe_id_rejects_trailing_newline_and_tricks():
    """Bestaetigt (klein): `$` passt vor einem abschliessenden Zeilenumbruch, "abc\\n" (URL %0A) ging als ID durch und
    wurde Ordnername. Jetzt fullmatch. Pfad-Tricks, NUL, Unicode bleiben abgewiesen."""
    from app import server
    for bad in ("abc\n", "a/b", "..", "../x", "a\\b", "/etc", "a\x00b", "C:x", "ä", "ab c", ".x", "-x", "١٢٣", "ａｂｃ", "", "a" * 81):
        with pytest.raises(server.HTTPException):
            server._safe_id(bad)
    for ok in ("abc", "u0123abcd", "A_b-9", "a" * 80):
        assert server._safe_id(ok) == ok
    assert not server._SAFE_NAME.fullmatch("abc.png\n")
    assert server._SAFE_NAME.fullmatch("abc.png")


def test_p28_12_asset_routes_with_newline_ids(app):
    from app import server
    body, ctype = _multipart("upload", "a.png", b"\x89PNG")
    _add_file("f-nl")
    st, _, _ = asgi_call(app, "POST", "/api/files/f-nl%0A/assets", body=body, content_type=ctype)
    assert st == 400
    assert not (server._assets_dir() / "f-nl\n").exists()
    assert asgi_call(app, "GET", "/api/assets/f-nl/abc.png%0A")[0] == 400


def test_p28_12_inside_handles_symlinks_absolute_and_missing(tmp_path):
    import os
    from app import server
    base = tmp_path / "base"
    (base / "sub").mkdir(parents=True)
    out = tmp_path / "out"
    out.mkdir()
    os.symlink(out, base / "flucht")
    assert server._inside(base, base / "sub" / "gibt-es-nicht") == (base / "sub" / "gibt-es-nicht").resolve()
    assert server._inside(base, base) == base.resolve()
    for bad in (base / "flucht", base / "flucht" / "x", base / ".." / "out", base / "/etc", base / "sub" / ".." / ".."):
        with pytest.raises(server.HTTPException):
            server._inside(base, bad)
    with pytest.raises(server.HTTPException):
        server._inside(base, Path(str(base) + "-nachbar"))       # Praefix ist kein Elternordner


# ================================================================ PAKET 29

def _seed_account(user, **rows):
    from app import config, db
    tok = config.set_user_context(user["id"], "luh")
    try:
        db.init_db()
        with db.cursor() as conn:
            conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, created_at) VALUES ('c1', 'Testkurs', 'uebung', '2026-10-24')")
            conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status) VALUES ('f-a', 'c1', 'a.pdf', 'pdf', 'neu')")
            conn.execute("INSERT OR REPLACE INTO annotations(file_id, data, updated_at, version) VALUES ('f-a', '{}', '2026-11-01', 1)")
            cur = conn.execute("INSERT INTO flashcard_stacks(name, created_at) VALUES ('S', '2026-11-01')")
            sid = cur.lastrowid
            card = conn.execute("INSERT INTO flashcards(stack_id, question, answer, created_at) VALUES (?, 'v', 'r', '2026-11-01')", (sid,)).lastrowid
        return sid, card
    finally:
        config.reset_user_context(tok)


def _count(user, sql, args=()):
    from app import config, db
    tok = config.set_user_context(user["id"], "luh")
    try:
        with db.cursor() as conn:
            return db.row(conn, sql, args)["n"]
    finally:
        config.reset_user_context(tok)


def test_p29_01_free_account_cannot_delete_annotations_via_sync(hosted):  # noqa: F811
    """Widerlegt fuer Notizen: Loeschungen von `annotations` lehnt sync.push immer ab (unknown_entity), auch mit Recht.
    Designfrage (dokumentiert): eigene Karteikarten/Stapel darf ein Free-Konto per Abgleich loeschen, ueber REST
    (DELETE /api/flashcards/{id}) erst ab Plus. Loeschen eigener Daten beruehrt niemand anderen."""
    u, h = _user(hosted, "frei@beispiel.de", plus=False)
    sid, card = _seed_account(u)
    st, d = _j(asgi_call(hosted, "POST", "/api/sync/push", headers=h, body=json.dumps(
        {"device_id": "d1", "items": [], "deletes": [{"entity": "annotations", "id": "f-a"},
                                                     {"entity": "flashcards", "id": card}]})))
    assert st == 200, d
    by = {r["entity"]: r["status"] for r in d["results"]}
    assert by["annotations"] == "unknown_entity"
    assert _count(u, "SELECT COUNT(*) AS n FROM annotations WHERE file_id='f-a'") == 1
    assert by["flashcards"] == "deleted"           # Designfrage, siehe Bericht
    assert asgi_call(hosted, "DELETE", f"/api/flashcard-stacks/{sid}", headers=h)[0] == 403


def test_p29_02_all_clients_send_base_version(app):
    """Widerlegt fuer die eigenen Clients: Web (editor.js, notes-queue.js), iPad (APIClient.swift) und Android
    (AnnotationStore.kt) senden base_version. Ohne base_version gilt der letzte Schreiber (festgenagelt, Designfrage)."""
    for rel in ("app/static/editor.js", "app/static/notes-queue.js", "apps/apple/UniFlow/Services/APIClient.swift",
                "apps/android/core/src/main/kotlin/de/uniflow/core/AnnotationStore.kt"):
        assert "base_version" in (ROOT / rel).read_text(encoding="utf-8"), rel
    _add_file("f-lww")
    assert _j(asgi_call(app, "PUT", "/api/files/f-lww/annotations?base_version=0", body='{"a": 1}'))[0] == 200
    assert _j(asgi_call(app, "PUT", "/api/files/f-lww/annotations?base_version=0", body='{"a": 2}'))[0] == 409
    st, d = _j(asgi_call(app, "PUT", "/api/files/f-lww/annotations", body='{"a": 3}'))
    assert st == 200 and d["version"] == 2


def test_p29_03_delete_forever_removes_unreferenced_assets(app):
    """Bestaetigt (beides): Bilder und Aufnahmen eines endgueltig geloeschten Dokuments blieben in assets/<id>/ liegen
    und belegten im Dienst das Kontingent fuer immer (kein Weg, den Platz freizugeben). Jetzt weg - ausser ein
    anderes Dokument (Duplikat) verweist noch darauf."""
    from app import db, server
    body, ctype = _multipart("upload", "a.pdf", b"%PDF-1.4\n" + b"\0" * 100, {"kind": "pdf", "title": "x"})
    fid = _j(asgi_call(app, "POST", "/api/notebooks", body=body, content_type=ctype))[1]["id"]
    img, ctype = _multipart("upload", "a.png", b"\x89PNG" + b"\0" * 100)
    url = _j(asgi_call(app, "POST", f"/api/files/{fid}/assets", body=img, content_type=ctype))[1]["url"]
    assert asgi_call(app, "PUT", f"/api/files/{fid}/annotations", body=json.dumps({"img": url}))[0] == 200
    d = server._assets_dir() / fid
    assert any(d.iterdir())
    # Duplikat verweist auf dieselben Bilder: Original weg, Bilder bleiben
    dup = _j(asgi_call(app, "PATCH", f"/api/library/files/{fid}", body=json.dumps({"duplicate": True})))[1]["id"]
    assert asgi_call(app, "PATCH", f"/api/library/files/{fid}", body=json.dumps({"delete_forever": True}))[0] == 200
    assert d.is_dir() and any(d.iterdir()), "Duplikat braucht die Bilder noch"
    assert asgi_call(app, "PATCH", f"/api/library/files/{dup}", body=json.dumps({"delete_forever": True}))[0] == 200
    with db.cursor() as conn:
        assert not db.row(conn, "SELECT 1 FROM files WHERE id IN (?,?)", (fid, dup))
    # das Duplikat hat eigene ID ohne eigene Assets; die des Originals sind jetzt unreferenziert - beim Loeschen des
    # letzten Verweises raeumt der Dienst den Ordner des Originals mit auf
    assert not d.exists(), "unreferenzierte Assets sind weg"


def test_p29_03_asset_for_unknown_file_is_accepted_design(app):
    """Festgenagelt (Designfrage): upload_asset prueft nicht, ob die Datei existiert (Aufnahmen schon). Folge nur fuer
    das eigene Konto (eigener Ordner, eigenes Kontingent); kein Zugriff auf Fremdes."""
    img, ctype = _multipart("upload", "a.png", b"\x89PNG")
    assert asgi_call(app, "POST", "/api/files/gibt-es-nicht/assets", body=img, content_type=ctype)[0] == 200


def test_p29_04_pagetext_limits_hold(hosted):  # noqa: F811
    """Festgenagelt: Grenzen je Seite und Seitenzahl; die Koerpergrenze (32 MB, P28-01) begrenzt die Summe."""
    _, h = _user(hosted, "text@beispiel.de")
    for pages in ([], ["x"] * 2001, ["x" * 20001], [1]):
        st, d = _j(asgi_call(hosted, "PUT", "/api/files/f1/pagetext", headers=h, body=json.dumps({"pages": pages})))
        assert st == 400 and d["code"] == "pagetext_invalid", (len(pages), st)


def test_p29_05_docx_size_is_checked_before_reading(app, monkeypatch, tmp_path):
    """Bestaetigt (PC; im Dienst gibt es keine lokalen DOCX): file_docx las die ganze Datei mit read_bytes() in den
    Speicher und lehnte erst danach (> 60 MB) ab. Jetzt erst die Groesse."""
    from app import config, db, docx_view
    monkeypatch.setattr(docx_view, "MAX_BYTES", 1 << 10)
    p = Path(config.DATA_DIR) / "p29-05.docx"
    p.write_bytes(b"PK" + b"\0" * (4 << 10))
    with db.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, created_at) VALUES ('c1', 'Testkurs', 'uebung', '2026-10-24')")
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status, local_path) VALUES ('f-docx5','c1','a.docx','docx','neu',?)", (str(p),))
    read = []
    real = Path.read_bytes
    monkeypatch.setattr(Path, "read_bytes", lambda self: read.append(self) or real(self))
    st, d = _j(asgi_call(app, "GET", "/api/files/f-docx5/docx"))
    assert st == 422 and d["code"] == "docx_unreadable"
    assert p not in read, "zu grosse Datei nicht erst einlesen"


def test_p29_06_patch_course_and_file_validate_types(app):
    """Bestaetigt (beides): difficulty "abc" -> ValueError -> 500, ein Objekt als Wert -> sqlite-Bindefehler -> 500,
    test_minutes ohne Grenze. Jetzt 400 value_invalid; gueltige Werte wie bisher."""
    from app import db
    _add_file("f-p6")
    with db.cursor() as conn:
        conn.execute("INSERT OR REPLACE INTO analysis(file_id, difficulty) VALUES ('f-p6', 3)")
    for body in ({"difficulty": "abc"}, {"difficulty": None}, {"difficulty": 9}, {"difficulty": [1]}, {"difficulty": True}):
        st, _, b = _call(app, "PATCH", "/api/files/f-p6", body=json.dumps(body))
        assert st == 400 and b"value_invalid" in b, (body, st, b[:200])
    for body in ({"subject": {"x": 1}}, {"kind": [1]}, {"active": "ja"}, {"active": 5}, {"test_minutes": -1},
                 {"test_minutes": 10 ** 9}, {"test_minutes": "90"}, {"subject": "x" * 500}):
        st, _, b = _call(app, "PATCH", "/api/courses/c1", body=json.dumps(body))
        assert st == 400 and b"value_invalid" in b, (body, st, b[:200])
    st, d = _j(asgi_call(app, "PATCH", "/api/files/f-p6", body=json.dumps({"difficulty": 4})))
    assert st == 200
    st, d = _j(asgi_call(app, "PATCH", "/api/courses/c1", body=json.dumps({"active": 1, "kind": "uebung", "test_minutes": 60, "subject": "Mathe"})))
    assert st == 200 and d["test_minutes"] == 60 and d["active"] == 1
    st, d = _j(asgi_call(app, "PATCH", "/api/courses/c1", body=json.dumps({"active": False, "subject": None, "difficulty": "egal"})))
    assert st == 200 and d["active"] == 0
    assert _j(asgi_call(app, "PATCH", "/api/courses/c1", body=json.dumps({"active": 1.0})))[0] == 200   # iPad: Zahl als Double


def test_p29_10_page_text_error_does_not_leak_internals(app, monkeypatch):
    """Bestaetigt (klein, beides): eine Ausnahme der Textextraktion ging als str(e) an den Client (Pfade, SQL).
    Jetzt eine feste Meldung mit code, Details nur im Server-Log. Status bleibt 200 (Clients werten `text` aus)."""
    from app import scriptsearch
    _add_file("f-pt10")

    def boom(*a, **k):
        raise RuntimeError("/srv/daten/users/abc/geheim.db: database disk image is malformed")
    monkeypatch.setattr(scriptsearch, "page_texts", boom)
    st, d = _j(asgi_call(app, "GET", "/api/files/f-pt10/pagetext?page=1"))
    assert st == 200 and d["text"] == "" and d["code"] == "pagetext_failed"
    assert "/srv" not in json.dumps(d) and "malformed" not in json.dumps(d)
