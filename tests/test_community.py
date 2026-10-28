"""Community-Dienst (Vertrag G4): Paketpruefung, Pseudonyme, Berechtigung nur fuer Dateien aus dem eigenen Abgleich,
Tarif Plus, veroeffentlichen/suchen/laden/zurueckziehen, melden (ab 3 verborgen), sperren, Moderation, Trennung je Konto."""
import json

import pytest
from conftest import asgi_call

FP_A = "a" * 64
FP_B = "b" * 64


@pytest.fixture
def hosted(app, monkeypatch, tmp_path):
    from app import accounts, community, config, vault
    monkeypatch.setattr(config, "MODE", "hosted")
    monkeypatch.setenv("LERNAPP_JOBS", "off")
    for p in (accounts.db_path(), community.db_path()):
        for suffix in ("", "-wal", "-shm"):
            p.with_name(p.name + suffix).unlink(missing_ok=True)
    import shutil
    shutil.rmtree(community.package_dir(), ignore_errors=True)
    vault.key_file().unlink(missing_ok=True)
    vault.reset_master()
    yield app
    for p in (accounts.db_path(), community.db_path()):
        p.unlink(missing_ok=True)
    shutil.rmtree(community.package_dir(), ignore_errors=True)
    vault.reset_master()


def _user(app, email, plus=True, admin=False, uni="luh", verified=True):
    from app import accounts
    st, _, b = asgi_call(app, "POST", "/api/account/register", body=json.dumps({"email": email, "password": "sehr-geheim-123", "university": uni}))
    assert st == 201, b
    d = json.loads(b)
    if verified:                                    # Veroeffentlichen verlangt eine bestaetigte Adresse (28.10.2026)
        accounts.mark_email_verified(d["user"]["id"])
    if plus:
        accounts.set_plan(d["user"]["id"], "plus")
    if admin:
        accounts.set_role(d["user"]["id"], "admin")
    return d["user"], {"Authorization": f"Bearer {d['token']}"}


def _own_file(app, headers, fingerprint, file_id="f-uni", from_uni=True):
    """Datei in der Datenbank des Kontos anlegen: aus dem Hochschul-Abgleich (download_url) oder eigenes Dokument."""
    from app import config, db
    # ueber die API gibt es keinen direkten Weg; der Kontext des Kontos wird wie im Dienst gesetzt
    st, _, b = asgi_call(app, "GET", "/api/account/me", headers=headers)
    uid = json.loads(b)["user"]["id"]
    uni = json.loads(b)["user"]["university"]
    t = config.set_user_context(uid, uni)
    try:
        db.init_db()
        with db.cursor() as conn:
            conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, active, created_at) VALUES ('c-uni', 'Mathe I', 'vorlesung', 1, '2026-10-26')")
            conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status, content_sha256, download_url) VALUES (?,?,?,?,?,?,?)",
                         (file_id, "c-uni" if from_uni else "__user__", "Blatt 3.pdf", "pdf", "neu", fingerprint,
                          "https://studip.example/file-refs/x/download" if from_uni else None))
    finally:
        config.reset_user_context(t)


def _j(res):
    st, _, b = res
    return st, (json.loads(b) if b else None)


# ---------------------------------------------------------------- Paketpruefung und Pseudonym

def test_validate_package_accepts_sample_and_rejects_broken():
    from app import community
    pkg = community.sample_package(FP_A, pages=3, page_count=10, display_name="Erika")
    info = community.validate_package(pkg)
    assert (info["fingerprint"], info["pages"], info["page_count"], info["display_name"]) == (FP_A, 3, 10, "Erika")
    def broken(mut):
        p = json.loads(json.dumps(community.sample_package(FP_A)))
        mut(p)
        with pytest.raises(community.CommunityError) as x:
            community.validate_package(p)
        return x.value.code
    assert broken(lambda p: p.update(format="x")) == "not_a_solution"
    assert broken(lambda p: p.update(formatVersion=2)) == "unsupported_version"
    assert broken(lambda p: p.update(formatVersion=1.0)) == "package_invalid"
    assert broken(lambda p: p.update(extra=1)) == "package_invalid"
    assert broken(lambda p: p["header"].update(fremd=1)) == "package_invalid"
    assert broken(lambda p: p["header"]["document"].update(sha256="zz")) == "package_invalid"
    assert broken(lambda p: p["header"]["contents"].update(pages=0)) == "package_invalid"
    assert broken(lambda p: p["header"]["encryption"].update(plaintextBytes=5)) == "package_invalid"
    assert broken(lambda p: p["header"]["encryption"].update(salt="QUJD")) == "package_invalid"
    assert broken(lambda p: p.update(ciphertext="nicht base64!")) == "package_invalid"
    assert broken(lambda p: p["header"].update(displayName="x" * 61)) == "package_invalid"
    assert broken(lambda p: p["header"].update(solutionId="keine-uuid")) == "package_invalid"
    with pytest.raises(community.CommunityError) as x:
        community.validate_package({**community.sample_package(FP_A), "ciphertext": "A" * (community.MAX_PACKAGE_BYTES + 4)})
    assert x.value.code == "too_large" and x.value.status == 413


