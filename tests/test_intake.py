"""Datei-Eingang (Auftrag des Inhabers vom 18.11.2026): neue Kurs-PDFs einmal sammeln und geordnet ablegen, ohne KI.
app/intake_server.py (eigenes Programm) und das Ticket im Dienst (app/intake_api.py)."""
import hashlib
import json
import os
import time

import pytest
from conftest import asgi_call

SECRET = "x" * 40


def pdf(text="Folie", extra=b""):
    """Kleine, gueltige PDF mit einer Seite und Text"""
    from io import BytesIO

    from pypdf import PdfWriter
    from pypdf.generic import DecodedStreamObject, DictionaryObject, NameObject
    w = PdfWriter()
    page = w.add_blank_page(width=200, height=200)
    stream = DecodedStreamObject()
    lines = text.split("\n")
    body = "BT /F1 8 Tf 10 180 Td " + " ".join(f"({ln}) Tj 0 -10 Td" for ln in lines) + " ET"
    stream.set_data(body.encode("latin-1"))
    page[NameObject("/Contents")] = w._add_object(stream)
    font = DictionaryObject({NameObject("/Type"): NameObject("/Font"), NameObject("/Subtype"): NameObject("/Type1"),
                             NameObject("/BaseFont"): NameObject("/Helvetica")})
    page[NameObject("/Resources")] = DictionaryObject({NameObject("/Font"): DictionaryObject({NameObject("/F1"): font})})
    b = BytesIO()
    w.write(b)
    return b.getvalue() + extra


def meta(data, **kw):
    m = {"sha256": hashlib.sha256(data).hexdigest(), "program": "Informatik (B.Sc.)", "semester": "WS 2026/27",
         "module": "Analysis I", "doc_type": "vorlesung", "file_name": "VL01 Folgen.pdf", "course_title": "Analysis I",
         "course_number": "4711", "week": 1, "pages": 1}
    m.update(kw)
    return m


def multipart(data, m, boundary="grenze123"):
    parts = [
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"meta\"\r\n\r\n{json.dumps(m)}\r\n".encode(),
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"upload\"; filename=\"f.pdf\"\r\nContent-Type: application/pdf\r\n\r\n".encode()
        + data + b"\r\n",
        f"--{boundary}--\r\n".encode(),
    ]
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


@pytest.fixture
def intake(monkeypatch, tmp_path):
    monkeypatch.setenv("LERNAPP_INTAKE_SECRET", SECRET)
    monkeypatch.setenv("INTAKE_DATA_DIR", str(tmp_path / "eingang"))
    from app import intake_server
    return intake_server


def call(srv, method, path, body=None, ticket=None, content_type="application/json"):
    headers = {"Authorization": f"Bearer {ticket}"} if ticket else {}
    st, _, b = asgi_call(srv.app, method, path, body=body, headers=headers, content_type=content_type)
    return st, (json.loads(b) if b else None)


def ticket(srv, uni="luh"):
    return srv.make_ticket(uni)["ticket"]


# ---------------------------------------------------------------- Ticket

def test_ticket_carries_no_account_and_is_checked(intake):
    t = intake.make_ticket("hildesheim")
    raw = t["ticket"].split(".")[0]
    body = json.loads(intake._unb64(raw))
    assert set(body) == {"u", "exp", "n"}, "nur Hochschule, Ablauf, Zufallszahl"
    assert intake.read_ticket("Bearer " + t["ticket"])["u"] == "hildesheim"
    for bad in ["", "Bearer kaputt", "Bearer " + raw + ".AAAA", "Bearer " + t["ticket"][:-2] + "xx"]:
        with pytest.raises(Exception) as e:
            intake.read_ticket(bad)
        assert getattr(e.value, "status_code", None) == 401
    old = intake.make_ticket("luh", now=time.time() - 2 * intake.TICKET_TTL_S)["ticket"]
    with pytest.raises(Exception) as e:
        intake.read_ticket("Bearer " + old)
    assert e.value.detail["code"] == "ticket_expired"


