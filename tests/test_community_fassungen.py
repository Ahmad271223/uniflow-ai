"""Loesungen fuer alle Fassungen einer PDF (Datei-Familie, Freigabe des Inhabers 23.11.2026).

Neue Apps schicken beim Teilen eine Kennung der Datei mit, die fuer jede Fassung gleich bleibt (`family`, HMAC auf dem
Geraet aus Kurs-Geheimnis und Datei-Kennung des Portals); die Suche findet Loesungen ueber den Fingerabdruck ODER die
Familie, gefiltert wie bisher. Alte Apps (1.0.6) senden keine Familie und fragen nur nach dem Fingerabdruck: fuer sie
aendert sich nichts. Testdaten sind erfunden."""
import pytest

from test_community import _user, hosted  # noqa: F401
from test_community_groups import ANDERER, KURS, call, member

FP1, FP2, FP3 = "a" * 64, "b" * 64, "c" * 64          # Fassung 1 und 2 derselben Datei, eine fremde Datei
FAMILIE, ANDERE_FAMILIE = "d" * 64, "e" * 64


def _pkg(fp, sid=None, pages=2):
    from app import community
    return community.sample_package(fp, pages=pages, solution_id=sid, key_material="community-secret")


def _publish(app, h, pkg, family=None, key=KURS, title="Blatt 3"):
    body = {"package": pkg, "title": title, "community_key": key}
    if family is not None:
        body["family"] = family
    return call(app, "POST", "/solutions", h, body)


def _ids(app, h, fp, family=None):
    q = f"/solutions?fingerprint={fp}" + (f"&family={family}" if family else "")
    st, d = call(app, "GET", q, h)
    assert st == 200, d
    return [r["solution_id"] for r in d["solutions"]]


def test_solution_to_version_1_is_found_with_version_2_through_the_family(hosted):  # noqa: F811
    autor, leser = member(hosted, "autor@beispiel.de"), member(hosted, "leser@beispiel.de")
    p1 = _pkg(FP1)
    sid = p1["header"]["solutionId"]
    st, d = _publish(hosted, autor, p1, family=FAMILIE)
    assert st == 201, d
    # neue App mit Fassung 2: ueber die Familie gefunden, mit Fingerabdruck der Fassung 1 und der Familie im Eintrag
    st, d = call(hosted, "GET", f"/solutions?fingerprint={FP2}&family={FAMILIE}", leser)
    assert [(r["solution_id"], r["fingerprint"], r["family"]) for r in d["solutions"]] == [(sid, FP1, FAMILIE)]
    assert d["total"] == 1
    # Fassung 1 findet sie wie immer, mit und ohne Familie (keine Doppel)
    assert _ids(hosted, leser, FP1) == [sid] and _ids(hosted, leser, FP1, FAMILIE) == [sid]
    # alte App mit Fassung 2: fragt nur nach dem Fingerabdruck und findet (wie bisher) nichts
    assert _ids(hosted, leser, FP2) == []
    # eine andere Datei findet sie nicht
    assert _ids(hosted, leser, FP3, ANDERE_FAMILIE) == []
    # geladen wird das unveraenderte Paket
    assert call(hosted, "GET", f"/solutions/{sid}", leser)[1]["package"] == p1


def test_old_clients_without_family_keep_working(hosted):  # noqa: F811
    autor, leser = member(hosted, "autor@beispiel.de"), member(hosted, "leser@beispiel.de")
    alt = _pkg(FP1)                                          # App 1.0.6: kein `family` im Aufruf
    sid = alt["header"]["solutionId"]
    assert _publish(hosted, autor, alt)[0] == 201
    rows = call(hosted, "GET", f"/solutions?fingerprint={FP1}", leser)[1]["solutions"]
    assert [(r["solution_id"], r["family"]) for r in rows] == [(sid, None)]
    # ohne Familie nur ueber den Fingerabdruck: eine neue App mit Fassung 2 findet die alte Loesung nicht
    assert _ids(hosted, leser, FP2, FAMILIE) == []
    assert _ids(hosted, leser, FP1, FAMILIE) == [sid]
    # beim Aktualisieren durch eine neue App bekommt sie die Familie ...
    st, d = call(hosted, "PUT", f"/solutions/{sid}", autor, {"package": _pkg(FP1, sid=sid, pages=3), "community_key": KURS, "family": FAMILIE})
    assert st == 200, d
    assert _ids(hosted, leser, FP2, FAMILIE) == [sid]
    # ... und ein alter Client, der danach ohne Familie aktualisiert, nimmt sie nicht wieder weg
    assert call(hosted, "PUT", f"/solutions/{sid}", autor, {"package": _pkg(FP1, sid=sid, pages=4)})[0] == 200
    assert _ids(hosted, leser, FP2, FAMILIE) == [sid]
    # eine andere Familie fuer dieselbe Loesung wird abgewiesen
    st, d = call(hosted, "PUT", f"/solutions/{sid}", autor, {"package": _pkg(FP1, sid=sid), "family": ANDERE_FAMILIE})
    assert (st, d["code"]) == (400, "solution_mismatch")