def test_pseudonym_is_stable_and_not_reversible(hosted):
    from app import community
    a, b = community.pseudonym("a" * 32), community.pseudonym("b" * 32)
    assert a == community.pseudonym("a" * 32) and a != b and a.startswith("Studi-") and len(a) == 14
    assert "a" * 32 not in a


# ---------------------------------------------------------------- Berechtigung und Tarif

def test_requires_hosted_plan_and_own_file(app, hosted, monkeypatch):
    from app import community, config
    u_free, h_free = _user(hosted, "free@beispiel.de", plus=False)
    st, d = _j(asgi_call(hosted, "POST", "/api/community/solutions", headers=h_free, body=json.dumps({"package": community.sample_package(FP_A)})))
    assert (st, d["code"]) == (403, "plan_required")
    u, h = _user(hosted, "plus@beispiel.de")
    st, d = _j(asgi_call(hosted, "POST", "/api/community/solutions", headers=h, body=json.dumps({"package": community.sample_package(FP_A)})))
    assert (st, d["code"]) == (403, "file_not_owned"), "ohne die PDF aus dem eigenen Abgleich kein Veroeffentlichen"
    _own_file(hosted, h, FP_A, from_uni=False)
    st, d = _j(asgi_call(hosted, "POST", "/api/community/solutions", headers=h, body=json.dumps({"package": community.sample_package(FP_A)})))
    assert (st, d["code"]) == (403, "file_not_owned"), "eigene Dokumente (kein Hochschul-Abgleich) zaehlen nicht"
    _own_file(hosted, h, FP_A)
    st, d = _j(asgi_call(hosted, "GET", "/api/community/solutions?fingerprint=" + FP_B, headers=h))
    assert (st, d["code"]) == (403, "file_not_owned"), "auch Suchen nur fuer eigene Dateien"
    st, d = _j(asgi_call(hosted, "GET", "/api/community/solutions?fingerprint=kurz", headers=h))
    assert (st, d["code"]) == (400, "fingerprint_invalid")
    monkeypatch.setattr(config, "MODE", "local")
    st, d = _j(asgi_call(hosted, "GET", "/api/community/info"))
    # Einzelplatz (Windows-App) leitet an den Dienst weiter, ohne verbundenes Studora-Konto: 409 (app/service_link.py)
    assert (st, d["code"]) == (409, "not_linked")


def test_publish_requires_a_confirmed_email(app, hosted):
    """Schutz gegen Wegwerf-Konten (28.10.2026): Veroeffentlichen erst nach bestaetigter E-Mail-Adresse."""
    from app import accounts, community
    u, h = _user(hosted, "neu-unbestaetigt@beispiel.de", verified=False)
    st, d = _j(asgi_call(hosted, "POST", "/api/community/solutions", headers=h, body=json.dumps({"package": community.sample_package(FP_A)})))
    assert (st, d["code"]) == (403, "email_unverified")
    accounts.mark_email_verified(u["id"])
    st, d = _j(asgi_call(hosted, "POST", "/api/community/solutions", headers=h, body=json.dumps({"package": community.sample_package(FP_A)})))
    assert (st, d["code"]) == (403, "file_not_owned"), "danach gelten die bisherigen Regeln"


# ---------------------------------------------------------------- Ablauf: veroeffentlichen, finden, laden, zurueckziehen

