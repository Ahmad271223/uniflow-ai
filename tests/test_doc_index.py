"""Dokument-Index, Dienst-Seite (app/doc_index.py, V2-Geruest): Schema byte-gleich mit dem gemeinsamen Vertrag, Pruefer,
Fingerabdruecke (Erwartungswerte fuer das iPad), Upload fuer hoechstens 15 Minuten mit Loeschauftrag, KI-Geruest."""
import json
import shutil
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from conftest import asgi_call
from test_community import _user, hosted  # noqa: F401
from test_security import _multipart

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / "packages" / "shared-contracts" / "doc-index.schema.json"


def _pdf_bytes(pages=2, text="Eigenwerte einer Matrix. Das charakteristische Polynom liefert die Eigenwerte."):
    from pypdf import PdfWriter
    import io
    w = PdfWriter()
    for _ in range(pages):
        w.add_blank_page(width=200, height=200)
    buf = io.BytesIO()
    w.write(buf)
    return buf.getvalue()


def _entry(**over):
    e = {"summary": "Eigenwerte und das charakteristische Polynom.", "terms": ["Eigenwert", "charakteristisches Polynom"],
         "elements": [{"order": 1, "type": "definition", "title": "Eigenwert", "explanation": "λ mit A v = λ v.", "position": "oben",
                       "task": None, "uncertain": False},
                      {"order": 2, "type": "formel", "title": "charakteristisches Polynom", "explanation": "det(A − λI) = 0.",
                       "position": "mitte", "task": None, "uncertain": True}],
         "tasks": [{"label": "Aufgabe 1", "asks": "Eigenwerte der Matrix bestimmen.", "solution": None}]}
    e.update(over)
    return e


@pytest.fixture
def clean_uploads():
    from app import doc_index
    shutil.rmtree(doc_index.upload_dir(), ignore_errors=True)
    yield
    shutil.rmtree(doc_index.upload_dir(), ignore_errors=True)


# ---------------------------------------------------------------- Vertrag

def test_schema_matches_contract_byte_for_byte():
    from app import doc_index
    assert doc_index.SCHEMA_JSON == CONTRACT.read_text(encoding="utf-8"), "app/doc_index.py SCHEMA_JSON aus der Vertragsdatei uebernehmen"
    assert doc_index.SCHEMA["version"] == doc_index.SCHEMA_VERSION == 1
    assert set(doc_index.SCHEMA["$defs"]) == {"catalog", "summary", "pageRecord"}


def test_fixture_cases_are_current():
    r = subprocess.run([sys.executable, str(ROOT / "tools" / "gen-doc-index-cases.py"), "--check"], cwd=ROOT, capture_output=True,
                       text=True, timeout=120)
    assert r.returncode == 0, r.stdout + r.stderr


# ---------------------------------------------------------------- Pruefer

def test_validate_accepts_good_entry_and_lists_errors():
    from app import doc_index
    assert doc_index.check_entry(_entry()) == []
    bad = _entry(summary="x" * 501, terms=["a"] * 13, extra=1)
    bad["elements"][0]["type"] = "bild"
    bad["elements"][1].pop("position")
    errors = doc_index.validate(bad)
    assert any("$.summary" in e and "501" in e for e in errors)
    assert any("$.terms" in e for e in errors)
    assert any("$.extra" in e for e in errors)
    assert any("$.elements[0].type" in e for e in errors)
    assert any("$.elements[1].position" in e for e in errors)
    assert doc_index.validate("kein Objekt") == ["$: Typ str, erwartet object"]
    assert doc_index.validate({"v": 2, "fileName": "a", "pageCount": -1, "pageHashes": [], "catalog": {}, "createdAt": ""},
                              doc_index.SUMMARY_SCHEMA)[:2] == ["$.v: 2 statt 1", "$.pageCount: -1 unter 0"]


def test_check_entry_requires_gapless_order_and_unique_tasks():
    from app import doc_index
    e = _entry()
    e["elements"][1]["order"] = 3
    assert doc_index.check_entry(e) == ["$.elements: order muss 1..n ohne Luecken sein"]
    e = _entry(tasks=[{"label": "A", "asks": "x"}, {"label": "A", "asks": "y"}])
    assert doc_index.check_entry(e) == ["$.tasks: Aufgaben doppelt"]


def test_normalized_entry_is_deterministic():
    from app import doc_index
    e = _entry(terms=[" Eigenwert ", "eigenwert", "Polynom"])
    e["elements"].reverse()
    n = doc_index.normalized_entry(e)
    assert [x["order"] for x in n["elements"]] == [1, 2] and n["terms"] == ["Eigenwert", "Polynom"]
    assert json.dumps(n, sort_keys=True) == json.dumps(doc_index.normalized_entry(_entry(terms=["Eigenwert", "Polynom"])), sort_keys=True)


# ---------------------------------------------------------------- Fingerabdruecke

