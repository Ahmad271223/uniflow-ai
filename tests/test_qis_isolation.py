"""QIS-Lauf ohne gemeinsamen Zustand (Befund qis-module-global-state-shared-across-concurrent-jobs):
Profil, Zugangsdaten und gesammelte PDFs gehören je Lauf zu genau einem Konto, auch wenn zwei Aufträge gleichzeitig in
`qis.run` sind, und `GET /api/qis/documents/{id}` liefert nur Dateien aus dem QIS-Ordner des aufrufenden Kontos."""
import json
import threading
from pathlib import Path

import pytest
from conftest import asgi_call
from test_hosted_sync import _register, hosted  # noqa: F401  (Fixture)

PW = "sehr-geheim-123"


class _Loc:
    def count(self):
        return 1                                      # "Abmelden"-Link vorhanden: LUH-Login endet sofort


class _Page:
    def __init__(self, gotos):
        self.gotos = gotos

    def goto(self, url, **kw):
        from app import config
        self.gotos.append((config.current_user_id(), url))

    def wait_for_timeout(self, ms):
        pass

    def locator(self, sel):
        return _Loc()


class _Ctx:
    def __init__(self, gotos):
        self.gotos = gotos

    def new_page(self):
        return _Page(self.gotos)

    def close(self):
        pass


class _PW:
    def __init__(self, gotos):
        self.chromium = self
        self.gotos = gotos

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def launch_persistent_context(self, *a, **kw):
        return _Ctx(self.gotos)


def _two_overlapping_runs(monkeypatch, acc_a, acc_b, docs=False):
    """Zwei Aufträge in zwei Threads, beide gleichzeitig in qis.run (Abstimmung per Barriere, gestreckte Zeiten wie in den Prüfskripten):
    erst nach use_profile/credentials_for, bei Bedarf nach dem Speichern der PDFs. Liefert die Aufzeichnungen."""
    from app import config, jobs, lsf, qis
    # Seit 06.11.2026 laeuft im Dienst kein Notenspiegel-Job mehr (jobs.HOSTED_UNI_SYNC = False, keine gespeicherten
    # Zugangsdaten). Der Weg bleibt im Code; diese Tests pruefen seine Trennung je Konto weiter, mit eingeschaltetem
    # Schalter und Altbestand im Tresor (conftest.legacy_vault).
    monkeypatch.setattr(jobs, "HOSTED_UNI_SYNC", True)
    rec = {"gotos": [], "lsf_login": [], "result": {}}
    gate = threading.Barrier(2, timeout=60)               # unter Last (ganze Suite parallel) reichen 20 s knapp
    orig_creds = qis.credentials_for

    def creds(key):
        out = orig_creds(key)
        gate.wait()                                   # beide haben ihr Profil gesetzt, keiner hat sich angemeldet
        return out

    def lsf_login(page, user, pw, log):
        rec["lsf_login"].append((config.current_user_id(), user, pw))

    def grades(page, prof, store):
        return []

    def documents(page, prof, store):
        body = b"%PDF-1.4 SECRET-" + config.current_user_id().encode()
        qis._store_pdf(body, "Studienbescheinigung", store)
        if docs:
            gate.wait()                               # beide haben gespeichert, bevor einer die Liste zurückgibt
        return list(store.docs)

    monkeypatch.setattr(qis, "credentials_for", creds)
    monkeypatch.setattr(qis, "sync_playwright", lambda: _PW(rec["gotos"]))
    monkeypatch.setattr(lsf, "login", lsf_login)
    monkeypatch.setattr(qis, "fetch_grades", grades)
    monkeypatch.setattr(qis, "fetch_documents", documents)
    for acc in (acc_a, acc_b):
        jobs.enqueue(acc["id"], "grades")
    claimed = [jobs.claim_next(), jobs.claim_next()]
    assert {j["user_id"] for j in claimed} == {acc_a["id"], acc_b["id"]}

    def work(j):
        rec["result"][j["user_id"]] = jobs.run_job(j)
    ts = [threading.Thread(target=work, args=(j,)) for j in claimed]
    [t.start() for t in ts]
    [t.join(120) for t in ts]
    assert not any(t.is_alive() for t in ts)
    return rec


def test_concurrent_runs_keep_credentials_and_profile_per_account(hosted, monkeypatch):
    from conftest import legacy_vault

    from app import accounts, qis
    a = accounts.register("qa@beispiel.de", PW, "luh")
    b = accounts.register("qb@beispiel.de", PW, "hildesheim")
    legacy_vault(a["id"], {"STUDIP_USER": "luh-user-A", "STUDIP_PASSWORD": "luh-pw-A"})
    legacy_vault(b["id"], {"HILDESHEIM_USER": "hil-user-B", "HILDESHEIM_PASSWORD": "hil-pw-B"})
    rec = _two_overlapping_runs(monkeypatch, a, b)
    assert all(r["ok"] for r in rec["result"].values()), rec["result"]
    # Hildesheim-Konto: eigene Zugangsdaten an das LSF-Login, die LUH-Zugangsdaten nie
    assert rec["lsf_login"] == [(b["id"], "hil-user-B", "hil-pw-B")]
    # LUH-Konto: Login über die QIS-Startseite der LUH (nicht über das SSO von Hildesheim)
    assert rec["gotos"] == [(a["id"], qis.QIS_START)]