def test_without_secret_the_intake_is_off(monkeypatch, tmp_path):
    monkeypatch.delenv("LERNAPP_INTAKE_SECRET", raising=False)
    monkeypatch.setenv("INTAKE_DATA_DIR", str(tmp_path / "e"))
    from app import intake_server
    st, d = call(intake_server, "POST", "/intake/v1/check", body=json.dumps({"files": []}), ticket="a.b")
    assert st == 503 and d["detail"]["code"] == "intake_not_configured"


# ---------------------------------------------------------------- Eingang

def test_check_upload_and_sorted_folders(intake):
    t = ticket(intake)
    data = pdf("Folgen und Reihen\nKonvergenz")
    m = meta(data)
    st, d = call(intake, "POST", "/intake/v1/check", body=json.dumps({"files": [m]}), ticket=t)
    assert st == 200 and d == {"missing": [m["sha256"]]}

    body, ct = multipart(data, m)
    st, d = call(intake, "POST", "/intake/v1/file", body=body, ticket=t, content_type=ct)
    assert st == 200 and d == {"status": "stored"}, d

    root = intake.data_dir()
    stored = root / "dateien" / m["sha256"][:2] / f"{m['sha256']}.pdf"
    assert stored.read_bytes() == data
    sorted_file = (root / "geordnet" / "Leibniz Universitaet Hannover" / "Informatik (B.Sc.)" / "WS 2026-27"
                   / "Analysis I" / "Vorlesungen" / "VL01 Folgen.pdf")
    assert sorted_file.exists() and sorted_file.samefile(stored), "geordnet als harter Link, kein zweiter Platz"

    # das naechste Geraet mit derselben Datei schickt nichts mehr
    st, d = call(intake, "POST", "/intake/v1/check", body=json.dumps({"files": [m]}), ticket=ticket(intake))
    assert d == {"missing": []}

    # anderer Studiengang mit demselben Modul: nur ein weiterer Platz in der Ordnung, keine zweite Datei
    m2 = meta(data, program="Mathematik (B.Sc.)")
    st, d = call(intake, "POST", "/intake/v1/check", body=json.dumps({"files": [m2]}), ticket=ticket(intake))
    assert d == {"missing": []}
    other = root / "geordnet" / "Leibniz Universitaet Hannover" / "Mathematik (B.Sc.)" / "WS 2026-27" / "Analysis I" / "Vorlesungen" / "VL01 Folgen.pdf"
    assert other.exists() and other.samefile(stored)
    assert len(list((root / "dateien").rglob("*.pdf"))) == 1

    ov = intake.overview()
    assert [(r["program"], r["module"], r["files"], r["stored"]) for r in ov] == [
        ("Informatik (B.Sc.)", "Analysis I", 1, 1), ("Mathematik (B.Sc.)", "Analysis I", 1, 1)]


def test_no_account_and_no_ip_in_the_store(intake):
    t = ticket(intake)
    data = pdf("Skript")
    m = meta(data, doc_type="skript", file_name="Skript.pdf")
    call(intake, "POST", "/intake/v1/check", body=json.dumps({"files": [m]}), ticket=t)
    body, ct = multipart(data, m)
    call(intake, "POST", "/intake/v1/file", body=body, ticket=t, content_type=ct)
    import sqlite3
    c = sqlite3.connect(intake.data_dir() / "eingang.db")
    cols = {r[1] for tbl in ("files", "places") for r in c.execute(f"PRAGMA table_info({tbl})")}
    assert not cols & {"user_id", "account", "ip", "device"}