def test_fingerprints_follow_the_rules():
    from app import doc_index
    sha = "a" * 64
    assert doc_index.file_key(sha) == doc_index.file_key(sha.upper()) and doc_index.file_key(sha) != sha
    with pytest.raises(ValueError):
        doc_index.file_key("abc")
    t1 = "Eigenwerte einer Matrix\nDas charakteristische Polynom liefert die Eigenwerte."
    t2 = "EIGENWERTE   einer Matrix\n\nDas charakteristische Polynom liefert die Eigenwerte."
    assert doc_index.page_hash(t1, sha, 1) == doc_index.page_hash(t2, sha, 7), "Leerraum und Schreibung aendern den Abdruck nicht"
    assert doc_index.page_hash(t1, sha, 1) == doc_index.page_hash(t1, "b" * 64, 1), "Textseite: nur der Text zaehlt"
    assert doc_index.page_hash("  3 ", sha, 5) != doc_index.page_hash("  3 ", sha, 6), "Bildseite: an Datei und Seite gebunden"
    assert doc_index.page_hash("", sha, 5) != doc_index.page_hash("", "b" * 64, 5)
    assert doc_index.record_name(doc_index.file_key(sha), 0).endswith("#0")
    assert doc_index.catalog_kind("uebung", "Hörsaalübung") == ("hoersaaluebung", "Hörsaalübung")
    assert doc_index.catalog_kind("organisatorisch", "Organisatorisches") == ("sonstiges", "Sonstiges")


# ---------------------------------------------------------------- Upload und 15-Minuten-Regel

def _upload(app, pdf, sha=None, extra=None):
    import hashlib
    body, ctype = _multipart("upload", "vl01.pdf", pdf, {"file_sha": sha or hashlib.sha256(pdf).hexdigest(),
                                                           "file_name": "vl01.pdf", "course": "Testmathe", **(extra or {})})
    return asgi_call(app, "POST", "/api/index/file", body=body, content_type=ctype)


def test_upload_rejects_non_pdf_and_wrong_sha(app, clean_uploads):
    from app import doc_index
    st, _, b = _upload(app, b"<html>keine pdf</html>")
    assert st == 400 and b"not_pdf" in b
    st, _, b = _upload(app, _pdf_bytes(), sha="0" * 64)
    assert st == 400 and b"sha_mismatch" in b
    st, _, b = _upload(app, _pdf_bytes(), sha="xyz")
    assert st == 400 and b"bad_sha" in b
    assert not list(doc_index.upload_dir().glob("*")), "abgelehnte Uploads hinterlassen nichts"


def test_upload_is_stored_with_expiry_and_purged_after_15_minutes(app, clean_uploads):
    from app import doc_index
    pdf = _pdf_bytes()
    st, _, b = _upload(app, pdf, extra={"pages": "1, 2, x, 999"})
    assert st == 202, b
    d = json.loads(b)
    job = doc_index.upload_dir() / d["job_id"]
    assert (job / "upload.pdf").read_bytes() == pdf and d["status"] == "queued"
    assert d["file_key"] == doc_index.file_key(__import__("hashlib").sha256(pdf).hexdigest())
    assert "file_sha" not in d and "size" not in d, "nach aussen nur Schluessel und Zustand"
    meta = json.loads((job / "meta.json").read_text(encoding="utf-8"))
    assert meta["pages"] == [1, 2] and meta["file_name"] == "vl01.pdf"
    received = datetime.fromisoformat(d["received_at"])
    assert datetime.fromisoformat(d["expires_at"]) - received == timedelta(minutes=15)
    # nach 14 Minuten bleibt die Datei, nach 15 ist sie weg - auch ohne Verarbeitung
    assert doc_index.purge_expired(received + timedelta(minutes=14)) == {"files_deleted": 0, "jobs_removed": 0, "checked": 1}
    assert (job / "upload.pdf").exists()
    assert doc_index.purge_expired(received + timedelta(minutes=15, seconds=1), dry_run=True)["files_deleted"] == 1
    assert (job / "upload.pdf").exists(), "Probelauf loescht nichts"
    assert doc_index.purge_expired(received + timedelta(minutes=15, seconds=1))["files_deleted"] == 1
    assert not (job / "upload.pdf").exists()
    st, _, b = asgi_call(app, "GET", f"/api/index/jobs/{d['job_id']}")
    s = json.loads(b)
    assert st == 200 and s["status"] == "expired" and s["file_deleted_reason"] == "expired"
    # ein zweiter Lauf findet nichts mehr; der leere Auftragsordner geht nach einem Tag
    assert doc_index.purge_expired(received + timedelta(minutes=20))["files_deleted"] == 0
    assert doc_index.purge_expired(received + timedelta(days=1, minutes=1))["jobs_removed"] == 1
    assert not job.exists()
    assert asgi_call(app, "GET", f"/api/index/jobs/{d['job_id']}")[0] == 404
    assert asgi_call(app, "GET", "/api/index/jobs/../meta")[0] == 404