def test_publish_find_download_withdraw(hosted):
    from app import community
    a, ha = _user(hosted, "a@beispiel.de")
    b, hb = _user(hosted, "b@beispiel.de")
    c, hc = _user(hosted, "c@beispiel.de", uni="hildesheim")
    _own_file(hosted, ha, FP_A); _own_file(hosted, hb, FP_A); _own_file(hosted, hc, FP_A)
    pkg = community.sample_package(FP_A, pages=2, display_name="Erika")
    st, d = _j(asgi_call(hosted, "POST", "/api/community/solutions", headers=ha, body=json.dumps({"package": pkg, "title": "Blatt 3"})))
    assert st == 201 and d["solution_id"] == pkg["header"]["solutionId"] and d["pseudonym"].startswith("Studi-") and not d["republished"]
    sid = d["solution_id"]
    st, d = _j(asgi_call(hosted, "POST", "/api/community/solutions", headers=ha, body=json.dumps({"package": pkg})))
    assert st == 201 and d["republished"], "gleiche Loesung erneut: aktualisiert, kein Doppel"
    st, d = _j(asgi_call(hosted, "POST", "/api/community/solutions", headers=hb, body=json.dumps({"package": pkg})))
    assert (st, d["code"]) == (409, "solution_exists")
    # B findet sie (gleiche PDF), C nicht (andere Hochschule)
    st, d = _j(asgi_call(hosted, "GET", "/api/community/solutions?fingerprint=" + FP_A, headers=hb))
    assert st == 200 and [s["solution_id"] for s in d["solutions"]] == [sid]
    s = d["solutions"][0]
    assert (s["display_name"], s["title"], s["pages"], s["page_count"], s["mine"], s["downloads"]) == ("Erika", "Blatt 3", 2, 12, False, 0)
    assert "author_id" not in s and a["id"] not in json.dumps(d)
    st, d = _j(asgi_call(hosted, "GET", "/api/community/solutions?fingerprint=" + FP_A, headers=hc))
    assert st == 200 and d["solutions"] == []
    st, d = _j(asgi_call(hosted, "GET", "/api/community/solutions?fingerprint=" + FP_A.upper(), headers=ha))
    assert d["solutions"][0]["mine"]
    # Laden: B bekommt das Paket unveraendert, Download zaehlt; A (eigene) zaehlt nicht
    st, d = _j(asgi_call(hosted, "GET", f"/api/community/solutions/{sid}", headers=hb))
    assert st == 200 and d["package"] == pkg and d["solution"]["solution_id"] == sid
    asgi_call(hosted, "GET", f"/api/community/solutions/{sid}", headers=ha)
    st, d = _j(asgi_call(hosted, "GET", "/api/community/solutions?fingerprint=" + FP_A, headers=hb))
    assert d["solutions"][0]["downloads"] == 1
    # Zurueckziehen: nur der Autor; danach weg fuer B, fuer A unter "mine" als withdrawn
    st, d = _j(asgi_call(hosted, "DELETE", f"/api/community/solutions/{sid}", headers=hb))
    assert (st, d["code"]) == (403, "not_owner")
    st, d = _j(asgi_call(hosted, "DELETE", f"/api/community/solutions/{sid}", headers=ha))
    assert st == 200 and d == {"withdrawn": True, "already": False}
    assert _j(asgi_call(hosted, "GET", "/api/community/solutions?fingerprint=" + FP_A, headers=hb))[1]["solutions"] == []
    assert _j(asgi_call(hosted, "GET", f"/api/community/solutions/{sid}", headers=hb))[0] == 404
    st, d = _j(asgi_call(hosted, "GET", "/api/community/mine", headers=ha))
    assert d["solutions"][0]["status"] == "withdrawn"
    assert not (community.package_dir() / f"{sid}.uniflowsolution").exists()
    assert _j(asgi_call(hosted, "DELETE", "/api/community/solutions/00000000-0000-4000-8000-000000000000", headers=ha))[0] == 404


# ---------------------------------------------------------------- Melden, Sperren, Moderation