def test_rejects_wrong_content_non_pdf_and_name_lists(intake):
    t = ticket(intake)
    data = pdf("Folie")
    body, ct = multipart(data, meta(pdf("andere Datei")))
    st, d = call(intake, "POST", "/intake/v1/file", body=body, ticket=t, content_type=ct)
    assert st == 422 and d["detail"]["code"] == "sha_mismatch"

    txt = b"kein pdf"
    body, ct = multipart(txt, meta(txt))
    st, _ = call(intake, "POST", "/intake/v1/file", body=body, ticket=t, content_type=ct)
    assert st == 415

    names = pdf("Name Vorname Matrikelnummer\nMueller Anna 1234567\nSchmidt Ben 2345678\nKaya Can 3456789\nLe Duc 4567890\nOtto Eva 5678901")
    body, ct = multipart(names, meta(names, doc_type="uebung", file_name="Blatt 3 Gruppen.pdf"))
    st, d = call(intake, "POST", "/intake/v1/file", body=body, ticket=t, content_type=ct)
    assert st == 422 and d["detail"]["code"] == "name_list"
    assert not (intake.data_dir() / "dateien").exists() or not list((intake.data_dir() / "dateien").rglob("*.pdf"))

    # Organisatorisches und Sonstiges nimmt der Eingang gar nicht an
    st, _ = call(intake, "POST", "/intake/v1/check", body=json.dumps({"files": [meta(data, doc_type="organisatorisch")]}), ticket=t)
    assert st == 422


def test_name_list_rule():
    from app.intake_server import looks_like_name_list
    assert looks_like_name_list("", "Teilnehmerliste WS.pdf")
    assert looks_like_name_list("1234567 2345678 3456789 4567890 5678901")
    assert looks_like_name_list("Notenliste ... Unterschrift")
    assert not looks_like_name_list("Satz 3.1: Jede beschraenkte Folge hat eine konvergente Teilfolge. 2026", "VL03.pdf")
    assert not looks_like_name_list("Matrikelnummer bitte oben eintragen", "Blatt 1.pdf"), "ein Feld fuer die eigene Nummer ist keine Liste"


def test_same_name_new_version_gets_its_own_file(intake):
    t = ticket(intake)
    a, b = pdf("Fassung 1"), pdf("Fassung 2")
    for data in (a, b):
        m = meta(data)
        call(intake, "POST", "/intake/v1/check", body=json.dumps({"files": [m]}), ticket=t)
        body, ct = multipart(data, m)
        assert call(intake, "POST", "/intake/v1/file", body=body, ticket=t, content_type=ct)[0] == 200
    folder = intake.data_dir() / "geordnet" / "Leibniz Universitaet Hannover" / "Informatik (B.Sc.)" / "WS 2026-27" / "Analysis I" / "Vorlesungen"
    names = sorted(p.name for p in folder.iterdir())
    assert len(names) == 2 and "VL01 Folgen.pdf" in names
    assert any(n.startswith("VL01 Folgen (") and n.endswith(").pdf") for n in names), "neue Fassung mit Kurzform des Fingerabdrucks"


def test_folder_names_are_safe(intake):
    assert intake.folder_name("../../etc/passwd", "x") == "etc passwd"
    assert intake.folder_name("  ", "Ohne") == "Ohne"
    assert intake.folder_name("Übung: Lineare Algebra", "x") == "Übung Lineare Algebra"
    m = intake.clean_meta({"sha256": "a" * 64, "doc_type": "klausur", "file_name": "alt", "program": "", "semester": None,
                           "module": "M", "week": 99, "pages": -1}, "luh")
    assert (m["file_name"], m["program"], m["semester"], m["week"], m["pages"]) == ("alt.pdf", "Ohne Studiengang", "Ohne Semester", None, None)


def test_ticket_limits(intake, monkeypatch):
    monkeypatch.setattr(intake, "TICKET_MAX_FILES", 1)
    t = ticket(intake)
    a, b = pdf("eins"), pdf("zwei")
    for i, data in enumerate((a, b)):
        m = meta(data, file_name=f"VL{i}.pdf")
        body, ct = multipart(data, m)
        st, d = call(intake, "POST", "/intake/v1/file", body=body, ticket=t, content_type=ct)
        assert st == (200 if i == 0 else 429), d


