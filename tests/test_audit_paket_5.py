"""Audit 08.11.2026, Paket 5 (app/community.py: publish ... delete_comment) samt Community-Zeilen aus Paket 6/7
(report_comment, leaderboard, info, _can_read/_can_comment). Je Befund erst der Nachweis am Code, dann der Fix;
Bericht in docs/audit/AUDIT-2026-11-08-PAKET-5.md."""
import json
import math
import sqlite3
import threading
import time
import uuid
from contextlib import contextmanager
from pathlib import Path

import pytest
from conftest import asgi_call
from test_community import _user, hosted  # noqa: F401
from test_community_groups import FP, KURS, call, member, package

PKG = ".uniflowsolution"


def _pkg(sid=None, fp=FP, pages=2):
    from app import community
    return community.sample_package(fp, pages=pages, solution_id=sid, key_material="community-secret")


def _publish(app, h, pkg, title="Blatt 3"):
    st, d = call(app, "POST", "/solutions", h, {"package": pkg, "title": title, "community_key": KURS})
    assert st == 201, d
    return pkg["header"]["solutionId"]


def _fresh(u):
    """Konto mit Tarif, Rolle und bestaetigter Adresse, wie es die Middleware an die Endpunkte gibt (test_community._user
    setzt diese erst nach der Registrierung)."""
    from app import accounts
    return accounts.get_user(u["id"])


def _member_user(app, email, **kw):
    """Wie test_community_groups.member, liefert dazu das Konto (fuer direkte Aufrufe der Modulfunktionen)."""
    u, h = _user(app, email, **kw)
    assert call(app, "POST", "/claims", h, {"fingerprints": [], "course_keys": [KURS]})[1]["courses"] == 1
    assert call(app, "POST", f"/communities/{KURS}/join", h, {"kind": "course"})[0] == 200
    return _fresh(u), h


def _file(sid):
    from app import community
    return community.package_dir() / f"{sid}{PKG}"


def _row(sid):
    from app import community
    with community.cursor() as conn:
        return conn.execute("SELECT * FROM solutions WHERE id=?", (sid,)).fetchone()


def _leftovers():
    from app import community
    return sorted(p.name for p in community.package_dir().iterdir() if not p.name.endswith(PKG))


class _FailingConn:
    """Verbindung, deren execute bei einem bestimmten SQL-Stueck wie eine kaputte Platte abbricht."""

    def __init__(self, conn, needle):
        self._conn, self._needle = conn, needle

    def execute(self, sql, *a):
        if self._needle in sql:
            raise sqlite3.OperationalError("disk I/O error")
        return self._conn.execute(sql, *a)

    def __getattr__(self, name):
        return getattr(self._conn, name)


def _failing_cursor(monkeypatch, needle):
    from app import community
    real = community.cursor

    @contextmanager
    def wrapped():
        with real() as conn:
            yield _FailingConn(conn, needle)
    monkeypatch.setattr(community, "cursor", wrapped)
    return real


# ---------------------------------------------------------------- P5-01 publish: Datei und Datenbank zusammen

def test_p5_01_db_failure_after_writing_leaves_no_orphan_package(hosted, monkeypatch):  # noqa: F811
    """Bricht die Datenbank beim Eintragen ab, darf kein Paket ohne Zeile auf der Platte zurueckbleiben (sonst
    Leiche, die weder Zurueckziehen noch Loeschen je entfernt); die Wiederholung veroeffentlicht normal."""
    from app import community, config
    autor, ha = _member_user(hosted, "autor@beispiel.de")
    pkg = _pkg()
    sid = pkg["header"]["solutionId"]
    real = _failing_cursor(monkeypatch, "INSERT INTO solutions")
    with pytest.raises(sqlite3.OperationalError):
        community.publish(autor, config.university(), pkg, "Blatt", KURS)
    monkeypatch.setattr(community, "cursor", real)
    assert _row(sid) is None
    assert not _file(sid).exists(), "Paketdatei ohne Datenbankzeile"
    assert _leftovers() == [], "keine halben Dateien"
    assert _publish(hosted, ha, pkg) == sid
    assert _file(sid).exists() and _row(sid)["status"] == "active"


