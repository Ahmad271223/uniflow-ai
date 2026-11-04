#!/usr/bin/env python3
"""Riesentest, Python-Referenz: die echten Abgleiche (`studip_sync.run_studip_sync`, `hildesheim.run_sync`) gegen die
synthetischen Hochschulen aus tools/lasttest-uni-synth.py. Kein Browser, kein Netz: die Playwright-Seite ist eine
Attrappe, die aus den Routen der Konto-Datei antwortet; jeder echte Verbindungsaufbau wird im Prozess gesperrt.

Je Konto: eigener Datenordner (wie ein Konto des Dienstes), Abgleich, Pruefung gegen `expected`, Ergebnis als JSON.
Aufruf im Projektordner:
  .venv/bin/python tools/riesentest-python.py --dir <ordner> --out ergebnis.json [--limit N] [--parallel 8] [--keep]
  (--shard i/n fuer einen Teil; --parallel startet n Unterprozesse mit je einem Teil)
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import resource
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import traceback
import urllib.parse
from datetime import date
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TMP = Path(os.environ.get("RIESENTEST_TMP") or tempfile.mkdtemp(prefix="riesentest-py-"))
os.environ["LERNAPP_DATA_DIR"] = str(TMP / "data")
os.environ["LERNAPP_LOG_DIR"] = str(TMP / "logs")
os.environ["LERNAPP_ENV_FILE"] = str(TMP / "leer.env")
os.environ["LERNAPP_ALLOWED_HOSTS"] = "test"
os.environ["LERNAPP_NO_SCHEDULER"] = "1"
os.environ["LERNAPP_MODE"] = "local"
os.environ["STUDIP_BASE"] = "https://studip.synth.invalid"
sys.path.insert(0, str(ROOT))

# ---------------------------------------------------------------- Netzsperre: nie eine echte Hochschule, nie irgendein Host


class NetworkForbidden(RuntimeError):
    pass


def _forbid(*a, **k):
    raise NetworkForbidden("Riesentest: Netzzugriff gesperrt (" + ", ".join(str(x)[:60] for x in a[:2]) + ")")


socket.create_connection = _forbid          # type: ignore[assignment]
socket.getaddrinfo = _forbid                # type: ignore[assignment]
import urllib.request as _ur                # noqa: E402

_ur.urlopen = _forbid                       # type: ignore[assignment]
_ur.OpenerDirector.open = _forbid           # type: ignore[assignment]

from app import announcements, config, db, hildesheim, learnweb, lsf, qis, semesters, studip_extras, studip_sync, studip_texts, study, timetable, unilogin  # noqa: E402

TODAY = date(2026, 11, 3)
BUDGET_SECONDS = 90.0


# ---------------------------------------------------------------- Welt eines Kontos

def content(fid: str, n: int, kind: str = "pdf") -> bytes:
    head = (f"%PDF-1.4\n% synth {fid}\n" if kind == "pdf" else f"SYNTH {kind} {fid}\n").encode("utf-8")
    if n <= 0:
        return b""
    return (head * (n // len(head) + 1))[:n]


class World:
    """Routen eines Kontos mit Zaehlern: flaky (erste Antworten 429/503), Sitzungsablauf, Dateiinhalte."""

    def __init__(self, acc: dict):
        self.acc = acc
        self.routes = acc["routes"]
        self.files = acc["files"]
        # Learnweb-Dateien ueber ihre Adresse, dekodiert (die Pipelines reichen die Adresse mal kodiert, mal nicht)
        self.file_urls = {urllib.parse.unquote(k): v for k, v in self.files.items() if k.startswith("http")}
        self.flaky: dict[str, list[int]] = {k: list(v["flaky"]) for k, v in self.routes.items() if v.get("flaky")}
        self.expire_after = acc["account"].get("expire_after")
        self.requests = 0
        self.log: list[str] = []

    @staticmethod
    def key(url: str) -> str:
        u = urllib.parse.unquote(url)
        for host in ("https://studip.synth.invalid",):
            if u.startswith(host):
                return u[len(host):]
        return u

    def reply(self, url: str) -> tuple[int, str, bytes]:
        """(Status, Content-Type, Body) wie die Hochschule; 404 ohne Route."""
        self.requests += 1
        k = self.key(url)
        self.log.append(k)
        if self.expire_after is not None and self.requests > self.expire_after and k.startswith("/jsonapi.php/"):
            return 401, "application/vnd.api+json", b'{"errors":[{"status":"401"}]}'
        if self.expire_after is not None and self.requests > self.expire_after and k.startswith("/dispatch.php/"):
            return 401, "text/html", b"<!doctype html><html><body><form><input type=password></form>Login</body></html>"
        m = re.match(r"^/jsonapi\.php/v1/file-refs/([0-9a-f]{32})/content$", k)
        if m:
            return self.file_reply(m.group(1))
        r = self.routes.get(k)
        if r is None:
            # Learnweb-Datei ueber ihre Adresse (ohne Abfrage)
            f = self.file_urls.get(k.split("?")[0])
            if f is not None:
                return self.file_reply(k.split("?")[0], f)
            return 404, "text/plain", b"nicht in der Nachbildung: " + k.encode()[:200]
        if k in self.flaky and self.flaky[k]:
            st = self.flaky[k].pop(0)
            return st, "application/vnd.api+json", json.dumps({"errors": [{"status": str(st)}]}).encode()
        data = base64.b64decode(r["b64"]) if r.get("b64") else r["body"].encode("utf-8")
        return r["status"], r["type"], data

    def file_reply(self, fid: str, f: dict | None = None) -> tuple[int, str, bytes]:
        f = f if f is not None else self.files.get(fid)
        if f is None:
            return 404, "text/plain", b"keine Datei"
        if f.get("html"):
            return 200, "text/html", b"<!doctype html><html><body>Wartungsseite</body></html>"
        return 200, "application/pdf" if f["kind"] == "pdf" else "application/octet-stream", content(fid, f["serve"], f["kind"])

    def learnweb_post(self, url: str, data: dict) -> bytes:
        self.requests += 1
        fn = data.get("wsfunction", "")
        key = ""
        for p in ("courseid", "forumid", "aftereventid"):
            if p in data:
                key = f"{p}={data[p]}"
                break
        r = self.routes.get(f"REST|{fn}|{key}") or self.routes.get(f"REST|{fn}|")
        self.log.append(f"REST {fn} {key}")
        if r is None:
            return json.dumps({"exception": "moodle_exception", "errorcode": "unknown", "message": f"nicht in der Nachbildung: {fn}"}).encode()
        return r["body"].encode("utf-8")


class Resp:
    def __init__(self, status: int, ctype: str, data: bytes, url: str):
        self.status, self._ctype, self._data, self.url = status, ctype, data, url
        self.headers = {"content-type": ctype}

    @property
    def ok(self) -> bool:
        return 200 <= self.status < 300

    def text(self) -> str:
        return self._data.decode("utf-8", "replace")

    def body(self) -> bytes:
        return self._data

    def json(self):
        return json.loads(self._data.decode("utf-8"))     # wie Playwright: ungueltiges UTF-8/JSON wirft

    def dispose(self) -> None:
        pass


class Locator:
    def __init__(self, page: "Page", selector: str):
        self.page, self.selector = page, selector

    def count(self) -> int:
        m = re.search(r"has-text\('([^']*)'\)", self.selector)
        if m:
            return 1 if m.group(1) in (self.page._content or "") else 0
        if "password" in self.selector or "username" in self.selector or "submit" in self.selector:
            return 0
        return 0

    @property
    def first(self):
        return self

    def nth(self, i):
        return self

    def inner_text(self) -> str:
        return ""

    def get_attribute(self, name):
        return None

    def all_inner_texts(self):
        return []

    def fill(self, *a, **k): pass
    def click(self, *a, **k): pass
    def press(self, *a, **k): pass


class Request:
    def __init__(self, world: World):
        self.world = world

    def get(self, url: str, headers=None, max_redirects=None, **k) -> Resp:
        st, ct, data = self.world.reply(url)
        return Resp(st, ct, data, url)


class Context:
    def cookies(self, urls=None):
        return []

    def add_cookies(self, cookies):
        pass

    def close(self):
        pass


class Page:
    """Playwright-Seite als Attrappe: goto laedt den Inhalt der Route, CAS-Logins leiten sofort zum Dienst weiter."""

    def __init__(self, world: World):
        self.world = world
        self.url = "about:blank"
        self._content = ""
        self.request = Request(world)
        self.context = Context()

    def goto(self, url: str, wait_until=None, **k):
        u = urllib.parse.unquote(url) if False else url
        cas = "https://www.uni-hildesheim.de/sso/login?service="
        if url.startswith(cas):
            url = urllib.parse.unquote(url[len(cas):])
        self.url = url
        st, ct, data = self.world.reply(url)
        self._content = data.decode("utf-8", "replace") if st == 200 else ""

    def content(self) -> str:
        return self._content

    def wait_for_timeout(self, ms): pass
    def wait_for_load_state(self, *a, **k): pass
    def screenshot(self, **k): pass

    def evaluate(self, js: str, arg=None):
        if "navigator.userAgent" in js:
            return "Mozilla/5.0 Riesentest"
        if "M.cfg" in js:
            return True
        return None

    def locator(self, selector: str) -> Locator:
        return Locator(self, selector)


class PW:
    def __init__(self, page: Page):
        self.page = page
        self.chromium = self

    def launch_persistent_context(self, *a, **k):
        ctx = Context()
        ctx.new_page = lambda: self.page            # type: ignore[attr-defined]
        return ctx

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


# ---------------------------------------------------------------- Pruefung

class Tables(HTMLParser):
    """Tabellenzeilen einer Seite als Zellentexte (fuer qis.parse_grade_rows ohne Browser)"""

    def __init__(self):
        super().__init__()
        self.tables: list[list[list[str]]] = []
        self._row = None
        self._cell = None
        self._summary = ""

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "table":
            self.tables.append([]); self._summary = a.get("summary", "")
        elif tag == "tr":
            self._row = []
        elif tag in ("td", "th"):
            self._cell = ""

    def handle_endtag(self, tag):
        if tag in ("td", "th") and self._row is not None and self._cell is not None:
            self._row.append(self._cell); self._cell = None
        elif tag == "tr" and self._row is not None and self.tables:
            self.tables[-1].append(self._row); self._row = None

    def handle_data(self, data):
        if self._cell is not None:
            self._cell += data


def grade_rows(html_text: str) -> list[dict]:
    t = Tables()
    t.feed(html_text)
    out = []
    for rows in t.tables:
        out += qis.parse_grade_rows(rows, "")
    seen, uniq = set(), []
    for g in out:
        key = (g.get("pruefungsnr"), g.get("text"), g.get("semester"), g.get("versuch"))
        if key not in seen:
            seen.add(key); uniq.append(g)
    return uniq


def q(conn, sql, params=()):
    return db.rows(conn, sql, params)


def verify(acc: dict, conn, world: World, result: dict) -> None:
    e = acc["expected"]
    uni = acc["account"]["university"]
    checks = result["checks"]
    counts = result["counts"]
    strict = e["strict"]

    def check(name, ok, detail=None):
        checks[name] = {"ok": bool(ok)} | ({"detail": detail} if detail not in (None, [], {}, "") else {})

    # Module legt der PC erst beim naechsten Lesen an (ensure_modules in /api/modules, der Stud.IP-Abgleich schon in
    # auto_import); hier wie dieser naechste Aufruf, damit Learnweb-Kurse dieselbe Pruefung bekommen
    study.ensure_modules(conn)
    courses = {r["id"]: r for r in q(conn, "SELECT id, title, subject, kind, active, module_id FROM courses WHERE id != '__user__'")}
    modules = {r["id"]: r["name"] for r in q(conn, "SELECT id, name FROM modules")}
    files = {r["id"]: r for r in q(conn, "SELECT id, course_id, local_path, studip_folder, size FROM files WHERE course_id != '__user__'")}
    counts.update(courses=len(courses), modules=len(modules), files=len(files), downloaded=sum(1 for f in files.values() if f["local_path"]))

    # Kurse und Einordnung
    expected_courses = [c for c in e["courses_expected"] if uni == "luh" or (c["kind"] != "sonstiges" and not c.get("hidden"))]
    missing_courses = [c["db_id"] for c in expected_courses if c["db_id"] not in courses]
    check("courses_present", not missing_courses, missing_courses[:5])
    misses = []
    for c in expected_courses:
        row = courses.get(c["db_id"])
        if not row or not c["subject"]:
            continue
        exp_subject = c["subject"]
        if (row["subject"] or "") != exp_subject or (row["kind"] or "") != c["kind"]:
            misses.append({"title": c["title"], "subject": row["subject"], "kind": row["kind"], "expected": [exp_subject, c["kind"]]})
    counts["classify_misses"] = len(misses)
    check("classification", not misses, misses[:8])
    mod_names = sorted(set(modules.values()))
    # Module: je Fach eines, Kurs zeigt auf das Modul seines Fachs (nach der Einordnung, also mit deren Fehlern verglichen)
    dup_modules = [n for n in set(modules.values()) if list(modules.values()).count(n) > 1]
    check("modules_unique", not dup_modules, dup_modules)
    wrong_module = []
    for c in expected_courses:
        row = courses.get(c["db_id"])
        if not row or not row["active"] or row["kind"] == "sonstiges" or not row["subject"]:
            continue
        if row["module_id"] is None or modules.get(row["module_id"]) != row["subject"]:
            wrong_module.append(c["db_id"])
    check("course_has_module", not wrong_module, wrong_module[:5])
    counts["module_names"] = mod_names
    check("module_count", len(mod_names) == e["module_count"], {"got": len(mod_names), "expected": e["module_count"]})

    # Dateien: alles Erwartete da, nichts Verbotenes, Downloads da und auf der Platte
    expected_files = set(e["files_expected"])
    present = set(files)
    missing_files = sorted(expected_files - present)
    extra = sorted(present - expected_files - set(e["files_inactive"]))
    forbidden_present = sorted(present & set(e["files_forbidden"]))
    counts.update(files_expected=len(expected_files), files_missing=len(missing_files), files_extra=len(extra))
    check("files_complete", (not missing_files) if strict else True, {"missing": missing_files[:5], "strict": strict})
    check("no_forbidden_files", not forbidden_present, forbidden_present[:5])
    check("no_extra_files", not extra, extra[:5])
    downloadable = set(e["files_downloadable"])
    not_loaded = sorted(f for f in downloadable if f in files and not files[f]["local_path"])
    gone = [f for f in files.values() if f["local_path"] and not Path(f["local_path"]).exists()]
    counts.update(downloads_expected=len(downloadable), downloads_missing=len(not_loaded), downloads_file_gone=len(gone))
    check("downloads_complete", (not not_loaded) if strict else True, {"missing": not_loaded[:5]})
    check("downloads_on_disk", not gone, [g["id"] for g in gone][:5])
    wrong_course = [f for f, r in files.items() if f in e["files_meta"] and r["course_id"] != e["files_meta"][f]["course"]]
    check("files_in_right_course", not wrong_course, wrong_course[:5])

    # Stundenplan: jede Serie einmal
    series = q(conn, "SELECT id, course_id, title, weekday, start_time, end_time, rrule, source FROM course_events")
    dups = q(conn, "SELECT course_id, title, weekday, start_time, end_time, COUNT(*) n FROM course_events WHERE rrule != 'once' GROUP BY course_id, title, weekday, start_time, end_time HAVING n > 1")
    check("timetable_no_duplicates", not dups, [dict(d) for d in dups][:5])
    weekly = [s for s in series if s["rrule"] != "once"]
    counts.update(series_weekly=len(weekly), series_once=len(series) - len(weekly), series_personal=sum(1 for s in series if s["course_id"] is None))
    inactive_series = [s["id"] for s in series if s["course_id"] and s["course_id"] in courses and not courses[s["course_id"]]["active"]]
    check("timetable_only_active_courses", not inactive_series, inactive_series[:5])
    exceptions = q(conn, "SELECT type, note, COUNT(*) n FROM event_exceptions GROUP BY type, note")
    counts["exceptions"] = {f"{r['type']}|{r['note']}": r["n"] for r in exceptions}

    if uni == "luh":
        expected_weekly = e["series_own"] + e["personal"]
        counts["series_expected"] = expected_weekly
        check("timetable_series_count", len(weekly) == expected_weekly if strict else True, {"got": len(weekly), "expected": expected_weekly})
        ev = q(conn, "SELECT COUNT(*) n, SUM(COALESCE(cancelled,0)) c FROM studip_events")[0]
        counts.update(studip_events=ev["n"], cancelled=ev["c"] or 0)
        check("events_complete", ev["n"] == e["events_active"] if strict else True, {"got": ev["n"], "expected": e["events_active"]})
        check("cancellations_detected", (ev["c"] or 0) == e["cancelled_events"] if strict else True, {"got": ev["c"], "expected": e["cancelled_events"]})
        # Fristen aus Ankuendigungen
        ann = {r["id"]: json.loads(r["dates"] or "[]") for r in q(conn, "SELECT id, dates FROM announcements WHERE source='studip'")}
        found, miss = 0, []
        for d in e["deadlines_news"]:
            dates = ann.get(d["news"])
            if dates is None:
                miss.append({"news": d["news"], "why": "fehlt"}); continue
            if any(x["date"] == d["date"] and x["kind"] == d["kind"] for x in dates):
                found += 1
            else:
                miss.append({"news": d["news"], "expected": [d["date"], d["kind"]], "got": [[x["date"], x["kind"]] for x in dates]})
        counts.update(deadlines_news_expected=len(e["deadlines_news"]), deadlines_news_found=found, announcements=len(ann))
        check("deadlines_in_news", (not miss) if strict else True, miss[:5])
        dl = {r["id"] for r in q(conn, "SELECT id FROM deadlines WHERE source='studip'")}
        cw = [d["id"] for d in e["cw_deadlines"]]
        counts.update(cw_deadlines_expected=len(cw), cw_deadlines_found=sum(1 for i in cw if i in dl))
        few = e["courses_active"] <= 12
        check("courseware_deadlines", all(i in dl for i in cw) if (strict and few) else True, {"missing": [i for i in cw if i not in dl][:5], "checked": strict and few})
        texts = {r["kind"]: r["n"] for r in q(conn, "SELECT kind, COUNT(*) n FROM studip_texts GROUP BY kind")} if q(conn, "SELECT 1 FROM sqlite_master WHERE name='studip_texts'") else {}
        counts["texts"] = texts
        per = {r["kind"]: r["n"] for r in q(conn, "SELECT kind, COUNT(*) n FROM studip_periods GROUP BY kind")} if q(conn, "SELECT 1 FROM sqlite_master WHERE name='studip_periods'") else {}
        msgs = q(conn, "SELECT COUNT(*) n FROM studip_messages")[0]["n"] if q(conn, "SELECT 1 FROM sqlite_master WHERE name='studip_messages'") else 0
        counts.update(semesters=per.get("semester", 0), messages=msgs)
        ex = e["extras"]
        check("extras", (per.get("semester", 0) == ex.get("semesters", 0) and msgs == ex.get("messages", 0)) if strict else True, {"got": [per.get("semester", 0), msgs], "expected": ex})
        # QIS: Notenspiegel-Tabelle mit dem Parser des PC (ohne Browser)
        grades = grade_rows(next(v["body"] for k, v in acc["routes"].items() if "stg=079" in k))
        counts["grades"] = len(grades)
        exp_g = {(g["pruefungsnr"], g["text"]) for g in e["grades"]}
        got_g = {(g.get("pruefungsnr"), g.get("text")) for g in grades}
        check("qis_grades_parsed", got_g == exp_g, {"got": len(got_g), "expected": len(exp_g)})
    else:
        lw_files = {f for ids in e["learnweb_files"].values() for f in ids}
        dl = {r["id"]: r for r in q(conn, "SELECT id, course_id, kind, due_at FROM deadlines WHERE source='learnweb'")}
        exp_dl = [d["id"] for d in e["learnweb_deadlines"]]
        counts.update(deadlines_expected=len(exp_dl), deadlines_found=sum(1 for i in exp_dl if i in dl))
        check("learnweb_deadlines", all(i in dl and dl[i]["kind"] == "abgabe" for i in exp_dl), [i for i in exp_dl if i not in dl][:5])
        ann = {r["id"]: json.loads(r["dates"] or "[]") for r in q(conn, "SELECT id, dates FROM announcements WHERE source='learnweb'")}
        miss = [a["id"] for a in e["learnweb_announcements"] if a["id"] not in ann or not any(x["date"] == a["date"] and x["kind"] == a["kind"] for x in ann[a["id"]])]
        counts.update(announcements=len(ann), announcements_expected=len(e["learnweb_announcements"]))
        check("learnweb_announcements", not miss, miss[:5])
        lsf = [s for s in series if s["source"] == "lsf"]
        counts.update(lsf_series=len(lsf), lsf_expected=e["lsf_series"])
        check("lsf_series_count", len(lsf) == e["lsf_series"], {"got": len(lsf), "expected": e["lsf_series"]})
        exc = q(conn, "SELECT COUNT(*) n FROM event_exceptions WHERE note='fällt aus laut LSF'")[0]["n"]
        counts["lsf_cancelled"] = exc
        check("lsf_cancellations", exc == e["lsf_cancelled"], {"got": exc, "expected": e["lsf_cancelled"]})
        grades = grade_rows(acc["routes"][acc["account"]["lsf_base"] + "/qisserver/rds?state=notenspiegelStudent&nodeID=a"]["body"])
        counts["grades"] = len(grades)
        exp_g = {(g["pruefungsnr"], g["text"]) for g in e["grades"]}
        got_g = {(g.get("pruefungsnr"), g.get("text")) for g in grades}
        check("lsf_grades_parsed", got_g == exp_g, {"got": len(got_g), "expected": len(exp_g)})
    log = q(conn, "SELECT ok, message FROM sync_log ORDER BY id DESC LIMIT 1")
    result["sync_log"] = dict(log[0]) if log else None
    check("sync_ok", bool(log) and (log[0]["ok"] == 1 or not strict), result["sync_log"])


# ---------------------------------------------------------------- Lauf eines Kontos

class Patches:
    def __init__(self):
        self.saved = []

    def set(self, obj, name, value):
        self.saved.append((obj, name, getattr(obj, name)))
        setattr(obj, name, value)

    def undo(self):
        for obj, name, old in reversed(self.saved):
            setattr(obj, name, old)
        self.saved = []


def timed(phases: dict, name: str, fn):
    def wrapper(*a, **k):
        t = time.perf_counter()
        try:
            return fn(*a, **k)
        finally:
            phases[name] = phases.get(name, 0.0) + time.perf_counter() - t
    return wrapper


def run_account(path: Path, keep: bool) -> dict:
    acc = json.loads(path.read_text(encoding="utf-8"))
    a = acc["account"]
    uni = a["university"]
    world = World(acc)
    page = Page(world)
    result = {"index": a["index"], "university": uni, "program": a["program"], "flags": sorted(a["flags"]), "checks": {}, "counts": {}, "phases": {}, "errors": []}
    uid = ("%032x" % a["index"])
    data_dir = config.user_data_dir(uid, uni)
    if data_dir.exists():
        shutil.rmtree(data_dir)
    tok_user = config.set_user_context(uid, uni)
    tok_env = config.set_env_context({"STUDIP_USER": "synth", "STUDIP_PASSWORD": "x", "HILDESHEIM_USER": "synth", "HILDESHEIM_PASSWORD": "x",
                                      "LEARNWEB_TOKEN": a["token"], "HILDESHEIM_LEARNWEB_URL": a["learnweb_base"]})
    p = Patches()
    phases = result["phases"]
    started = time.perf_counter()
    try:
        p.set(study, "today", lambda: TODAY)
        p.set(studip_sync, "console_print", lambda line: None)       # Protokoll nur in die Datei, nicht auf die Konsole
        p.set(studip_sync.time, "sleep", lambda s: None)
        p.set(studip_sync, "sync_playwright", lambda: PW(page))
        p.set(hildesheim, "sync_playwright", lambda: PW(page))
        p.set(unilogin, "has_session", lambda name: False)
        p.set(unilogin, "restore", lambda ctx, name: 0)

        def download(page_, url, target, size=0):
            t = time.perf_counter()
            try:
                st, ct, data = world.reply(url)
                if st != 200:
                    raise RuntimeError(f"Download fehlgeschlagen ({st})")
                if data.lstrip()[:15].lower().startswith((b"<!doctype html", b"<html")) and not str(target).lower().endswith((".html", ".htm")):
                    raise RuntimeError("Statt der Datei kam eine Webseite zurueck")
                if studip_sync.empty_download(data, target, size):
                    raise RuntimeError("Leere Antwort statt der Datei")
                target.parent.mkdir(parents=True, exist_ok=True)
                part = target.with_name(target.name + ".part")
                part.write_bytes(data)
                os.replace(part, target)
            finally:
                phases["downloads"] = phases.get("downloads", 0.0) + time.perf_counter() - t
        p.set(studip_sync, "download", download)
        p.set(hildesheim, "_download", lambda page_, url, target, token="", size=0: download(page_, url, target, size))
        p.set(learnweb, "_urllib_post", lambda url, data, timeout=60: world.learnweb_post(url, data))
        for name in ("fetch_courses", "fetch_events", "fetch_news", "fetch_files", "fetch_folder_paths", "fetch_calendar_ids"):
            p.set(studip_sync, name, timed(phases, name, getattr(studip_sync, name)))
        p.set(studip_sync, "store_course_files", timed(phases, "store_files", studip_sync.store_course_files))
        p.set(timetable, "auto_import", timed(phases, "timetable", timetable.auto_import))
        p.set(studip_extras, "sync", timed(phases, "extras", studip_extras.sync))
        p.set(studip_texts, "run", timed(phases, "texts", studip_texts.run))
        p.set(lsf, "import_plan", timed(phases, "lsf_plan", lsf.import_plan))
        if uni == "luh":
            res = studip_sync.run_studip_sync()
        else:
            res = hildesheim.run_sync()
        result["sync"] = {"ok": res["ok"], "message": res["message"][:300], "new_files": len(res["new_files"])}
        with db.cursor() as conn:
            verify(acc, conn, world, result)
    except Exception as ex:  # noqa: BLE001
        result["errors"].append("".join(traceback.format_exception_only(type(ex), ex)).strip()[:500])
        result["traceback"] = traceback.format_exc()[-2000:]
    finally:
        p.undo()
        result["seconds"] = round(time.perf_counter() - started, 3)
        result["requests"] = world.requests
        try:
            log_text = (config.log_dir() / "sync.log").read_text(encoding="utf-8") if (config.log_dir() / "sync.log").exists() else ""
        except Exception:  # noqa: BLE001
            log_text = ""
        result["locked"] = log_text.count("database is locked")
        result["log_errors"] = [ln[:200] for ln in log_text.splitlines() if "FEHLER" in ln or "Fehler" in ln][:20]
        config.reset_env_context(tok_env)
        config.reset_user_context(tok_user)
        if not keep:
            shutil.rmtree(data_dir, ignore_errors=True)
    result["ok"] = not result["errors"] and all(c["ok"] for c in result["checks"].values()) and result["locked"] == 0
    result["within_budget"] = result["seconds"] <= BUDGET_SECONDS
    return result


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--shard", default="")
    ap.add_argument("--parallel", type=int, default=1)
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()
    files = sorted(Path(a.dir).glob("acc-*.json"))
    if a.limit:
        files = files[:a.limit]
    if a.parallel > 1:
        procs, parts = [], []
        for i in range(a.parallel):
            part = Path(a.out).with_name(Path(a.out).stem + f".teil{i}.json")
            parts.append(part)
            cmd = [sys.executable, __file__, "--dir", a.dir, "--out", str(part), "--shard", f"{i}/{a.parallel}", "--quiet"] + (["--limit", str(a.limit)] if a.limit else []) + (["--keep"] if a.keep else [])
            procs.append(subprocess.Popen(cmd, env={**os.environ, "RIESENTEST_TMP": str(TMP)}))
        t0 = time.perf_counter()
        for pr in procs:
            pr.wait()
        wall = time.perf_counter() - t0
        results = []
        for part in parts:
            results += json.loads(part.read_text(encoding="utf-8"))["accounts"]
        results.sort(key=lambda r: r["index"])
        write_summary(a, results, wall, parallel=a.parallel)
        return 0
    if a.shard:
        i, n = map(int, a.shard.split("/"))
        files = [f for k, f in enumerate(files) if k % n == i]
    results = []
    t0 = time.perf_counter()
    for f in files:
        r = run_account(f, a.keep)
        results.append(r)
        if not a.quiet:
            bad = [k for k, c in r["checks"].items() if not c["ok"]]
            print(f"#{r['index']:5d} {r['university']:10s} {r['seconds']:6.2f}s req={r['requests']:5d} files={r['counts'].get('files', '?')} "
                  f"{'OK' if r['ok'] else 'FEHLER ' + ', '.join(bad) + ' ' + '; '.join(r['errors'])[:160]}", flush=True)
    write_summary(a, results, time.perf_counter() - t0)
    return 0


def write_summary(a, results, wall, parallel=1):
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    rss_children = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    out = {"tool": "riesentest-python", "accounts": results, "wall_seconds": round(wall, 2), "parallel": parallel,
           "max_rss_mb": round(max(rss, rss_children) / (1024 * 1024), 1), "python": sys.version.split()[0], "tmp": str(TMP)}
    Path(a.out).write_text(json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
    n_ok = sum(1 for r in results if r["ok"])
    print(f"{len(results)} Konten, {n_ok} ok, Wanduhr {wall:.1f}s, RSS {out['max_rss_mb']} MB -> {a.out}")


if __name__ == "__main__":
    sys.exit(main())
