"""Erzeugt packages/shared-contracts/fixtures/studip-bulletin/bulletin.json: Schwarzes Brett aus Stud.IP (03.11.2026) mit
der Python-Referenz (app/studip_bulletin.py) auf erfundenen Seiten und Feeds und eingefrorener Uhr. Der Swift-Kern
(StudIPBulletinTests) kann dieselben Antworten ueber seinen Stub liefern und exakt vergleichen: Reihenfolge der
Anfragen, Themenliste, Anzeigen, gespeicherte Zeilen, Merker fuer ein fehlendes Plugin und die Antworten von
GET /api/studip/bulletin(/{id}).

Inhalt:
- topics: Seite category/list -> gelesene Themen (auch Hinweistext hinter der Anzahl, verschachtelte und doppelte Links)
- feed: RSS eines Themas -> Anzeigen (ohne Titel/doppelt weg, ganzer langer Text, Zeiten, nur http(s)-Links)
- local_time: pubDate -> Ortszeit Berlin
- runs: Abrufe nacheinander auf einer Datenbank (erst, bald = zu frueh, spaeter = Bestand ersetzt) mit den Anfragen,
  gespeicherten Zeilen, Einstellungen und der Uebersicht (Themen, Anzeigen, new_count) sowie einer Anzeige
- plugin: kein Plugin (404), Seite ohne Themenliste, Merker 29/30 Tage, abgelaufene Sitzung, RSS abgeschaltet
- hosts: Uebersicht bei Hildesheim (kein Brett) und im Dienst (nichts gezeigt)

Aufruf im Projektordner: python tools/gen-studip-bulletin-fixture.py [--check]
"""
from __future__ import annotations

import json
import sys
from datetime import date

from schema_source import ROOT, SchemaSource, write_or_check

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "studip-bulletin" / "bulletin.json"
BASE = "https://studip.test"
PLUGIN = "/plugins.php/schwarzesbrettplugin"
IDS = {"Biete": "a" * 32, "Jobs an der Uni": "b" * 32, "Wohnliches": "c" * 32}

LIST_HTML = f"""<!DOCTYPE html><html><head><title>Schwarzes Brett</title></head><body>
<div id="content"><h2>Themenübersicht</h2>
<ul class="sb-categories">
    <li><a href="{BASE}{PLUGIN}/category/view/{'a' * 32}" class="category seen">
        Biete
        (1.234)
        <img src="x.svg" title="Dinge, die du loswerden willst" alt="">
    </a><div class="options"><a href="{BASE}{PLUGIN}/rss/{'a' * 32}"><img src="rss.svg"></a></div></li>
    <li><a href="{BASE}{PLUGIN}/category/view/{'b' * 32}" class="category unseen">Jobs an der Uni (7)</a></li>
    <li><a href="{PLUGIN}/category/view/{'c' * 32}" class="category seen">Wohnliches</a>
        <ul><li><a href="{PLUGIN}/category/view/{'a' * 32}">doppelt</a></li></ul></li>
</ul>
<h2>Die 20 neuesten Anzeigen</h2>
<ul class="sb-articles">
    <li data-article-id="{'d' * 32}" class="article seen"><a href="{PLUGIN}/article/view/{'d' * 32}" data-dialog>Suche WG-Zimmer</a>
        <a href="{PLUGIN}/category/view/{'c' * 32}">Wohnliches</a></li>
</ul></div></body></html>"""

TOOLTIP_HTML = f"""<ul class="sb-categories"><li><a href="plugins.php/schwarzesbrettplugin/category/view/{'0123456789abcdef' * 2}">Umfragen (5) <span class="tooltip">Umfragen und Befragungen</span></a></li>
<li><a href="plugins.php/schwarzesbrettplugin/category/view/{'fedcba9876543210' * 2}">Studentische Arbeiten (43) Hier können Angebote eingestellt werden.</a></li></ul>"""
NOT_A_LIST_HTML = '<html><body><ul class="sb-articles"><li><a href="/x/category/view/' + "a" * 32 + '">x</a></li></ul></body></html>'
LONG = "<p>" + " ".join(f"Wort{i}" for i in range(1, 301)) + "</p><p>Letzter Absatz.</p>"


def feed_xml(items) -> str:
    s = (f'<?xml version="1.0" encoding="UTF-8"?>\n<rss version="2.0"><channel><title>Stud.IP Schwarzes Brett - Biete</title>'
         f'<link>{BASE}{PLUGIN}/category</link>\n<description><![CDATA[]]></description><lastBuildDate>Mon, 02 Nov 2026 10:00:00 +0100</lastBuildDate>\n')
    for title, guid, link, desc, pub in items:
        s += f"<item><title>{title}</title><link>{link}</link><description><![CDATA[{desc}]]></description><pubDate>{pub}</pubDate>"
        if guid:
            s += f'<guid isPermaLink="false">{guid}</guid>'
        s += "</item>\n"
    return s + "</channel></rss>"