def test_purge_handles_running_job_and_missing_meta(app, clean_uploads):
    """Ein haengender Auftrag (running) behaelt die Datei nicht; ein Ordner ohne meta.json zaehlt nach seiner Aenderungszeit."""
    from app import doc_index
    import os
    import time
    st, _, b = _upload(app, _pdf_bytes())
    d = json.loads(b)
    job = doc_index.upload_dir() / d["job_id"]
    meta = json.loads((job / "meta.json").read_text(encoding="utf-8"))
    meta["status"] = "running"
    (job / "meta.json").write_text(json.dumps(meta), encoding="utf-8")
    stray = doc_index.upload_dir() / ("f" * 32)
    stray.mkdir()
    (stray / "upload.pdf").write_bytes(b"%PDF")
    old = time.time() - 20 * 60
    os.utime(stray, (old, old))
    r = doc_index.purge_expired(datetime.fromisoformat(d["received_at"]) + timedelta(minutes=16))
    assert r["files_deleted"] == 2
    assert json.loads((job / "meta.json").read_text(encoding="utf-8"))["status"] == "expired"
    assert not (stray / "upload.pdf").exists()


def test_processing_deletes_the_file_immediately_even_without_ai(app, clean_uploads, monkeypatch):
    from app import doc_index
    pdf = _pdf_bytes(pages=3)
    st, _, b = _upload(app, pdf, extra={"pages": "2"})
    d = json.loads(b)
    job = doc_index.upload_dir() / d["job_id"]
    meta = doc_index.process_job(d["job_id"])
    assert meta["status"] == "unavailable" and meta["page_count"] == 3 and len(meta["page_hashes"]) == 3
    assert not (job / "upload.pdf").exists() and meta["file_deleted_reason"] == "processed"
    assert "KI" in meta["message"]
    # mit angeschlossener KI: nur die fehlende Seite 2 wird gefragt (Seiten 1 und 3 sind beim Dienst bekannt), die
    # Antwort muss zum Schema passen, sonst bis zu zwei Wiederholungen
    st, _, b = _upload(app, pdf, extra={"pages": "2"})
    d = json.loads(b)
    calls = []
    answers = [{"kaputt": True}, {"kaputt": True}, _entry()]

    def fake(course, file_name, page, page_count, text, image_jpeg=None):
        calls.append(page)
        return answers.pop(0)
    monkeypatch.setattr(doc_index, "analyze_page", fake)
    meta = doc_index.process_job(d["job_id"])
    assert calls == [2, 2, 2] and meta["status"] == "done" and meta["pages_done"] == 1 and meta["pages_failed"] == 0
    assert not (doc_index.upload_dir() / d["job_id"] / "upload.pdf").exists()
    # dreimal unbrauchbar: die Seite gilt als gescheitert, die Datei ist trotzdem weg
    st, _, b = _upload(app, pdf, extra={"pages": "1"})
    d = json.loads(b)
    answers[:] = [{"kaputt": True}] * 3
    meta = doc_index.process_job(d["job_id"])
    assert meta["status"] == "done" and meta["pages_failed"] == 1
    assert not (doc_index.upload_dir() / d["job_id"] / "upload.pdf").exists()


def test_processing_failure_still_deletes(app, clean_uploads, monkeypatch):
    from app import doc_index
    st, _, b = _upload(app, _pdf_bytes())
    d = json.loads(b)
    monkeypatch.setattr(doc_index, "analyze_page", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("Anbieter weg")))
    meta = doc_index.process_job(d["job_id"])
    assert meta["status"] == "failed" and "Anbieter weg" in meta["message"]
    assert not (doc_index.upload_dir() / d["job_id"] / "upload.pdf").exists()


def test_background_purge_is_off_in_tests():
    from app import doc_index
    doc_index.start_background()                    # LERNAPP_NO_SCHEDULER (conftest) laesst keinen Thread starten
    assert doc_index._thread is None


def test_hosted_requires_verified_account(hosted, clean_uploads):
    _, headers = _user(hosted, "index-unverified@example.org", verified=False)
    pdf = _pdf_bytes()
    import hashlib
    body, ctype = _multipart("upload", "a.pdf", pdf, {"file_sha": hashlib.sha256(pdf).hexdigest()})
    st, _, b = asgi_call(hosted, "POST", "/api/index/file", body=body, content_type=ctype, headers=headers)
    assert st == 403 and b"email_unverified" in b
    st, _, b = asgi_call(hosted, "POST", "/api/index/file", body=body, content_type=ctype)
    assert st == 401
    _, headers = _user(hosted, "index-ok@example.org")
    st, _, b = asgi_call(hosted, "POST", "/api/index/file", body=body, content_type=ctype, headers=headers)
    assert st == 202, b