# ---------------------------------------------------------------- Weiterleitung im Dienst (ohne Domain)

from test_subscriptions import hosted, user  # noqa: E402,F401


@pytest.fixture
def svc(hosted, intake, monkeypatch):
    """Dienst mit Eingang im privaten Netz; die Weiterleitung geht hier direkt in das Programm des Eingangs"""
    from app import intake_api
    monkeypatch.setenv("LERNAPP_INTAKE_URL", "http://10.0.0.3:8780")
    sent = []

    def fake_forward(url, path, body, content_type, university):
        if not isinstance(body, bytes):                      # Datei in Stuecken (intake_api.Stream)
            assert len(body) == sum(len(c) for c in body)
            body = b"".join(body)
        t = intake.make_ticket(university)["ticket"]
        st, _, b = asgi_call(intake.app, "POST", path, body=body, headers={"Authorization": f"Bearer {t}"}, content_type=content_type)
        sent.append((url, path, university, body))
        return st, (json.loads(b) if b else {})
    monkeypatch.setattr(intake_api, "forward", fake_forward)
    hosted.sent = sent
    return hosted


def svc_call(app, path, headers, body, content_type="application/json"):
    st, _, b = asgi_call(app, "POST", path, body=body, headers=headers, content_type=content_type)
    return st, (json.loads(b) if b else None)


def test_service_forwards_without_account(svc, intake):
    st, d = svc_call(svc, "/api/intake/check", {}, json.dumps({"files": []}))
    assert st == 401, "nur mit Konto"
    u, h = user(svc, "eingang@example.com", plan="free", uni="hildesheim")
    data = pdf("Folgen und Reihen")
    m = meta(data)
    st, d = svc_call(svc, "/api/intake/check", h, json.dumps({"files": [m]}))
    assert st == 200 and d == {"missing": [m["sha256"]]}, d

    body, ct = multipart(data, m)
    st, d = svc_call(svc, "/api/intake/file", h, body, ct)
    assert st == 200 and d == {"status": "stored"}, d
    stored = intake.data_dir() / "geordnet" / "Universitaet Hildesheim" / "Informatik (B.Sc.)" / "WS 2026-27" / "Analysis I" / "Vorlesungen" / "VL01 Folgen.pdf"
    assert stored.read_bytes() == data, "Hochschule kommt aus dem Konto"

    # nichts, was das Konto verraet, geht an den Eingang
    for url, path, uni, b in svc.sent:
        assert url == "http://10.0.0.3:8780" and uni == "hildesheim"
        assert u["id"].encode() not in b and u["email"].encode() not in b


def test_service_passes_rejections_on(svc, intake):
    u, h = user(svc, "liste@example.com")
    names = pdf("1234567 2345678 3456789 4567890 5678901")
    body, ct = multipart(names, meta(names, doc_type="uebung", file_name="Blatt.pdf"))
    st, d = svc_call(svc, "/api/intake/file", h, body, ct)
    assert st == 422 and d["code"] == "name_list"


def test_service_daily_limit(svc, monkeypatch):
    from app import intake_api
    monkeypatch.setattr(intake_api, "CHECKS_PER_DAY", 2)
    u, h = user(svc, "viel@example.com")
    codes = [svc_call(svc, "/api/intake/check", h, json.dumps({"files": []}))[0] for _ in range(3)]
    assert codes == [200, 200, 429]


def test_service_off_without_private_address(hosted, monkeypatch):
    from app import intake_api
    monkeypatch.setenv("LERNAPP_INTAKE_SECRET", SECRET)
    u, h = user(hosted, "aus@example.com")
    for url in ["", "http://eingang.example", "http://8.8.8.8:8780", "ftp://10.0.0.3"]:
        monkeypatch.setenv("LERNAPP_INTAKE_URL", url)
        assert intake_api.intake_url() is None, url
        st, d = svc_call(hosted, "/api/intake/check", h, json.dumps({"files": []}))
        assert st == 503 and d["code"] == "intake_off"
    for url in ["http://10.0.0.3:8780", "http://172.16.0.2:8780", "http://127.0.0.1:8780", "https://x.example"]:
        monkeypatch.setenv("LERNAPP_INTAKE_URL", url)
        assert intake_api.intake_url() == url