def test_p5_01_disk_failure_while_writing_leaves_no_row(hosted, monkeypatch):  # noqa: F811
    from app import community, config
    autor, ha = _member_user(hosted, "autor@beispiel.de")
    pkg = _pkg()
    sid = pkg["header"]["solutionId"]
    real = Path.write_text

    def full(self, *a, **k):
        if self.parent == community.package_dir():
            raise OSError(28, "No space left on device")
        return real(self, *a, **k)
    monkeypatch.setattr(Path, "write_text", full)
    with pytest.raises(OSError):
        community.publish(autor, config.university(), pkg, "Blatt", KURS)
    monkeypatch.setattr(Path, "write_text", real)
    assert _row(sid) is None and not _file(sid).exists() and _leftovers() == []
    assert _publish(hosted, ha, pkg) == sid


def test_p5_01_republish_never_writes_the_package_in_place(hosted, monkeypatch):  # noqa: F811
    """Erneutes Veroeffentlichen derselben Loesung: ein Leser, der gerade laedt, bekommt entweder das alte oder das
    neue Paket, nie ein halb geschriebenes (Schreiben neben die Datei, dann atomar ersetzen)."""
    from app import community
    autor, ha = _member_user(hosted, "autor@beispiel.de")
    leser, hl = _member_user(hosted, "leser@beispiel.de")
    pkg = _pkg()
    sid = _publish(hosted, ha, pkg)
    seen = {}
    real = Path.write_text

    def spy(self, *a, **k):
        if self.parent == community.package_dir():
            seen[self.name] = True
            # mitten im Schreiben laedt ein Leser: das gespeicherte Paket muss noch vollstaendig das alte sein
            assert call(hosted, "GET", f"/solutions/{sid}", hl)[1]["package"] == pkg
        return real(self, *a, **k)
    monkeypatch.setattr(Path, "write_text", spy)
    neu = _pkg(sid=sid, pages=4)
    st, d = call(hosted, "POST", "/solutions", ha, {"package": neu, "title": "Blatt 3", "community_key": KURS})
    assert (st, d["republished"]) == (201, True)
    monkeypatch.setattr(Path, "write_text", real)
    assert seen and f"{sid}{PKG}" not in seen, f"direkt in die Zieldatei geschrieben: {sorted(seen)}"
    assert call(hosted, "GET", f"/solutions/{sid}", hl)[1]["package"] == neu
    assert _leftovers() == []


# ---------------------------------------------------------------- P5-02 update: gemeinsamer Temp-Name

def test_p5_02_two_updates_of_the_same_solution_at_once_both_succeed(hosted, monkeypatch):  # noqa: F811
    """Zwei gleichzeitige PUT desselben Autors: bisher teilten sie den Namen `<id>.uniflowsolution.neu`; der zweite
    ueberschrieb die Temp-Datei des ersten und benannte sie um, der erste fand seine Temp-Datei nicht mehr (500) oder
    ein halb geschriebenes Paket landete im Ziel. Nachgestellt: waehrend der erste seine Temp-Datei schreibt, laeuft
    der zweite komplett durch."""
    from app import community, config
    autor, ha = _member_user(hosted, "autor@beispiel.de")
    first = _pkg()
    sid = _publish(hosted, ha, first)
    a, b = _pkg(sid=sid, pages=5), _pkg(sid=sid, pages=7)
    real = Path.write_text
    state = {"nested": False}

    def interleaved(self, *args, **kw):
        out = real(self, *args, **kw)
        if self.parent == community.package_dir() and not state["nested"]:
            state["nested"] = True
            r = community.update(autor, config.university(), sid, b, None, KURS)        # der Zweite ueberholt
            assert r["pages"] == 7
        return out
    monkeypatch.setattr(Path, "write_text", interleaved)
    r = community.update(autor, config.university(), sid, a, None, KURS)
    monkeypatch.setattr(Path, "write_text", real)
    assert state["nested"] and r["pages"] == 5
    stored = json.loads(_file(sid).read_text(encoding="utf-8"))
    assert stored in (a, b), "halb geschriebenes oder fremdes Paket"
    assert _row(sid)["pages"] == stored["header"]["contents"]["pages"], "Datenbank und Datei passen zusammen"
    assert _leftovers() == [], "Temp-Dateien bleiben nicht liegen"


