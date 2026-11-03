"""Schwarzes Brett aus Stud.IP (app/studip_bulletin.py, 03.11.2026), Python-Fassung des Swift-Kerns StudIPBulletin:
Themenliste aus der Plugin-Seite, Anzeigen aus den RSS-Feeds je Thema (ohne Autoren, ganzer Text, Zeit als Ortszeit),
hoechstens 20 je Thema, fehlendes Plugin 30 Tage gemerkt, Mindestabstand 6 Stunden, abgelaufene Sitzung, nur lokal und
nur bei Hochschulen mit Brett, Endpunkte /api/studip/bulletin. Seiten und Feeds aus der gemeinsamen Fixture
packages/shared-contracts/fixtures/studip-bulletin/bulletin.json (tools/gen-studip-bulletin-fixture.py)."""
import json
import subprocess
import sys
from datetime import date
from pathlib import Path

import pytest
from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
FX = json.loads((ROOT / "packages/shared-contracts/fixtures/studip-bulletin/bulletin.json").read_text(encoding="utf-8"))
PLUGIN = "/plugins.php/schwarzesbrettplugin"
TODAY = date(2026, 11, 2)


def test_fixture_is_current():
    r = subprocess.run([sys.executable, "tools/gen-studip-bulletin-fixture.py", "--check"], cwd=ROOT, capture_output=True, text=True,
                       encoding="utf-8", timeout=300)
    assert r.returncode == 0, f"python tools/gen-studip-bulletin-fixture.py neu ausfuehren\n{r.stdout}\n{r.stderr}"


# ---------------------------------------------------------------- Lesen (reine Funktionen)

def test_topics_from_the_list_page():
    from app import studip_bulletin as sb
    topics = sb.parse_topics(FX["list_html"])
    assert [t["title"] for t in topics] == ["Biete", "Jobs an der Uni", "Wohnliches"], "nur die Themenliste, keine Anzeigen, keine Doppelten"
    assert [t["count"] for t in topics] == [1234, 7, 0]
    assert topics[0]["id"] == "a" * 32
    assert sb.parse_topics(FX["not_a_list_html"]) == []
    assert sb.parse_topics("") == [] and sb.parse_topics("<ul class='sb-categories'><li><a href='/x'>kein Thema</a>") == []
    assert sb.board_url("https://studip.test/") == "https://studip.test/plugins.php/schwarzesbrettplugin/category/list"
    assert FX["topics"]["list"] == topics


def test_topic_ends_at_the_first_count():
    """LUH: Hinweistext hinter der Anzahl gehoert nicht zum Titel (Commit 1e78d8c)"""
    from app import studip_bulletin as sb
    t = sb.parse_topics(FX["tooltip_html"])
    assert [x["title"] for x in t] == ["Umfragen", "Studentische Arbeiten"]
    assert [x["count"] for x in t] == [5, 43]


def test_feed_has_full_text_without_authors():
    from app import studip_bulletin as sb
    e = sb.parse_feed(FX["feed_xml"], "Biete")
    assert [x["id"] for x in e] == ["sb-e1", "sb-e2", "sb-e4"], "ohne Titel oder doppelt: weg"
    assert e[0]["title"] == "Fahrrad & Helm zu verkaufen"
    assert e[0]["text"] == "Gut erhaltenes Rad,\n28 Zoll. Preis VB.\nNur Abholung.", "Absaetze bleiben"
    assert e[0]["posted_at"] == "2026-11-02T10:15:00"
    assert e[0]["url"].endswith("/article/view/e1") and e[0]["topic"] == "Biete"
    assert e[1]["posted_at"] == "2026-07-12T10:00:00", "Sommerzeit"
    assert len(e[1]["text"]) > 1000 and e[1]["text"].startswith("Wort1 Wort2 ") and e[1]["text"].endswith("Wort300\nLetzter Absatz.")
    assert "…" not in e[1]["text"], "ganze Anzeige, nie gekuerzt"
    assert e[2]["posted_at"] == "2026-11-03T10:00:00", "GMT -> Berlin"
    assert e[2]["url"] == "" and e[2]["text"] == "xText", "nur http(s)"
    assert sb.local_time("irgendwann") is None
    assert sb.local_time("2 Nov 2026 23:30:00 -0500") == "2026-11-03T05:30:00"
    assert FX["feed"] == e
    assert {k: sb.local_time(k) for k in FX["local_time"]} == FX["local_time"]