def test_report_hides_after_three_and_block_hides_author(hosted):
    from app import community
    a, ha = _user(hosted, "autor@beispiel.de")
    _own_file(hosted, ha, FP_A)
    pkg = community.sample_package(FP_A)
    sid = _j(asgi_call(hosted, "POST", "/api/community/solutions", headers=ha, body=json.dumps({"package": pkg})))[1]["solution_id"]
    readers = []
    for i in range(3):
        u, h = _user(hosted, f"leser{i}@beispiel.de")
        _own_file(hosted, h, FP_A)
        readers.append(h)
    st, d = _j(asgi_call(hosted, "POST", f"/api/community/solutions/{sid}/report", headers=ha, body=json.dumps({"reason": "spam"})))
    assert (st, d["code"]) == (400, "own_solution")
    st, d = _j(asgi_call(hosted, "POST", f"/api/community/solutions/{sid}/report", headers=readers[0], body=json.dumps({"reason": "unsinn"})))
    assert (st, d["code"]) == (400, "reason_invalid")
    st, d = _j(asgi_call(hosted, "POST", f"/api/community/solutions/{sid}/report", headers=readers[0], body=json.dumps({"reason": "foreignMaterial", "note": "Folien drin"})))
    assert st == 200 and d == {"reported": True, "hidden": False, "reports": 1}
    st, d = _j(asgi_call(hosted, "POST", f"/api/community/solutions/{sid}/report", headers=readers[0], body=json.dumps({"reason": "spam"})))
    assert (st, d["code"]) == (409, "already_reported")
    assert _j(asgi_call(hosted, "GET", "/api/community/solutions?fingerprint=" + FP_A, headers=readers[1]))[1]["solutions"][0]["reported_by_me"] is False
    asgi_call(hosted, "POST", f"/api/community/solutions/{sid}/report", headers=readers[1], body=json.dumps({"reason": "gradedSubmission"}))
    st, d = _j(asgi_call(hosted, "POST", f"/api/community/solutions/{sid}/report", headers=readers[2], body=json.dumps({"reason": "offensive"})))
    assert d["hidden"] and d["reports"] == 3
    assert _j(asgi_call(hosted, "GET", "/api/community/solutions?fingerprint=" + FP_A, headers=readers[0]))[1]["solutions"] == []
    assert _j(asgi_call(hosted, "GET", f"/api/community/solutions/{sid}", headers=readers[0]))[0] == 404
    assert _j(asgi_call(hosted, "GET", f"/api/community/solutions/{sid}", headers=ha))[0] == 200, "der Autor sieht seine verborgene Loesung"
    st, d = _j(asgi_call(hosted, "POST", "/api/community/solutions", headers=ha, body=json.dumps({"package": pkg})))
    assert (st, d["code"]) == (403, "solution_blocked")
    # Sperren eines Autors fuer mich: zweite Loesung des Autors verschwindet nur fuer den Sperrenden
    pkg2 = community.sample_package(FP_A)
    sid2 = _j(asgi_call(hosted, "POST", "/api/community/solutions", headers=ha, body=json.dumps({"package": pkg2})))[1]["solution_id"]
    st, d = _j(asgi_call(hosted, "POST", f"/api/community/solutions/{sid2}/block", headers=readers[0]))
    assert st == 200 and d["blocked"].startswith("Studi-")
    assert _j(asgi_call(hosted, "GET", "/api/community/solutions?fingerprint=" + FP_A, headers=readers[0]))[1]["solutions"] == []
    assert [s["solution_id"] for s in _j(asgi_call(hosted, "GET", "/api/community/solutions?fingerprint=" + FP_A, headers=readers[1]))[1]["solutions"]] == [sid2]
    assert _j(asgi_call(hosted, "GET", "/api/community/blocks", headers=readers[0]))[1] == {"blocked": [d["blocked"]]}
    st, d2 = _j(asgi_call(hosted, "DELETE", f"/api/community/blocks/{d['blocked']}", headers=readers[0]))
    assert st == 200 and [s["solution_id"] for s in _j(asgi_call(hosted, "GET", "/api/community/solutions?fingerprint=" + FP_A, headers=readers[0]))[1]["solutions"]] == [sid2]
    assert _j(asgi_call(hosted, "POST", f"/api/community/solutions/{sid2}/block", headers=ha))[1]["code"] == "own_solution"