FEED_CASES = feed_xml([
    ("Fahrrad &amp; Helm zu verkaufen", "e1", f"{BASE}{PLUGIN}/article/view/e1",
     "<p>Gut erhaltenes <b>Rad</b>,<br>28 Zoll.&nbsp;Preis VB.</p><p>Nur Abholung.</p>", "Mon, 02 Nov 2026 10:15:00 +0100"),
    ("Sehr lang", None, f"{BASE}{PLUGIN}/article/view/e2", LONG, "Sun, 12 Jul 2026 10:00:00 +0200"),
    ("", "e3", f"{BASE}/x", "ohne Titel", "Mon, 02 Nov 2026 10:15:00 +0100"),
    ("Doppelt", "e1", f"{BASE}/y", "doppelte guid", "Mon, 02 Nov 2026 10:15:00 +0100"),
    ("GMT-Zeit", "e4", "javascript:alert(1)", "<script>x</script>Text", "Tue, 03 Nov 2026 09:00:00 GMT"),
])
TIMES = ["Mon, 02 Nov 2026 10:15:00 +0100", "Sun, 12 Jul 2026 10:00:00 +0200", "Tue, 03 Nov 2026 09:00:00 GMT", "irgendwann",
         "2 Nov 2026 23:30:00 -0500", "Mon, 02 Nov 26 08:05 +0100", "Sun, 25 Oct 2026 01:30:00 +0000", "Mon, 32 Nov 2026 10:00:00 +0100",
         "Mon, 02 Foo 2026 10:00:00 +0100", "Mon, 02 Nov 2026 25:00:00 +0100", "Mon, 02 Nov 2026 10:00:75 +0100"]


def page(html: str, status: int = 200, final_url: str | None = None) -> dict:
    return {"status": status, "content_type": "text/html; charset=UTF-8", "body": html, "final_url": final_url}


def feed(xml: str) -> dict:
    return {"status": 200, "content_type": "application/rss+xml;charset=utf-8", "body": xml, "final_url": None}


def routes(per_topic: int) -> dict:
    r = {PLUGIN + "/category/list": page(LIST_HTML)}
    for topic, tid in IDS.items():
        word = {"Biete": "Biete", "Jobs an der Uni": "Jobs", "Wohnliches": "Wohnen"}[topic]
        items = [(f"{word} {i}", f"{tid[0]}{i}", f"{BASE}{PLUGIN}/article/view/{tid[0]}{i}", f"<p>Text {i}</p>",
                  f"Mon, 02 Nov 2026 {10 - min(i, 9):02d}:{i % 60:02d}:00 +0100") for i in range(1, per_topic + 1)]
        r[f"{PLUGIN}/rss/{tid}/20"] = feed(feed_xml(items))
    return r