def test_p5_02_update_after_moderation_removal_does_not_resurrect_the_package(hosted, monkeypatch):  # noqa: F811
    """Entfernt die Moderation die Loesung, waehrend der Autor gerade aktualisiert (Pruefung bestanden, Paket noch
    nicht geschrieben), darf danach kein Paket auf der Platte liegen und die Loesung bleibt entfernt."""
    from app import community, config
    autor, ha = _member_user(hosted, "autor@beispiel.de")
    admin = _fresh(_user(hosted, "admin@beispiel.de", admin=True)[0])
    sid = _publish(hosted, ha, _pkg())
    real = Path.write_text
    state = {"done": False}

    def moderation_in_between(self, *args, **kw):
        if self.parent == community.package_dir() and not state["done"]:
            state["done"] = True
            community.moderate(admin, sid, "remove", "Urheberrecht")
        return real(self, *args, **kw)
    monkeypatch.setattr(Path, "write_text", moderation_in_between)
    with pytest.raises(community.CommunityError) as e:
        community.update(autor, config.university(), sid, _pkg(sid=sid, pages=9), None, KURS)
    monkeypatch.setattr(Path, "write_text", real)
    assert state["done"] and e.value.code == "solution_blocked"
    assert _row(sid)["status"] == "removed" and _row(sid)["pages"] == 2
    assert not _file(sid).exists() and _leftovers() == []


# ---------------------------------------------------------------- P5-03 moderate: restore nach remove

def test_p5_03_restore_after_remove_does_not_offer_a_package_that_is_gone(hosted):  # noqa: F811
    """`remove` loescht die Paketdatei; `restore` setzte die Loesung trotzdem auf aktiv: gelistet, aber Laden 404.
    Entscheidung: ohne Paket wird sie zurueckgezogen (wie vom Autor), der Autor kann sie erneut veroeffentlichen."""
    autor, ha = _member_user(hosted, "autor@beispiel.de")
    leser, hl = _member_user(hosted, "leser@beispiel.de")
    admin, hadm = _user(hosted, "admin@beispiel.de", admin=True)
    pkg = _pkg()
    sid = _publish(hosted, ha, pkg)
    assert call(hosted, "POST", f"/solutions/{sid}/moderate", hadm, {"action": "remove", "reason": "x"})[1]["solution"]["status"] == "removed"
    assert not _file(sid).exists()
    st, d = call(hosted, "POST", f"/solutions/{sid}/moderate", hadm, {"action": "restore"})
    assert st == 200
    assert d["solution"]["status"] != "active", "aktiv ohne Paket"
    assert d["solution"]["status"] == "withdrawn" and d.get("package_gone") is True
    assert call(hosted, "GET", f"/communities/{KURS}/solutions", hl)[1]["solutions"] == []
    assert call(hosted, "GET", f"/solutions/{sid}", hl)[0] == 404
    # der Autor veroeffentlicht dieselbe Loesung erneut, danach ist sie wieder ladbar
    st, d = call(hosted, "POST", "/solutions", ha, {"package": pkg, "title": "Blatt 3", "community_key": KURS})
    assert (st, d["republished"]) == (201, True)
    assert call(hosted, "GET", f"/solutions/{sid}", hl)[1]["package"] == pkg


def test_p5_03_restore_after_hide_keeps_the_package_and_works(hosted):  # noqa: F811
    autor, ha = _member_user(hosted, "autor@beispiel.de")
    leser, hl = _member_user(hosted, "leser@beispiel.de")
    admin, hadm = _user(hosted, "admin@beispiel.de", admin=True)
    pkg = _pkg()
    sid = _publish(hosted, ha, pkg)
    assert call(hosted, "POST", f"/solutions/{sid}/moderate", hadm, {"action": "hide", "reason": "pruefen"})[1]["solution"]["status"] == "hidden"
    assert _file(sid).exists()
    st, d = call(hosted, "POST", f"/solutions/{sid}/moderate", hadm, {"action": "restore"})
    assert (st, d["solution"]["status"], "package_gone" in d) == (200, "active", False)
    assert call(hosted, "GET", f"/solutions/{sid}", hl)[1]["package"] == pkg


# ---------------------------------------------------------------- P5-04 get_package_raw: Downloadzaehler