def test_unreachable_intake_is_502(hosted, monkeypatch):
    from app import intake_api
    monkeypatch.setenv("LERNAPP_INTAKE_SECRET", SECRET)
    monkeypatch.setenv("LERNAPP_INTAKE_URL", "http://127.0.0.1:9")
    u, h = user(hosted, "weg@example.com")
    st, d = svc_call(hosted, "/api/intake/check", h, json.dumps({"files": []}))
    assert st == 502 and d["code"] == "intake_unreachable"


# ---------------------------------------------------------------- Andrang (18.11.2026: "problemlos, ohne dass normale Nutzer etwas merken")

def test_service_busy_answers_503_and_keeps_nothing(svc, monkeypatch):
    """Zu viele Weitergaben gleichzeitig: 503 intake_busy mit Retry-After; die App versucht es still beim naechsten Abgleich"""
    from app import intake_api
    u, h = user(svc, "andrang@example.com")
    data = pdf("Folgen und Reihen")
    body, ct = multipart(data, meta(data))
    monkeypatch.setattr(intake_api, "_uploads_running", intake_api.parallel_uploads())
    st, d = svc_call(svc, "/api/intake/file", h, body, ct)
    assert st == 503 and d["code"] == "intake_busy"
    assert svc.sent == [], "nichts weitergereicht"
    monkeypatch.setattr(intake_api, "_uploads_running", 0)
    st, d = svc_call(svc, "/api/intake/file", h, body, ct)
    assert st == 200 and intake_api._uploads_running == 0, "Zaehler geht nach der Weitergabe zurueck"


def test_parallel_setting_is_bounded(monkeypatch):
    from app import intake_api
    for raw, want in [("", 2), ("x", 2), ("0", 1), ("5", 5), ("99", 16)]:
        monkeypatch.setenv("LERNAPP_INTAKE_PARALLEL", raw)
        assert intake_api.parallel_uploads() == want, raw


def test_intake_busy_answers_503(intake, monkeypatch):
    monkeypatch.setattr(intake, "_running", intake.PARALLEL)
    data = pdf("Folgen und Reihen")
    body, ct = multipart(data, meta(data))
    st, _, b = asgi_call(intake.app, "POST", "/intake/v1/file", body=body,
                         headers={"Authorization": f"Bearer {ticket(intake)}"}, content_type=ct)
    assert st == 503 and json.loads(b)["detail"]["code"] == "intake_busy"


def test_stream_reaches_the_intake_in_pieces_with_length(monkeypatch):
    """Echte Weitergabe ueber HTTP: Datei in Stuecken (nie ganz im Speicher des Dienstes), Content-Length stimmt"""
    import http.server, io, threading
    from app import intake_api
    got = {}

    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers["Content-Length"])
            got["body"], got["len"] = self.rfile.read(n), n
            out = b'{"status": "stored"}'
            self.send_response(200); self.send_header("Content-Length", str(len(out))); self.end_headers()
            self.wfile.write(out)

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.handle_request, daemon=True).start()
    monkeypatch.setenv("LERNAPP_INTAKE_SECRET", SECRET)
    monkeypatch.setattr(intake_api, "CHUNK", 7)
    data = b"%PDF-1.4 " + bytes(range(256)) * 5
    s = intake_api.Stream(b"KOPF", io.BytesIO(data), len(data), b"ENDE")
    assert len(list(s)) > 3, "in Stuecken"
    st, d = intake_api.forward(f"http://127.0.0.1:{srv.server_port}", "/intake/v1/file", s, "application/pdf", "luh")
    srv.server_close()
    assert st == 200 and d == {"status": "stored"}
    assert got["body"] == b"KOPF" + data + b"ENDE" and got["len"] == len(s)
