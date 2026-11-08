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