def test_concurrent_runs_keep_documents_per_account(hosted, monkeypatch):
    from conftest import legacy_vault

    from app import accounts, config, db
    a = accounts.register("qc@beispiel.de", PW, "luh")
    b = accounts.register("qd@beispiel.de", PW, "luh")
    for acc in (a, b):
        legacy_vault(acc["id"], {"STUDIP_USER": "u-" + acc["id"][:6], "STUDIP_PASSWORD": "pw-pw-pw-pw"})
    rec = _two_overlapping_runs(monkeypatch, a, b, docs=True)
    assert all(r["ok"] for r in rec["result"].values()), rec["result"]
    for acc in (a, b):
        tok = config.set_user_context(acc["id"], "luh")
        try:
            with db.cursor() as conn:
                rows = db.rows(conn, "SELECT * FROM qis_documents")
            base = config.data_dir() / "qis"
            assert len(rows) == 1 and rows[0]["title"] == "Studienbescheinigung"
            p = base / rows[0]["local_path"]
            assert p.parent == base and p.read_bytes() == b"%PDF-1.4 SECRET-" + acc["id"].encode()
        finally:
            config.reset_user_context(tok)


def test_use_profile_returns_independent_copies():
    from app import qis
    a, b = qis.use_profile("hildesheim"), qis.use_profile("luh")
    assert a is not b and a["key"] == "hildesheim" and b["key"] == "luh"
    assert qis._abs("rds?state=x", a) == "https://lsf.uni-hildesheim.de/qisserver/rds?state=x"
    assert qis._abs("rds?state=x", b).startswith(qis.QIS_BASE + "/")
    a["base"] = "https://geaendert.example"
    assert qis.PROFILES["hildesheim"]["base"] != "https://geaendert.example" and qis.use_profile("unbekannt")["key"] == "luh"


def test_doc_store_is_per_run(monkeypatch, tmp_path):
    from app import qis
    monkeypatch.setattr(qis, "DOC_DIR", tmp_path / "qis")
    s1, s2 = qis.DocStore(), qis.DocStore()
    assert qis._store_pdf(b"%PDF-1.4 eins", "Bescheinigung", s1) and qis._store_pdf(b"%PDF-1.4 eins", "Bescheinigung", s2)
    assert [d["local_path"] for d in s1.docs] == ["Bescheinigung.pdf"] == [d["local_path"] for d in s2.docs]
    assert s1.docs is not s2.docs and s1.hashes is not s2.hashes


# ---------------------------------------------------------------- Auslieferung nur aus dem eigenen Ordner

def test_document_route_serves_only_files_inside_own_qis_dir(hosted):
    from app import config, db
    (a, ha), (b, hb) = _register(hosted, "qe@beispiel.de"), _register(hosted, "qf@beispiel.de")
    paths = {}
    for acc in (a, b):
        d = config.user_data_dir(acc["id"], "luh") / "qis"
        d.mkdir(parents=True, exist_ok=True)
        (d / "Studienbescheinigung.pdf").write_bytes(b"%PDF-1.4 SECRET-" + acc["id"].encode())
        paths[acc["id"]] = d / "Studienbescheinigung.pdf"
    outside = config.user_data_dir(a["id"], "luh") / "geheim.pdf"           # im Kontoordner, aber nicht unter qis/
    outside.write_bytes(b"%PDF-1.4 AUSSERHALB")
    tok = config.set_user_context(a["id"], "luh")
    try:
        db.init_db()
        with db.cursor() as conn:
            for p in ("Studienbescheinigung.pdf",                               # neu: nur der Dateiname
                      str(paths[a["id"]]),                                      # alt: absoluter Pfad im eigenen Ordner
                      str(paths[b["id"]]),                                      # fremdes Konto
                      "../../../" + b["id"] + "/qis/Studienbescheinigung.pdf",  # Pfad nach oben
                      str(outside),                                             # eigener Ordner, aber nicht qis/
                      "/etc/hostname"):
                conn.execute("INSERT INTO qis_documents(title, local_path, fetched_at) VALUES ('t', ?, 'x')", (p,))
    finally:
        config.reset_user_context(tok)
    got = [asgi_call(hosted, "GET", f"/api/qis/documents/{i}", headers=ha) for i in range(1, 7)]
    expected = b"%PDF-1.4 SECRET-" + a["id"].encode()
    assert [g[0] for g in got] == [200, 200, 404, 404, 404, 404], [g[0] for g in got]
    assert got[0][2] == expected and got[1][2] == expected
    assert b"SECRET-" + b["id"].encode() not in b"".join(g[2] for g in got)
    assert asgi_call(hosted, "GET", "/api/qis/documents/99", headers=ha)[0] == 404
    assert asgi_call(hosted, "GET", "/api/qis/documents/1", headers=hb)[0] == 404, "Zeile 1 gehört nur dem Konto A"