def test_feed_never_keeps_author_names():
    """Der Feed kann Autoren nennen (author, dc:creator); gespeichert wird nur Titel, Text, Link, Zeit"""
    from app import studip_bulletin as sb
    xml = ('<rss><channel><item><title>Sofa</title><link>https://studip.test/a/1</link><author>Max Mustermann</author>'
           '<dc:creator>Erika Beispiel</dc:creator><description><![CDATA[<p>Rot, 2 m.</p>]]></description>'
           '<pubDate>Mon, 02 Nov 2026 10:15:00 +0100</pubDate><guid>g1</guid></item></rss>')
    (e,) = sb.parse_feed(xml, "Biete")
    assert set(e) == {"id", "topic", "title", "text", "url", "posted_at"}
    assert "Mustermann" not in json.dumps(e) and "Beispiel" not in json.dumps(e)


def test_at_most_twenty_per_topic():
    from app import studip_bulletin as sb
    items = "".join(f"<item><title>T{i}</title><guid>g{i}</guid><link>https://x.test/{i}</link></item>" for i in range(30))
    assert len(sb.parse_feed(f"<rss>{items}</rss>", "Biete")) == 20


# ---------------------------------------------------------------- Abruf und Speichern

@pytest.fixture
def clean(app):
    from app import db
    db.init_db()

    def wipe():
        with db.cursor() as conn:
            conn.execute("DROP TABLE IF EXISTS studip_bulletin")
            conn.execute("DELETE FROM settings WHERE key IN ('studip_bulletin_topics', 'studip_bulletin_fetched_at', 'studip_missing_endpoints')")
    wipe()
    yield
    wipe()


def _getter(table, log):
    from app import studip_bulletin as sb

    def get(path):
        log.append(path)
        r = table.get(path)
        return sb.Reply(404, "application/json", "{}") if r is None else sb.Reply(r["status"], r["content_type"], r["body"], r["final_url"])
    return get


def test_fetch_stores_twenty_per_topic_and_waits_six_hours(clean):
    from app import db, studip_bulletin as sb, studip_extras
    erst, bald, spaeter = FX["runs"]
    assert erst["entries"] == 60 and not erst["skipped"], "hoechstens 20 je Thema"
    assert len(erst["requested"]) == 4 and all(p.startswith(PLUGIN + "/") for p in erst["requested"]), "nur das Plugin, nur GET"
    assert erst["requested"][0] == PLUGIN + "/category/list"
    assert [t["title"] for t in erst["topics"]] == ["Biete", "Jobs an der Uni", "Wohnliches"]
    assert bald["skipped"] and bald["requested"] == [], "innerhalb von 6 Stunden nichts gefragt"
    assert spaeter["entries"] == 9 and spaeter["stored"] == 9, "danach ersetzt der Bestand (Verschwundenes weg)"
    assert spaeter["overview"]["new_count"] == 9 and len(spaeter["rows"]) == 9
    # dieselben Schritte noch einmal auf der Datenbank der Tests
    table25 = _table_from(FX["runs"][0])
    with db.cursor() as conn:
        d = sb.fetch(_getter(table25, []), {}, None, "2026-11-02", "2026-11-02T12:00:00")
        assert sb.store(d, conn, "2026-11-02T12:00:00") == 60
        assert conn.execute("SELECT COUNT(*) FROM studip_bulletin").fetchone()[0] == 60
        assert sb.last_fetched_at(conn) == "2026-11-02T12:00:00"
        soon = sb.fetch(_getter(table25, log := []), studip_extras.load_missing(conn), sb.last_fetched_at(conn), "2026-11-02", "2026-11-02T17:59:59")
        assert soon.skipped and log == []
        later = sb.fetch(_getter(table25, []), {}, sb.last_fetched_at(conn), "2026-11-02", "2026-11-02T18:00:00")
        assert not later.skipped and len(later.entries) == 60


def _table_from(run):
    """Seiten der Fixture ('erst'): Themenliste und ein Feed je Thema"""
    from app import studip_bulletin as sb
    import importlib.util
    spec = importlib.util.spec_from_file_location("genbulletin", ROOT / "tools" / "gen-studip-bulletin-fixture.py")
    sys.path.insert(0, str(ROOT / "tools"))
    try:
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    finally:
        sys.path.remove(str(ROOT / "tools"))
    assert run["name"] == "erst" and sb.PER_TOPIC == 20
    return mod.routes(25)