def test_republishing_the_same_solution_without_family_keeps_it(hosted):  # noqa: F811
    autor, leser = member(hosted, "autor@beispiel.de"), member(hosted, "leser@beispiel.de")
    p = _pkg(FP1)
    assert _publish(hosted, autor, p, family=FAMILIE)[0] == 201
    assert _publish(hosted, autor, p)[1]["republished"] is True        # gleiche ID, alter Client
    assert _ids(hosted, leser, FP2, FAMILIE) == [p["header"]["solutionId"]]


def test_family_search_keeps_all_filters(hosted):  # noqa: F811
    from app import community
    autor = member(hosted, "autor@beispiel.de")
    leser = member(hosted, "leser@beispiel.de")
    fremd = member(hosted, "fremd@beispiel.de", course=ANDERER)
    gesperrt = member(hosted, "gesperrt@beispiel.de")
    zurueck = member(hosted, "zurueck@beispiel.de")
    a = _pkg(FP1)
    assert _publish(hosted, autor, a, family=FAMILIE)[0] == 201
    b = _pkg(FP1)
    assert _publish(hosted, gesperrt, b, family=FAMILIE)[0] == 201
    c = _pkg(FP1)
    assert _publish(hosted, zurueck, c, family=FAMILIE)[0] == 201
    # andere Community: wer dort nicht Mitglied ist, sieht die Loesung auch ueber die Familie nicht
    call(hosted, "POST", "/claims", autor, {"fingerprints": [], "course_keys": [KURS, ANDERER]})
    assert call(hosted, "POST", f"/communities/{ANDERER}/join", autor, {"kind": "course"})[0] == 200
    d = _pkg(FP1)
    assert _publish(hosted, autor, d, family=FAMILIE, key=ANDERER)[0] == 201
    assert sorted(_ids(hosted, leser, FP2, FAMILIE)) == sorted(x["header"]["solutionId"] for x in (a, b, c))
    assert _ids(hosted, fremd, FP2, FAMILIE) == [d["header"]["solutionId"]]
    # zurueckgezogen
    assert call(hosted, "DELETE", f"/solutions/{c['header']['solutionId']}", zurueck)[0] == 200
    # eigene Sperrliste
    assert call(hosted, "POST", f"/solutions/{b['header']['solutionId']}/block", leser)[0] == 200
    assert _ids(hosted, leser, FP2, FAMILIE) == [a["header"]["solutionId"]]
    # Bann durch die Moderation
    with community.cursor() as conn:
        row = conn.execute("SELECT author_id FROM solutions WHERE id=?", (a["header"]["solutionId"],)).fetchone()
        conn.execute("INSERT INTO bans(author_id, created_at) VALUES (?, '2026-11-23T10:00:00Z')", (row["author_id"],))
    assert _ids(hosted, leser, FP2, FAMILIE) == []
    # verborgen (Meldungen) und andere Hochschule
    with community.cursor() as conn:
        conn.execute("DELETE FROM bans")
        conn.execute("UPDATE solutions SET status='hidden' WHERE id=?", (a["header"]["solutionId"],))
    assert _ids(hosted, leser, FP2, FAMILIE) == []
    with community.cursor() as conn:
        conn.execute("UPDATE solutions SET status='active', university='hildesheim' WHERE id=?", (a["header"]["solutionId"],))
    assert _ids(hosted, leser, FP2, FAMILIE) == []


def test_package_without_community_never_reaches_another_version(hosted, monkeypatch):  # noqa: F811
    """Pakete ohne Community (nur Tests der alten Regeln) gehoeren an genau ihre PDF: ueber die Familie nie."""
    from app import community
    monkeypatch.setattr(community, "LEGACY_PUBLISH", True)
    _, autor = _user(hosted, "autor@beispiel.de")
    _, leser = _user(hosted, "leser@beispiel.de")
    for h in (autor, leser):
        assert call(hosted, "POST", "/claims", h, {"fingerprints": [FP1, FP2], "course_keys": [KURS]})[0] == 200
        assert call(hosted, "POST", f"/communities/{KURS}/join", h, {"kind": "course"})[0] == 200
    p = community.sample_package(FP1)
    st, d = call(hosted, "POST", "/solutions", autor, {"package": p, "title": "x", "family": FAMILIE})
    assert st == 201, d
    assert _ids(hosted, leser, FP1, FAMILIE) == [p["header"]["solutionId"]]
    assert _ids(hosted, leser, FP2, FAMILIE) == []


@pytest.mark.parametrize("bad", ["xyz", "A" * 63, "g" * 64, "1" * 65])
def test_invalid_family_is_refused(hosted, bad):  # noqa: F811
    autor = member(hosted, "autor@beispiel.de")
    st, d = _publish(hosted, autor, _pkg(FP1), family=bad)
    assert (st, d["code"]) == (400, "family_invalid")
    st, d = call(hosted, "GET", f"/solutions?fingerprint={FP1}&family={bad}", autor)
    assert (st, d["code"]) == (400, "family_invalid")


def test_family_in_capitals_is_the_same_family(hosted):  # noqa: F811
    autor, leser = member(hosted, "autor@beispiel.de"), member(hosted, "leser@beispiel.de")
    p = _pkg(FP1)
    assert _publish(hosted, autor, p, family="D" * 64)[0] == 201
    assert _ids(hosted, leser, FP2, FAMILIE) == [p["header"]["solutionId"]]
    assert _ids(hosted, leser, FP2, "D" * 64) == [p["header"]["solutionId"]]