def test_moderation_restore_remove_and_ban(hosted):
    from app import community
    a, ha = _user(hosted, "autor@beispiel.de")
    _own_file(hosted, ha, FP_A)
    sid = _j(asgi_call(hosted, "POST", "/api/community/solutions", headers=ha, body=json.dumps({"package": community.sample_package(FP_A)})))[1]["solution_id"]
    leser, hl = _user(hosted, "leser@beispiel.de")
    _own_file(hosted, hl, FP_A)
    asgi_call(hosted, "POST", f"/api/community/solutions/{sid}/report", headers=hl, body=json.dumps({"reason": "spam", "note": "x"}))
    assert _j(asgi_call(hosted, "GET", "/api/community/moderation", headers=hl))[1]["code"] == "forbidden"
    admin, hadm = _user(hosted, "admin@beispiel.de", admin=True)
    st, d = _j(asgi_call(hosted, "GET", "/api/community/moderation", headers=hadm))
    assert st == 200 and d["solutions"][0]["solution_id"] == sid and d["solutions"][0]["reports"][0]["reason"] == "spam"
    st, d = _j(asgi_call(hosted, "POST", f"/api/community/solutions/{sid}/moderate", headers=hadm, body=json.dumps({"action": "hide", "reason": "pruefen"})))
    assert st == 200 and d["solution"]["status"] == "hidden"
    assert _j(asgi_call(hosted, "GET", "/api/community/solutions?fingerprint=" + FP_A, headers=hl))[1]["solutions"] == []
    st, d = _j(asgi_call(hosted, "POST", f"/api/community/solutions/{sid}/moderate", headers=hadm, body=json.dumps({"action": "restore"})))
    assert d["solution"]["status"] == "active" and d["solution"]["reported_by_me"] is False
    assert len(_j(asgi_call(hosted, "GET", "/api/community/solutions?fingerprint=" + FP_A, headers=hl))[1]["solutions"]) == 1
    st, d = _j(asgi_call(hosted, "POST", f"/api/community/solutions/{sid}/moderate", headers=hadm, body=json.dumps({"action": "ban_author", "reason": "wiederholt"})))
    assert d["solution"]["status"] == "removed"
    assert not (community.package_dir() / f"{sid}.uniflowsolution").exists()
    st, d = _j(asgi_call(hosted, "POST", "/api/community/solutions", headers=ha, body=json.dumps({"package": community.sample_package(FP_A)})))
    assert (st, d["code"]) == (403, "author_banned")
    st, d = _j(asgi_call(hosted, "POST", f"/api/community/solutions/{sid}/moderate", headers=hadm, body=json.dumps({"action": "unban_author"})))
    assert st == 200
    assert _j(asgi_call(hosted, "POST", "/api/community/solutions", headers=ha, body=json.dumps({"package": community.sample_package(FP_A)})))[0] == 201
    assert _j(asgi_call(hosted, "POST", f"/api/community/solutions/{sid}/moderate", headers=hadm, body=json.dumps({"action": "x"})))[1]["code"] == "action_invalid"
    st, d = _j(asgi_call(hosted, "GET", "/api/community/info", headers=hadm))
    assert st == 200 and d["admin"] and d["plan_ok"] and d["reasons"] == list(community.REPORT_REASONS)


def test_accounts_cli_plan_and_role(hosted, capsys):
    from app import accounts
    u = accounts.register("cli@beispiel.de", "sehr-geheim-123", "luh")
    assert accounts.main(["plan", "cli@beispiel.de", "plus", "2027-03-31"]) == 0
    assert accounts.main(["role", "cli@beispiel.de", "admin"]) == 0
    out = accounts.get_user(u["id"])
    assert (out["plan"], out["plan_until"], out["role"]) == ("plus", "2027-03-31", "admin")
    assert accounts.main(["plan", "niemand@beispiel.de", "plus"]) == 1


# ---------------------------------------------------------------- Vertrag G4: Fixture entspricht der Referenz

def test_community_contract_matches_python(hosted, monkeypatch):
    import importlib.util
    from pathlib import Path
    root = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location("gen_community_fixture", root / "tools" / "gen-community-fixture.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    built = mod.build()
    stored = json.loads((root / "packages" / "shared-contracts" / "fixtures" / "community" / "contract.json").read_text(encoding="utf-8"))
    assert built["rules"] == stored["rules"]
    assert built["errors"] == stored["errors"]
    assert built["package-checks"] == stored["package-checks"]
    assert [(f["step"], f["status"]) for f in built["flows"]] == [(f["step"], f["status"]) for f in stored["flows"]]
    assert built["flows"] == stored["flows"], "python tools/gen-community-fixture.py neu ausfuehren"
    text = json.dumps(stored)
    assert "Bearer" not in text and "Studi-" not in text.replace("<pseudonym>", "").replace("Studi-<8 hex>", "")
    assert "sehr-geheim" not in text.replace('"password": "sehr-geheim-123"', ""), "nur das Beispiel-Passwort der Anfrage"