def test_missing_plugin_is_remembered_for_thirty_days():
    plugin = {r["name"]: r for r in FX["plugin"]}
    assert plugin["kein-plugin"]["entries"] is None and plugin["kein-plugin"]["missing"] == {"bulletin": "2026-11-02"}
    assert plugin["kein-plugin"]["requested"] == [PLUGIN + "/category/list"]
    assert plugin["ohne-themen"]["missing"] == {"bulletin": "2026-11-02"}, "Seite ohne Themenliste: ebenso"
    assert plugin["gemerkt-29"]["skipped"] and plugin["gemerkt-29"]["requested"] == [], "nach 29 Tagen nicht gefragt"
    assert plugin["gemerkt-30"]["entries"] == 3 and plugin["gemerkt-30"]["missing"] == {}, "nach 30 Tagen wieder; Merker weg"
    assert plugin["kein-plugin"]["overview"]["entries"] == [] and plugin["kein-plugin"]["overview"]["available"] is True


def test_session_expiry_and_switched_off_feed_keep_the_stock():
    plugin = {r["name"]: r for r in FX["plugin"]}
    for name in ("sitzung", "passwortfeld"):
        assert plugin[name]["session_expired"] and plugin[name]["entries"] is None
        assert plugin[name]["missing"] == {}, "abgelaufene Sitzung ist kein fehlendes Plugin"
    assert plugin["rss-aus"]["feed_unavailable"] and plugin["rss-aus"]["entries"] is None and plugin["rss-aus"]["rows"] == []


def test_store_keeps_old_ads_when_nothing_was_read(clean):
    from app import db, studip_bulletin as sb
    table = _table_from(FX["runs"][0])
    with db.cursor() as conn:
        sb.store(sb.fetch(_getter(table, []), {}, None, "2026-11-02", "2026-11-02T12:00:00"), conn, "2026-11-02T12:00:00")
        broken = dict(table)
        broken[PLUGIN + "/category/list"] = {"status": 200, "content_type": "text/html", "body": "<html>", "final_url": "https://studip.test/dispatch.php/login"}
        d = sb.fetch(_getter(broken, []), {}, None, "2026-11-03", "2026-11-03T12:00:00")
        assert d.session_expired and sb.store(d, conn, "2026-11-03T12:00:00") == 0
        assert conn.execute("SELECT COUNT(*) FROM studip_bulletin").fetchone()[0] == 60
        assert sb.last_fetched_at(conn) == "2026-11-02T12:00:00"


def test_network_error_keeps_the_stock(clean):
    from app import db, studip_bulletin as sb
    def broken(path):
        raise OSError("kein Netz")
    with db.cursor() as conn:
        d = sb.fetch(broken, {}, None, "2026-11-02", "2026-11-02T12:00:00")
        assert d.entries is None and not d.session_expired and d.missing == {}


# ---------------------------------------------------------------- Endpunkte

def test_endpoints(app, clean):
    from app import db, studip_bulletin as sb
    status, _, body = asgi_call(app, "GET", "/api/studip/bulletin")
    o = json.loads(body)
    assert status == 200 and o["available"] is True and o["entries"] == [] and o["topics"] == [] and o["new_count"] == 0
    assert o["fetched_at"] is None and o["url"].endswith("/plugins.php/schwarzesbrettplugin/category/list")
    assert set(o) == {"available", "topics", "entries", "new_count", "fetched_at", "url"}
    table = _table_from(FX["runs"][0])
    from app import study
    now = study.today().isoformat() + "T12:00:00"
    with db.cursor() as conn:
        sb.store(sb.fetch(_getter(table, []), {}, None, study.today().isoformat(), now), conn, now)
    o = json.loads(asgi_call(app, "GET", "/api/studip/bulletin")[2])
    assert [t["title"] for t in o["topics"]] == ["Biete", "Jobs an der Uni", "Wohnliches"], "Reihenfolge von Stud.IP"
    assert [t["count"] for t in o["topics"]] == [20, 20, 20] and o["topics"][0]["total"] == 1234
    assert len(o["entries"]) == 60 and o["entries"][0]["title"] == "Biete 1", "neueste zuerst"
    assert o["fetched_at"] == now
    assert set(o["entries"][0]) == {"id", "topic", "title", "text", "url", "posted_at"}
    one = json.loads(asgi_call(app, "GET", "/api/studip/bulletin?topic=Jobs%20an%20der%20Uni")[2])
    assert len(one["entries"]) == 20 and all(e["topic"] == "Jobs an der Uni" for e in one["entries"])
    assert one["new_count"] == o["new_count"], "new_count zaehlt alle Themen"
    status, _, body = asgi_call(app, "GET", "/api/studip/bulletin/sb-a3")
    assert status == 200 and json.loads(body)["text"] == "Text 3"
    status, _, body = asgi_call(app, "GET", "/api/studip/bulletin/sb-nein")
    assert status == 404 and json.loads(body)["detail"] == "Anzeige nicht gefunden"