def test_p5_04_missing_file_does_not_count_as_download(hosted):  # noqa: F811
    """Die Erhoehung steht vor der Dateipruefung, aber in derselben Transaktion: der Fehler verwirft sie (kein Commit
    im Fehlerfall, community.cursor). Befund widerlegt, Verhalten festgenagelt."""
    autor, ha = _member_user(hosted, "autor@beispiel.de")
    leser, hl = _member_user(hosted, "leser@beispiel.de")
    sid = _publish(hosted, ha, _pkg())
    assert call(hosted, "GET", f"/solutions/{sid}", hl)[0] == 200
    assert call(hosted, "GET", f"/solutions/{sid}", ha)[0] == 200, "eigene Loesung zaehlt nicht"
    assert _row(sid)["downloads"] == 1
    _file(sid).unlink()
    st, d = call(hosted, "GET", f"/solutions/{sid}", hl)
    assert (st, d["code"]) == (404, "not_found")
    assert _row(sid)["downloads"] == 1, "fehlende Datei als Download gezaehlt"


def test_p5_04_parallel_downloads_count_each(hosted):  # noqa: F811
    from app import community
    autor, ha = _member_user(hosted, "autor@beispiel.de")
    leser, hl = _member_user(hosted, "leser@beispiel.de")
    sid = _publish(hosted, ha, _pkg())
    errors = []

    def dl():
        try:
            for _ in range(5):
                community.get_package_raw(leser, sid)
        except Exception as e:                                     # noqa: BLE001
            errors.append(repr(e))
    ts = [threading.Thread(target=dl) for _ in range(4)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    assert errors == []
    assert _row(sid)["downloads"] == 20


# ---------------------------------------------------------------- P5-05 withdraw_all / forget_author: Wiederholung

def _fail_first_unlink(monkeypatch):
    real = Path.unlink
    state = {"failed": False}

    def flaky(self, missing_ok=False):
        if self.name.endswith(PKG) and not state["failed"]:
            state["failed"] = True
            raise PermissionError(13, "Permission denied")
        return real(self, missing_ok=missing_ok)
    monkeypatch.setattr(Path, "unlink", flaky)
    return state, real


def test_p5_05_withdraw_all_retry_after_file_failure_finishes_the_job(hosted, monkeypatch):  # noqa: F811
    """Scheitert das Loeschen einer Paketdatei, war die Datenbank schon festgeschrieben: die Wiederholung fand keine
    Loesung mehr (0) und liess die Pakete liegen. Jetzt gehoert das Loeschen zur Transaktion: die Wiederholung
    erledigt alles."""
    from app import community
    autor, ha = _member_user(hosted, "autor@beispiel.de")
    s1, s2 = _publish(hosted, ha, _pkg()), _publish(hosted, ha, _pkg(fp="e" * 64))
    state, real = _fail_first_unlink(monkeypatch)
    with pytest.raises(PermissionError):
        community.withdraw_all(autor["id"], "account_deleted")
    monkeypatch.setattr(Path, "unlink", real)
    assert state["failed"]
    n = community.withdraw_all(autor["id"], "account_deleted")
    assert n == 2, "Wiederholung zieht alles zurueck"
    assert {_row(s)["status"] for s in (s1, s2)} == {"withdrawn"}
    assert not _file(s1).exists() and not _file(s2).exists()
    assert community.withdraw_all(autor["id"], "account_deleted") == 0


def test_p5_05_forget_author_retry_after_file_failure_finishes_the_job(hosted, monkeypatch):  # noqa: F811
    from app import community
    autor, ha = _member_user(hosted, "autor@beispiel.de")
    leser, hl = _member_user(hosted, "leser@beispiel.de")
    s1, s2 = _publish(hosted, ha, _pkg()), _publish(hosted, ha, _pkg(fp="e" * 64))
    assert call(hosted, "POST", f"/solutions/{s1}/like", hl)[0] == 200
    assert call(hosted, "POST", f"/solutions/{s1}/comments", hl, {"text": "Danke"})[0] == 201
    state, real = _fail_first_unlink(monkeypatch)
    with pytest.raises(PermissionError):
        community.forget_author(autor["id"])
    monkeypatch.setattr(Path, "unlink", real)
    assert state["failed"]
    assert community.forget_author(autor["id"]) == 2, "Wiederholung entfernt alles"
    with community.cursor() as conn:
        for t in ("solutions", "likes", "comments"):
            assert conn.execute(f"SELECT COUNT(*) FROM {t} WHERE solution_id=? OR solution_id=?" if t != "solutions"
                                else "SELECT COUNT(*) FROM solutions WHERE id=? OR id=?", (s1, s2)).fetchone()[0] == 0
    assert not _file(s1).exists() and not _file(s2).exists()
    assert community.forget_author(autor["id"]) == 0


def test_p5_05_forget_author_removes_packages_left_by_an_interrupted_withdraw(hosted, monkeypatch):  # noqa: F811
    """Konto geloescht: withdraw_all (sofort) und forget_author (nach 30 Tagen) hintereinander; ein nach dem Rueckzug
    liegen gebliebenes Paket (z. B. Prozess weg zwischen Commit und Loeschen) raeumt forget_author ab."""
    from app import community
    autor, ha = _member_user(hosted, "autor@beispiel.de")
    sid = _publish(hosted, ha, _pkg())
    assert community.withdraw_all(autor["id"], "account_deleted") == 1
    _file(sid).write_text("{}", encoding="utf-8")                    # Leiche nachgestellt
    assert community.forget_author(autor["id"]) == 1
    assert not _file(sid).exists() and _row(sid) is None


# ---------------------------------------------------------------- P5-06 comments: viele Kommentare

def test_p5_06_comments_with_1200_entries_stay_fast(hosted):  # noqa: F811
    from app import community
    autor, ha = _member_user(hosted, "autor@beispiel.de")
    leser, hl = _member_user(hosted, "leser@beispiel.de")
    sid = _publish(hosted, ha, _pkg())
    with community.cursor() as conn:
        rows, tops = [], []
        for i in range(600):
            cid = str(uuid.uuid4())
            tops.append(cid)
            rows.append((cid, sid, leser["id"], "Studi-leser", None, "p1", 0.5, 0.5, f"Kommentar {i}", f"2026-11-01T10:{i // 60:02d}:{i % 60:02d}Z"))
        for i, parent in enumerate(tops):
            rows.append((str(uuid.uuid4()), sid, autor["id"], "Studi-autor", parent, "p1", 0.5, 0.5, f"Antwort {i}", "2026-11-02T00:00:00Z"))
        conn.executemany("""INSERT INTO comments(id, solution_id, author_id, pseudonym, parent_id, page_key, anchor_x, anchor_y, text, created_at)
                            VALUES (?,?,?,?,?,?,?,?,?,?)""", rows)
    t0 = time.perf_counter()
    out = community.comments(leser, sid)
    dt = time.perf_counter() - t0
    print(f"\nP5-06 comments(): {len(out)} Kommentare in {dt * 1000:.0f} ms")
    assert len(out) == 1200
    assert [c["parent_id"] is None for c in out[:2]] == [True, False], "Antwort direkt unter ihrem Kommentar"
    assert dt < 1.0, f"{dt:.2f} s"


# ---------------------------------------------------------------- P5-07 _anchor: NaN / Infinity

@pytest.mark.parametrize("x", ["NaN", "Infinity", "-Infinity", "1e400"])
def test_p5_07_non_finite_anchor_is_rejected_over_the_api(hosted, x):  # noqa: F811
    """Pythons json.loads nimmt NaN/Infinity an (kein gueltiges JSON, aber Starlette reicht es durch). Der Vergleich
    0 <= x <= 1 ist fuer NaN und Unendlich falsch: anchor_invalid. Widerlegt, festgenagelt."""
    autor, ha = _member_user(hosted, "autor@beispiel.de")
    leser, hl = _member_user(hosted, "leser@beispiel.de")
    sid = _publish(hosted, ha, _pkg())
    body = '{"text": "hier", "page_key": "p1", "anchor": {"x": %s, "y": 0.5}}' % x
    st, _, b = asgi_call(hosted, "POST", f"/api/community/solutions/{sid}/comments", body=body, headers=hl)
    d = json.loads(b)
    assert (st, d["code"]) == (400, "anchor_invalid"), d
    assert call(hosted, "GET", f"/solutions/{sid}/comments", hl)[1]["comments"] == []


def test_p5_07_anchor_edge_values():
    from app import community
    assert community._anchor("p1", {"x": 0, "y": 1}) == ("p1", 0.0, 1.0)
    assert community._anchor(None, None) == (None, None, None)
    for bad in ({"x": math.nan, "y": 0.5}, {"x": math.inf, "y": 0.5}, {"x": 0.5, "y": -math.inf}, {"x": "a", "y": 0},
                {"x": None, "y": 0}, [0.5, 0.5], "0.5", {"x": 1.0001, "y": 0}):
        with pytest.raises(community.CommunityError) as e:
            community._anchor("p1", bad)
        assert e.value.code == "anchor_invalid"
    with pytest.raises(community.CommunityError):
        community._anchor(None, {"x": 0.5, "y": 0.5})            # Stelle ohne Seite


# ---------------------------------------------------------------- Paket 6/7: report_comment, leaderboard, info, Rechte

def _comment(app, sid, h, text="Frage"):
    st, d = call(app, "POST", f"/solutions/{sid}/comments", h, {"text": text})
    assert st == 201, d
    return d["id"]


def test_p7_08_three_reports_hide_a_comment_and_repeat_is_refused(hosted):  # noqa: F811
    autor, ha = _member_user(hosted, "autor@beispiel.de")
    leser, hl = _member_user(hosted, "leser@beispiel.de")
    sid = _publish(hosted, ha, _pkg())
    cid = _comment(hosted, sid, hl)
    melder = [_member_user(hosted, f"m{i}@beispiel.de")[1] for i in range(3)]
    assert call(hosted, "POST", f"/comments/{cid}/report", hl, {"reason": "spam"})[1]["code"] == "own_comment"
    assert call(hosted, "POST", f"/comments/{cid}/report", melder[0], {"reason": "quatsch"})[1]["code"] == "reason_invalid"
    r1 = call(hosted, "POST", f"/comments/{cid}/report", melder[0], {"reason": "spam"})[1]
    assert (r1["hidden"], r1["reports"]) == (False, 1)
    assert call(hosted, "POST", f"/comments/{cid}/report", melder[0], {"reason": "spam"})[0] == 409
    assert call(hosted, "POST", f"/comments/{cid}/report", melder[1], {"reason": "spam"})[1]["hidden"] is False
    r3 = call(hosted, "POST", f"/comments/{cid}/report", melder[2], {"reason": "spam"})[1]
    assert (r3["hidden"], r3["reports"]) == (True, 3)
    assert call(hosted, "GET", f"/solutions/{sid}/comments", ha)[1]["comments"] == [], "verborgen fuer alle"
    assert call(hosted, "POST", f"/comments/{cid}/report", ha, {"reason": "spam"})[0] == 404, "verborgen = nicht mehr meldbar"
    assert call(hosted, "POST", f"/solutions/{sid}/comments", ha, {"text": "re", "parent_id": cid})[1]["code"] == "parent_invalid"


def test_p7_08_parallel_reports_end_consistent(hosted):  # noqa: F811
    from app import community
    autor, ha = _member_user(hosted, "autor@beispiel.de")
    leser, hl = _member_user(hosted, "leser@beispiel.de")
    sid = _publish(hosted, ha, _pkg())
    cid = _comment(hosted, sid, hl)
    melder = [_member_user(hosted, f"m{i}@beispiel.de")[0] for i in range(4)]
    results, errors = [], []
    start = threading.Barrier(4)

    def rep(u):
        try:
            start.wait()
            results.append(community.report_comment(u, cid, "spam"))
        except Exception as e:                                     # noqa: BLE001
            errors.append(repr(e))
    ts = [threading.Thread(target=rep, args=(u,)) for u in melder]
    [t.start() for t in ts]
    [t.join() for t in ts]
    with community.cursor() as conn:
        c = conn.execute("SELECT status, report_count FROM comments WHERE id=?", (cid,)).fetchone()
        n = conn.execute("SELECT COUNT(*) FROM comment_reports WHERE comment_id=?", (cid,)).fetchone()[0]
    # Nach der dritten Meldung ist der Kommentar ausgeblendet; eine vierte, die erst danach liest, findet ihn nicht
    # mehr (gewollt: ausgeblendete Kommentare sind nicht meldbar). Jeder andere Fehler, z. B. 'database is locked'
    # (08.11.2026 unter Last gefunden, db.schema_once), laesst den Test scheitern.
    assert all("Kommentar nicht gefunden" in e for e in errors), errors
    assert len(results) + len(errors) == 4 and len(results) >= 3, (results, errors)
    assert (c["status"], c["report_count"], n) == ("hidden", len(results), len(results))
    assert sorted(r["reports"] for r in results) == list(range(1, len(results) + 1)), "jede Meldung sieht ihren eigenen Stand"


def test_p6_152_leaderboard_with_10000_solutions_and_100000_likes(hosted):  # noqa: F811
    from app import community
    admin, hadm = _user(hosted, "admin@beispiel.de", admin=True)
    admin = _fresh(admin)
    authors = [f"a{i:04d}" for i in range(500)]
    with community.cursor() as conn:
        sols = [(f"{i:08x}-0000-4000-8000-000000000000", "f" * 64, "luh", authors[i % 500], f"Studi-{i % 500:04d}", "x.pdf",
                 "2026-11-01T00:00:00Z", f"2026-11-0{1 + i % 8}T00:00:00Z", 12, 2, 100, "active", i % 7, KURS) for i in range(10_000)]
        conn.executemany("""INSERT INTO solutions(id, fingerprint, university, author_id, pseudonym, display_name, created_at,
                            published_at, page_count, pages, size, status, downloads, community_key) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""", sols)
        likes = [(sols[i % 10_000][0], f"u{i // 10_000}-{i % 10_000}", "2026-11-02T00:00:00Z") for i in range(100_000)]
        conn.executemany("INSERT INTO likes(solution_id, user_id, created_at) VALUES (?,?,?)", likes)
        comments = [(str(uuid.uuid4()), sols[i][0], "leser", "Studi-l", None, None, None, None, "x", "2026-11-03T00:00:00Z") for i in range(5_000)]
        conn.executemany("""INSERT INTO comments(id, solution_id, author_id, pseudonym, parent_id, page_key, anchor_x, anchor_y, text, created_at)
                            VALUES (?,?,?,?,?,?,?,?,?,?)""", comments)
    t0 = time.perf_counter()
    rows = community.leaderboard(admin, 50)
    dt = time.perf_counter() - t0
    print(f"\nP6-152 leaderboard(): 10.000 Loesungen, 100.000 Likes, 500 Autoren in {dt * 1000:.0f} ms")
    assert len(rows) == 50 and rows[0]["rank"] == 1 and rows[0]["likes"] == 200 and rows[0]["solutions"] == 20
    assert rows[0]["account_status"] == "deleted" and rows[0]["email"] is None, "unbekanntes Konto ohne E-Mail"
    assert dt < 1.0, f"{dt:.2f} s"
    st, d = call(hosted, "GET", "/admin/leaderboard?limit=5", hadm)
    assert st == 200 and len(d["authors"]) == 5


def test_p7_08_read_and_comment_rights_are_enforced_in_the_endpoints(hosted):  # noqa: F811
    """`_can_read`/`_can_comment` sind nicht nur Anzeige in `info`: ohne Plus (can_read_community) antworten die
    Lese-Endpunkte 403 plan_required; Kommentieren prueft can_write_community_comments zusaetzlich in add_comment."""
    autor, ha = _member_user(hosted, "autor@beispiel.de")
    sid = _publish(hosted, ha, _pkg())
    frei, hf = _user(hosted, "frei@beispiel.de", plus=False)
    st, d = call(hosted, "GET", "/info", hf)
    assert st == 200 and (d["can_read"], d["can_comment"], d["can_share"]) == (False, False, False)
    assert set(d) <= {"enabled", "plan_required", "plan_ok", "can_read", "can_share", "reasons", "reports_to_hide", "format", "format_version",
                      "max_package_bytes", "pseudonym", "admin", "can_comment", "max_comment"}, "keine weiteren (vertraulichen) Felder"
    for method, path, body in (("GET", f"/solutions?fingerprint={FP}", None), ("GET", f"/communities/{KURS}/solutions", None),
                               ("GET", f"/solutions/{sid}", None), ("GET", f"/solutions/{sid}/comments", None),
                               ("POST", f"/solutions/{sid}/comments", {"text": "hi"}), ("POST", f"/solutions/{sid}/like", None),
                               ("POST", f"/solutions/{sid}/report", {"reason": "spam"}), ("POST", "/solutions", {"package": _pkg(), "community_key": KURS}),
                               ("PUT", f"/solutions/{sid}", {"package": _pkg(sid=sid)}), ("POST", f"/communities/{KURS}/join", {"kind": "course"}),
                               ("GET", "/communities", None), ("POST", f"/comments/x/report", {"reason": "spam"}), ("PATCH", "/comments/x", {"text": "x"})):
        st, d = call(hosted, method, path, hf, body)
        assert (st, d["code"]) == (403, "plan_required"), (method, path, st, d)
    # eigene Daten und Moderation ohne Tarif erreichbar (bewusst: _account)
    assert call(hosted, "GET", "/mine", hf)[0] == 200 and call(hosted, "GET", "/blocks", hf)[0] == 200
    assert call(hosted, "GET", "/moderation", hf)[1]["code"] == "forbidden"
    # Plus-Konto ohne bestaetigte Adresse: lesen ja, kommentieren nein
    _, hu = _user(hosted, "unbestaetigt@beispiel.de", verified=False)
    call(hosted, "POST", "/claims", hu, {"fingerprints": [], "course_keys": [KURS]})
    from app import community
    uid = json.loads(asgi_call(hosted, "GET", "/api/account/me", headers=hu)[2])["user"]["id"]
    with community.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO community_members(user_id, community_key, university, kind, joined_at) VALUES (?,?,'luh','course','2026-11-04T00:00:00Z')",
                     (uid, KURS))
    assert call(hosted, "GET", f"/solutions/{sid}/comments", hu)[0] == 200
    assert call(hosted, "POST", f"/solutions/{sid}/comments", hu, {"text": "hi"})[1]["code"] == "email_unverified"
    assert call(hosted, "POST", f"/solutions/{sid}/like", hu)[1]["code"] == "email_unverified"