def build(check: bool) -> int:
    src = SchemaSource()
    try:
        from app import config, db, studip_bulletin as sb, studip_extras, universities

        config.STUDIP_BASE = "https://studip.uni-hannover.de"          # unabhaengig von der Umgebung (Adresse in `url`)
        def getter(table, log):
            def get(path):
                log.append(path)
                r = table.get(path)
                if r is None:
                    return sb.Reply(404, "application/json", "{}")
                return sb.Reply(r["status"], r["content_type"], r["body"], r["final_url"])
            return get

        def step(name, table, today, now, missing=None):
            """Ein Abruf auf der aktuellen Datenbank: fetch + store, danach Zeilen, Einstellungen und Uebersicht"""
            log: list = []
            with db.cursor() as conn:
                miss = studip_extras.load_missing(conn) if missing is None else missing
                d = sb.fetch(getter(table, log), miss, sb.last_fetched_at(conn), today, now)
                stored = None if d.skipped else sb.store(d, conn, now)
                t = date.fromisoformat(today)
                rows = db.rows(conn, "SELECT id, topic, title, text, url, posted_at, fetched_at FROM studip_bulletin ORDER BY id") \
                    if sb._has(conn) else []
                return {"name": name, "today": today, "now": now, "requested": log, "skipped": d.skipped,
                        "session_expired": d.session_expired, "feed_unavailable": d.feed_unavailable,
                        "topics": d.topics, "entries": None if d.entries is None else len(d.entries), "stored": stored,
                        "missing": d.missing, "rows": rows,
                        "settings": db.rows(conn, "SELECT key, value FROM settings WHERE key IN (?,?,?) ORDER BY key",
                                            (sb.TOPICS_KEY, sb.FETCHED_KEY, studip_extras.MISSING_KEY)),
                        "overview": sb.overview(conn, None, t)}

        out: dict = {"base": BASE, "plugin": PLUGIN, "per_topic": sb.PER_TOPIC, "min_hours": sb.MIN_HOURS, "new_days": sb.NEW_DAYS,
                     "list_html": LIST_HTML, "tooltip_html": TOOLTIP_HTML, "not_a_list_html": NOT_A_LIST_HTML, "feed_xml": FEED_CASES}
        out["topics"] = {"list": sb.parse_topics(LIST_HTML), "tooltip": sb.parse_topics(TOOLTIP_HTML), "not_a_list": sb.parse_topics(NOT_A_LIST_HTML)}
        out["feed"] = sb.parse_feed(FEED_CASES, "Biete")
        out["local_time"] = {t: sb.local_time(t) for t in TIMES}
        out["board_url"] = {BASE + "/": sb.board_url(BASE + "/"), BASE: sb.board_url(BASE)}

        # Abrufe nacheinander
        src.fresh_db("brett")
        runs = [step("erst", routes(25), "2026-11-02", "2026-11-02T12:00:00")]
        with db.cursor() as conn:
            t = date(2026, 11, 2)
            out["overview_topic"] = sb.overview(conn, "Jobs an der Uni", t)
            out["item"] = sb.item(conn, "sb-a3")
            out["item_missing"] = sb.item(conn, "sb-nein")
        runs.append(step("bald", routes(3), "2026-11-02", "2026-11-02T17:00:00"))
        runs.append(step("spaeter", routes(3), "2026-11-02", "2026-11-02T18:30:00"))
        out["runs"] = runs

        # kein Plugin, Merker, Sitzung, RSS aus
        plugin = []
        src.fresh_db("kein-plugin")
        plugin.append(step("kein-plugin", {}, "2026-11-02", "2026-11-02T12:00:00"))
        plugin.append(step("gemerkt-29", routes(1), "2026-12-01", "2026-12-01T12:00:00"))
        plugin.append(step("gemerkt-30", routes(1), "2026-12-02", "2026-12-02T12:00:00"))
        src.fresh_db("ohne-themen")
        plugin.append(step("ohne-themen", {PLUGIN + "/category/list": page("<html><body><h1>Fehler</h1></body></html>")},
                           "2026-11-02", "2026-11-02T12:00:00"))
        src.fresh_db("sitzung")
        login = page("<html>", final_url=BASE + "/dispatch.php/login")
        plugin.append(step("sitzung", {PLUGIN + "/category/list": login}, "2026-11-02", "2026-11-02T12:00:00"))
        passwort = page('<html><body><form action="/anmelden"><input type="password" name="p"></form></body></html>')
        plugin.append(step("passwortfeld", {PLUGIN + "/category/list": passwort}, "2026-11-02", "2026-11-02T12:00:00"))
        src.fresh_db("rss-aus")
        r = routes(2)
        r[f"{PLUGIN}/rss/{'a' * 32}/20"] = page("<html><body>RSS-Exporte sind nicht aktiviert.</body></html>", status=500)
        plugin.append(step("rss-aus", r, "2026-11-02", "2026-11-02T12:00:00"))
        out["plugin"] = plugin

        # Hochschule ohne Brett und gehosteter Dienst: nichts gezeigt
        hosts = {}
        src.fresh_db("hosts")
        with db.cursor() as conn:
            sb.store(sb.fetch(getter(routes(2), []), {}, None, "2026-11-02", "2026-11-02T12:00:00"), conn, "2026-11-02T12:00:00")
        saved = universities.current_key, config.is_hosted
        try:
            universities.current_key = lambda: "hildesheim"
            with db.cursor() as conn:
                hosts["hildesheim"] = sb.overview(conn, None, date(2026, 11, 2))
            universities.current_key = saved[0]
            config.is_hosted = lambda: True
            with db.cursor() as conn:
                hosts["dienst"] = sb.overview(conn, None, date(2026, 11, 2))
                hosts["dienst_item"] = sb.item(conn, "sb-a1")
                hosts["dienst_sync_allowed"] = sb.sync_allowed()
        finally:
            universities.current_key, config.is_hosted = saved
        out["hosts"] = hosts

        ok_ = write_or_check(OUT, json.dumps(out, ensure_ascii=False, indent=1) + "\n", check)
        return 0 if ok_ or not check else 1
    finally:
        src.cleanup()


if __name__ == "__main__":
    sys.exit(build("--check" in sys.argv))