def test_new_count_counts_the_last_seven_days(clean):
    from app import db, studip_bulletin as sb
    d = sb.Download({})
    d.topics = [{"id": "a", "title": "Biete", "count": 3}]
    d.entries = [{"id": f"sb-{i}", "topic": "Biete", "title": f"A{i}", "text": "t", "url": "", "posted_at": p}
                 for i, p in enumerate(["2026-11-02T09:00:00", "2026-10-26T00:00:00", "2026-10-25T23:59:59", ""])]
    with db.cursor() as conn:
        sb.store(d, conn, "2026-11-02T12:00:00")
        o = sb.overview(conn, None, TODAY)
        assert o["new_count"] == 2, "sieben Tage zurueck: 26.10. zaehlt, 25.10. nicht, ohne Zeit nie"
        assert [e["id"] for e in o["entries"]] == ["sb-0", "sb-1", "sb-2", "sb-3"]
        assert o["entries"][-1]["posted_at"] is None and o["entries"][-1]["url"] is None


def test_hildesheim_has_no_board(clean, monkeypatch):
    from app import db, studip_bulletin as sb, universities
    table = _table_from(FX["runs"][0])
    with db.cursor() as conn:
        sb.store(sb.fetch(_getter(table, []), {}, None, "2026-11-02", "2026-11-02T12:00:00"), conn, "2026-11-02T12:00:00")
        monkeypatch.setattr(universities, "current_key", lambda: "hildesheim")
        o = sb.overview(conn, None, TODAY)
        assert o == FX["hosts"]["hildesheim"] and o["available"] is False and o["entries"] == [] and o["url"] is None
        assert not sb.sync_allowed()


def test_nothing_in_the_hosted_service(clean, monkeypatch):
    """Im Dienst wird nichts abgerufen, gespeichert oder gezeigt"""
    from app import config, db, studip_bulletin as sb
    table = _table_from(FX["runs"][0])
    with db.cursor() as conn:
        sb.store(sb.fetch(_getter(table, []), {}, None, "2026-11-02", "2026-11-02T12:00:00"), conn, "2026-11-02T12:00:00")
        monkeypatch.setattr(config, "is_hosted", lambda: True)
        o = sb.overview(conn, None, TODAY)
        assert o["available"] is False and o["entries"] == [] and o["topics"] == [] and o["new_count"] == 0
        assert sb.item(conn, "sb-a1") is None and not sb.sync_allowed()
        log: list = []
        assert sb.run(conn, _getter(table, log), "2026-11-03", "2026-11-03T12:00:00") == {"skipped": True} and log == []


def test_run_reads_once_and_remembers(clean):
    from app import db, studip_bulletin as sb
    table = _table_from(FX["runs"][0])
    with db.cursor() as conn:
        log: list = []
        r = sb.run(conn, _getter(table, log), "2026-11-02", "2026-11-02T12:00:00")
        assert r["entries"] == 60 and r["topics"] == 3 and len(log) == 4
        log.clear()
        assert sb.run(conn, _getter(table, log), "2026-11-02", "2026-11-02T13:00:00") == {"skipped": True} and log == []
        r = sb.run(conn, _getter({}, log), "2026-12-01", "2026-12-01T13:00:00")
        assert r["entries"] == 0 and r["missing"] is True, "kein Plugin: Merker, der Bestand bleibt stehen"
        assert conn.execute("SELECT COUNT(*) FROM studip_bulletin").fetchone()[0] == 60


def test_sync_calls_the_board_only_for_local_use():
    """Der Abgleich ruft das Brett nach den Ergaenzungen, nur wenn es erlaubt ist (lokal, Hochschule mit Brett)"""
    src = (ROOT / "app" / "studip_sync.py").read_text(encoding="utf-8")
    assert "studip_bulletin.sync_allowed()" in src and "studip_bulletin.run(" in src
    assert src.index("studip_extras.sync(") < src.index("studip_bulletin.run(") < src.index("studip_texts.run(")