def test_comment_rights_matrix_owner_author_admin(hosted):  # noqa: F811
    """Nr. 148-150: Verfasser aendert und loescht; Autor der Loesung und Moderation loeschen, aendern nicht; nach dem
    Loeschen ist der Kommentar fuer Aendern, Loeschen und Melden weg; Antworten bleiben unter dem Platzhalter."""
    autor, ha = _member_user(hosted, "autor@beispiel.de")
    leser, hl = _member_user(hosted, "leser@beispiel.de")
    dritte, hd = _member_user(hosted, "dritte@beispiel.de")
    admin, hadm = _user(hosted, "admin@beispiel.de", admin=True)
    sid = _publish(hosted, ha, _pkg())
    c1, c2, c3 = _comment(hosted, sid, hl, "eins"), _comment(hosted, sid, hl, "zwei"), _comment(hosted, sid, hl, "drei")
    reply = call(hosted, "POST", f"/solutions/{sid}/comments", hd, {"text": "Antwort", "parent_id": c1})[1]["id"]
    assert call(hosted, "PATCH", f"/comments/{c1}", hd, {"text": "fremd"})[1]["code"] == "not_owner"
    assert call(hosted, "PATCH", f"/comments/{c1}", ha, {"text": "Autor der Loesung"})[1]["code"] == "not_owner"
    assert call(hosted, "PATCH", f"/comments/{c1}", hadm, {"text": "Moderation"})[1]["code"] == "not_owner"
    assert call(hosted, "PATCH", f"/comments/{c1}", hl, {"text": "geaendert"})[1]["text"] == "geaendert"
    assert call(hosted, "DELETE", f"/comments/{c1}", hd)[1]["code"] == "not_owner"
    assert call(hosted, "DELETE", f"/comments/{c1}", hl)[0] == 200
    assert call(hosted, "DELETE", f"/comments/{c2}", ha)[0] == 200, "Autor der Loesung raeumt auf"
    assert call(hosted, "DELETE", f"/comments/{c3}", hadm)[0] == 200, "Moderation"
    assert call(hosted, "PATCH", f"/comments/{c1}", hl, {"text": "nochmal"})[1]["code"] == "not_found"
    assert call(hosted, "DELETE", f"/comments/{c1}", hl)[1]["code"] == "not_found"
    assert call(hosted, "POST", f"/comments/{c1}/report", hd, {"reason": "spam"})[1]["code"] == "not_found"
    out = call(hosted, "GET", f"/solutions/{sid}/comments", hd)[1]["comments"]
    assert [(c["id"], c["deleted"], c["text"]) for c in out] == [(c1, True, ""), (reply, False, "Antwort")], "nur der geloeschte mit Antwort bleibt"
