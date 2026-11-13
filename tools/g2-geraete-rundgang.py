#!/usr/bin/env python3
"""Rundgang ueber alle Geraete eines Pro-AI-Kontos (13.11.2026): Windows-App, iPad, iPhone und Web gleichzeitig gegen
einen lokalen Testdienst (tools/g2-testdienst.py).

- Windows: die echte Windows-App im Einzelplatzmodus mit eigenem Datenordner, Anmeldung mit E-Mail und Passwort,
  Abgleich ueber `app/sync_client.py` (tools/g2-windows-schritt.py).
- iPad und iPhone: derselbe Abgleich-Code wie in der App (`DeviceSync`, `StudoraAccount` aus UniFlowCore) mit je einer
  Datenbank-Datei, jedes Geraet mit eigener Anmeldung (`GeraeteRundgangTests`, swift test).
- Web: die Web-Oberflaeche des Dienstes ueber ihre HTTP-Schnittstelle.

Nur lokal, mit Wegwerf-Daten in einem Temp-Ordner; nichts geht ins Netz. Aufruf aus dem Repo:
    .venv/bin/python tools/g2-geraete-rundgang.py [--bericht pfad.json]
Vorher einmal: (cd apps/apple/Packages/UniFlowCore && swift build --build-tests) mit DEVELOPER_DIR auf Xcode.
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PY = sys.executable
CORE = ROOT / "apps/apple/Packages/UniFlowCore"
FILE = "studip-datei-0001"
WORK = Path(tempfile.mkdtemp(prefix="g2-rundgang-"))
CHECKS: list[dict] = []
LOG: list[str] = []


def log(msg: str) -> None:
    LOG.append(msg)
    print(msg, flush=True)


def check(area: str, what: str, ok: bool, detail: str = "") -> bool:
    CHECKS.append({"bereich": area, "pruefung": what, "ok": bool(ok), "detail": detail})
    log(f"  [{'OK ' if ok else 'FEHLT'}] {area}: {what}" + (f"  ({detail})" if detail else ""))
    return ok


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


PORT = free_port()
BASE = f"http://127.0.0.1:{PORT}"


def http(method: str, path: str, body=None, token: str | None = None) -> tuple[int, object]:
    req = urllib.request.Request(BASE + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json", **({"Authorization": f"Bearer {token}"} if token else {})})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, raw.decode(errors="replace")


def page(*ids: str) -> str:
    return json.dumps({"version": 2, "pages": {"p1": {"objects": [{"id": i, "type": "stroke", "points": [1, 2, 3, 4]} for i in ids]}},
                       "pageOrder": [{"key": "p1", "type": "pdf", "index": 1}], "deletedPages": [], "note": "",
                       "bookmarks": [], "outline": []})


def stroke_ids(data) -> list[str]:
    if isinstance(data, str):
        data = json.loads(data)
    return sorted(o.get("id") for o in ((data or {}).get("pages", {}).get("p1", {}).get("objects") or []))


SEED = [
    {"sql": "INSERT OR IGNORE INTO courses(id, title, semester) VALUES ('kurs-1', 'Mathematik I', 'WiSe 26/27')"},
    {"sql": "INSERT OR IGNORE INTO files(id, course_id, name, mime, status, download_url) VALUES "
            "(?, 'kurs-1', 'Blatt1.pdf', 'application/pdf', 'neu', 'https://studip.example/1')", "params": [FILE]},
    {"sql": "INSERT INTO modules(name, semester) SELECT 'Mathe I', 'WiSe 26/27' WHERE NOT EXISTS (SELECT 1 FROM modules)"},
]


class Device:
    kind = ""

    def __init__(self, name: str):
        self.name = name
        self.n = 0

    def step(self, actions: list[dict]) -> list[dict]:
        raise NotImplementedError

    def sync(self) -> dict:
        r = self.step([{"sync": True}])[0]["sync"]
        if not r.get("ok") or r.get("errors"):
            log(f"    ! Abgleich {self.name}: {r}")
        return r

    def q(self, sql: str) -> list[dict]:
        return self.step([{"query": sql, "name": "q"}])[0]["rows"]

    def strokes(self, file_id: str = FILE) -> list[str]:
        rows = self.q(f"SELECT data FROM annotations WHERE file_id='{file_id}'")
        return stroke_ids(rows[0]["data"]) if rows else []


class Apple(Device):
    """iPad oder iPhone: UniFlowCore-Abgleich mit eigener Datenbank-Datei und eigener Anmeldung."""

    def __init__(self, name: str, email: str, password: str, account: str):
        super().__init__(name)
        st, d = http("POST", "/api/account/login", {"email": email, "password": password, "device_id": name, "device_name": name})
        assert st == 200, d
        self.token, self.account, self.db = d["token"], account, WORK / f"{name}.sqlite"

    def step(self, actions):
        self.n += 1
        cmd, out = WORK / f"{self.name}-{self.n}.json", WORK / f"{self.name}-{self.n}.out.json"
        cmd.write_text(json.dumps({"base": BASE, "token": self.token, "device": self.name, "account": self.account,
                                   "db": str(self.db), "out": str(out), "actions": actions}))
        env = dict(os.environ, G2_SCHRITT=str(cmd), DEVELOPER_DIR=os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"))
        p = subprocess.run(["swift", "test", "--skip-build", "--filter", "GeraeteRundgangTests/testSchritt"], cwd=CORE, env=env,
                           capture_output=True, text=True)
        if p.returncode != 0 or not out.exists():
            raise RuntimeError(f"{self.name}: Schritt fehlgeschlagen\n{p.stdout[-3000:]}\n{p.stderr[-2000:]}")
        return json.loads(out.read_text())


class Windows(Device):
    """Windows-App: eigener Datenordner, Anmeldung mit E-Mail und Passwort, `sync_client.run`."""

    def __init__(self, name: str, email: str, password: str):
        super().__init__(name)
        self.dir = WORK / name
        self.dir.mkdir()
        self.env = dict(os.environ, LERNAPP_DATA_DIR=str(self.dir), LERNAPP_LOG_DIR=str(self.dir), LERNAPP_DESKTOP="1",
                        LERNAPP_ENV_FILE=str(self.dir / "leer.env"), UNIVERSITY="luh", LERNAPP_SERVICE_URL=BASE)
        self.env.pop("LERNAPP_MODE", None)
        r = self.step([{"login": {"email": email, "password": password}}])
        self.device_id, self.login = r[0]["login"]["device_id"], r[0]["login"]
        log(f"    {name}: angemeldet als {self.device_id}, Zustand {self.login.get('state')}, Tarif {self.login.get('plan')}")

    def step(self, actions):
        self.n += 1
        cmd, out = WORK / f"{self.name}-{self.n}.json", WORK / f"{self.name}-{self.n}.out.json"
        cmd.write_text(json.dumps({"out": str(out), "actions": actions}))
        p = subprocess.run([PY, str(ROOT / "tools/g2-windows-schritt.py"), str(cmd)], cwd=ROOT, env=self.env, capture_output=True, text=True)
        if p.returncode != 0 or not out.exists():
            raise RuntimeError(f"{self.name}: Schritt fehlgeschlagen\n{p.stdout[-3000:]}\n{p.stderr[-3000:]}")
        return json.loads(out.read_text())


def sync_all(*devices: Device) -> None:
    for d in devices:
        d.sync()


def main() -> int:
    bericht = Path(sys.argv[sys.argv.index("--bericht") + 1]) if "--bericht" in sys.argv else None
    service = subprocess.Popen([PY, str(ROOT / "tools/g2-testdienst.py"), str(PORT)], cwd=ROOT, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True)
    try:
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", PORT), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)
        return run(bericht)
    finally:
        service.terminate()
        service.wait(timeout=10)


def run(bericht: Path | None) -> int:
    t0 = time.time()
    st, acc = http("POST", "/__test/account", {"plan": "pro_ai"})
    assert st == 200, acc
    email, pw, uid = acc["email"], acc["password"], acc["id"]
    log(f"Testkonto (Pro AI) {email}, Arbeitsordner {WORK}")

    # ---------------------------------------------------------------- 0. Anmelden, erster Abgleich
    log("\n0. Alle Geraete melden sich an und gleichen zum ersten Mal ab")
    win = Windows("windows", email, pw)
    ipad = Apple("ipad-rundgang01", email, pw, uid)
    iphone = Apple("iphone-rundgang01", email, pw, uid)
    st, webd = http("POST", "/api/account/login", {"email": email, "password": pw, "device_id": "web-rundgang", "device_name": "Web"})
    web = webd["token"]
    for d in (win, ipad, iphone):
        d.step(SEED)
    sync_all(win, ipad, iphone, win, ipad)
    for d in (win, ipad, iphone):
        names = [r["name"] for r in d.q("SELECT name FROM modules ORDER BY name")]
        check("Erster Abgleich", f"{d.name}: Modul 'Mathe I' genau einmal (keine Doppelten)", names == ["Mathe I"], str(names))

    # ---------------------------------------------------------------- 1. Notizen
    log("\n1. Notizen auf einer Hochschul-PDF")
    ipad.step([{"sql": "INSERT INTO annotations(file_id, data, version) VALUES (?, ?, 1)", "params": [FILE, page("ipad-1")]}])
    sync_all(ipad, win, iphone)
    check("Notizen", "iPad schreibt -> Windows sieht", win.strokes() == ["ipad-1"], str(win.strokes()))
    check("Notizen", "iPad schreibt -> iPhone sieht", iphone.strokes() == ["ipad-1"], str(iphone.strokes()))
    st, a = http("GET", f"/api/files/{FILE}/annotations", token=web)
    check("Notizen", "iPad schreibt -> Web sieht", st == 200 and stroke_ids(a.get("data")) == ["ipad-1"], f"{st} {stroke_ids(a.get('data')) if st == 200 else a}")

    win.step([{"sql": "UPDATE annotations SET data=?, version=version+1 WHERE file_id=?", "params": [page("ipad-1", "win-1"), FILE]}])
    sync_all(win, ipad, iphone)
    check("Notizen", "Windows schreibt -> iPad sieht", ipad.strokes() == ["ipad-1", "win-1"], str(ipad.strokes()))
    check("Notizen", "Windows schreibt -> iPhone sieht", iphone.strokes() == ["ipad-1", "win-1"], str(iphone.strokes()))

    # gleichzeitig auf iPad und iPhone, ohne Abgleich dazwischen
    ipad.step([{"sql": "UPDATE annotations SET data=?, version=version+1 WHERE file_id=?", "params": [page("ipad-1", "win-1", "ipad-2"), FILE]}])
    iphone.step([{"sql": "UPDATE annotations SET data=?, version=version+1 WHERE file_id=?", "params": [page("ipad-1", "win-1", "iphone-1"), FILE]}])
    r_ipad = ipad.sync()
    r_iphone = iphone.sync()
    sync_all(ipad, win)
    want = sorted(["iphone-1", "ipad-1", "ipad-2", "win-1"])
    for d in (win, ipad, iphone):
        check("Notizen", f"gleichzeitig auf iPad und iPhone -> {d.name} hat beide Striche", d.strokes() == want, str(d.strokes()))
    log(f"    (iPhone hat zusammengefuehrt: {r_iphone.get('notes_merged')} Dokument, Konflikte {r_iphone.get('conflicts')})")

    st, a = http("GET", f"/api/files/{FILE}/annotations", token=web)
    doc = a["data"]
    doc["pages"]["p1"]["objects"].append({"id": "web-1", "type": "stroke", "points": [5, 6, 7, 8]})
    st, put = http("PUT", f"/api/files/{FILE}/annotations?base_version={a['version']}", doc, token=web)
    check("Notizen", "Web speichert eine Notiz", st == 200, f"{st}")
    sync_all(win, ipad, iphone)
    want = sorted(want + ["web-1"])
    for d in (win, ipad, iphone):
        check("Notizen", f"Web schreibt -> {d.name} sieht", d.strokes() == want, str(d.strokes()))

    # ---------------------------------------------------------------- 2. Lernkalender
    log("\n2. Lernkalender (Lernpakete)")
    win.step([{"sql": "INSERT INTO study_packages(date, module_id, subject, title, planned_minutes, generated) "
                      "VALUES ('2026-11-20', (SELECT id FROM modules WHERE name='Mathe I'), 'Mathe I', 'Blatt 3 rechnen', 90, 0)"}])
    sync_all(win, ipad, iphone)
    pk = "SELECT p.date, p.title, p.status, m.name AS modul FROM study_packages p LEFT JOIN modules m ON m.id=p.module_id WHERE p.title='{}'"
    for d in (ipad, iphone):
        rows = d.q(pk.format("Blatt 3 rechnen"))
        check("Lernkalender", f"Windows plant -> {d.name} sieht (Tag und Modul)",
              len(rows) == 1 and rows[0]["date"] == "2026-11-20" and rows[0]["modul"] == "Mathe I", str(rows))
    ipad.step([{"sql": "UPDATE study_packages SET date='2026-11-21' WHERE title='Blatt 3 rechnen'"}])
    sync_all(ipad, win, iphone)
    for d in (win, iphone):
        rows = d.q(pk.format("Blatt 3 rechnen"))
        check("Lernkalender", f"iPad verschiebt -> {d.name} sieht neuen Tag", [r["date"] for r in rows] == ["2026-11-21"], str(rows))
    iphone.step([{"sql": "UPDATE study_packages SET status='erledigt' WHERE title='Blatt 3 rechnen'"}])
    sync_all(iphone, win, ipad)
    for d in (win, ipad):
        rows = d.q(pk.format("Blatt 3 rechnen"))
        check("Lernkalender", f"iPhone hakt ab -> {d.name} sieht erledigt", [r["status"] for r in rows] == ["erledigt"], str(rows))
    st, wp = http("POST", "/api/packages", {"date": "2026-11-22", "title": "Wiederholung Kapitel 2", "subject": "Mathe I", "minutes": 60}, token=web)
    check("Lernkalender", "Web legt Lernpaket an", st == 200, str(st))
    sync_all(win, ipad, iphone)
    for d in (win, ipad, iphone):
        rows = d.q("SELECT p.date, t.title AS aufgabe FROM study_packages p LEFT JOIN study_tasks t ON t.package_id=p.id "
                   "WHERE p.date='2026-11-22'")
        check("Lernkalender", f"Web plant -> {d.name} sieht (mit Aufgabe)", len(rows) == 1 and rows[0]["aufgabe"], str(rows))
    win.step([{"sql": "DELETE FROM study_tasks WHERE package_id IN (SELECT id FROM study_packages WHERE date='2026-11-22')"},
              {"sql": "DELETE FROM study_packages WHERE date='2026-11-22'"}])
    sync_all(win, ipad, iphone)
    for d in (ipad, iphone):
        rows = d.q("SELECT id FROM study_packages WHERE date='2026-11-22'")
        check("Lernkalender", f"Windows loescht -> bei {d.name} weg", rows == [], str(rows))

    # ---------------------------------------------------------------- 3. Karteikarten
    log("\n3. Karteikarten")
    iphone.step([{"sql": "INSERT INTO flashcard_stacks(name, subject, created_at, kind) VALUES ('Analysis', 'Mathe I', '2026-11-13', 'eigene')"},
                 {"sql": "INSERT INTO flashcards(subject, question, answer, created_at, box, due, stack_id) VALUES "
                         "('Mathe I', 'Was ist eine Ableitung?', 'Grenzwert des Differenzenquotienten', '2026-11-13', 1, '2026-11-13', "
                         "(SELECT id FROM flashcard_stacks WHERE name='Analysis'))"}])
    sync_all(iphone, win, ipad)
    cq = ("SELECT s.name AS stapel, c.question, c.box, c.due FROM flashcards c LEFT JOIN flashcard_stacks s ON s.id=c.stack_id "
          "ORDER BY c.question")
    for d in (win, ipad):
        rows = d.q(cq)
        check("Karteikarten", f"iPhone legt Karte an -> {d.name} sieht (im Stapel)",
              len(rows) == 1 and rows[0]["stapel"] == "Analysis", str(rows))
    win.step([{"sql": "UPDATE flashcards SET box=3, due='2026-11-25' WHERE question='Was ist eine Ableitung?'"}])
    sync_all(win, ipad, iphone)
    for d in (ipad, iphone):
        rows = d.q(cq)
        check("Karteikarten", f"Windows lernt (Fach 3) -> {d.name} sieht Lernstand", [(r["box"], r["due"]) for r in rows] == [(3, "2026-11-25")], str(rows))
    st, stacks = http("GET", "/api/flashcard-stacks", token=web)
    sid = next((s["id"] for s in stacks if s.get("name") == "Analysis"), None) if st == 200 else None
    check("Karteikarten", "Web sieht den Stapel vom iPhone", sid is not None, f"{st}")
    st, _ = http("POST", "/api/flashcards", {"stack_id": sid, "cards": [{"question": "Was ist ein Integral?", "answer": "Flaeche unter der Kurve"}]}, token=web)
    check("Karteikarten", "Web legt Karte an", st == 200, str(st))
    sync_all(win, ipad, iphone)
    for d in (win, ipad, iphone):
        rows = d.q(cq)
        check("Karteikarten", f"Web legt an -> {d.name} hat 2 Karten im Stapel",
              [r["stapel"] for r in rows] == ["Analysis", "Analysis"], str([(r["stapel"], r["question"]) for r in rows]))
    ipad.step([{"sql": "DELETE FROM flashcards WHERE question='Was ist eine Ableitung?'"}])
    sync_all(ipad, win, iphone)
    for d in (win, iphone):
        rows = d.q(cq)
        check("Karteikarten", f"iPad loescht -> bei {d.name} weg", [r["question"] for r in rows] == ["Was ist ein Integral?"], str(rows))
    st, cards = http("GET", "/api/flashcards", token=web)
    qs = sorted(c.get("question") for c in (cards if isinstance(cards, list) else cards.get("cards", []))) if st == 200 else cards
    check("Karteikarten", "iPad loescht -> im Web weg", qs == ["Was ist ein Integral?"], str(qs))

    # ---------------------------------------------------------------- 4. Eigene Dokumente
    log("\n4. Eigene Dokumente (importierte PDF, Notizbuch)")
    ipad.step([{"sql": "INSERT OR IGNORE INTO courses(id, title) VALUES ('__user__', 'Eigene Dokumente')"},
               {"sql": "INSERT INTO files(id, course_id, name, mime, local_path, status) VALUES "
                       "('eigen-pdf-1', '__user__', 'Mitschrift.pdf', 'application/pdf', '/eigene/Mitschrift.pdf', 'neu')"},
               {"sql": "INSERT INTO files(id, course_id, name, mime, status) VALUES "
                       "('notizbuch-1', '__user__', 'Notizbuch Lineare Algebra', 'application/x-studinow-notebook', 'neu')"},
               {"sql": "INSERT INTO annotations(file_id, data, version) VALUES ('eigen-pdf-1', ?, 1)", "params": [page("ipad-eigen")]},
               {"sql": "INSERT INTO annotations(file_id, data, version) VALUES ('notizbuch-1', ?, 1)", "params": [page("ipad-heft")]}])
    sync_all(ipad, win, iphone)
    for d in (win, iphone):
        f = d.q("SELECT id FROM files WHERE course_id='__user__'")
        n = d.q("SELECT file_id FROM annotations WHERE file_id IN ('eigen-pdf-1', 'notizbuch-1')")
        check("Eigene Dokumente", f"iPad importiert PDF und Notizbuch -> {d.name} sieht sie", bool(f) and len(n) == 2,
              f"Dateien {len(f)}, Notizen {len(n)}")
    st, _ = http("GET", "/api/files/eigen-pdf-1/annotations", token=web)
    check("Eigene Dokumente", "iPad importiert PDF -> Web sieht sie", st == 200, f"Antwort {st}")

    # ---------------------------------------------------------------- 5. Mehr als drei Geraete
    log("\n5. Viertes und fuenftes Geraet")
    ipad2 = Apple("ipad-zweites01", email, pw, uid)
    ipad2.step(SEED)
    r = ipad2.sync()
    win2 = Windows("windows-zweiter", email, pw)
    win2.step(SEED)
    r2 = win2.sync()
    st, me = http("GET", "/api/account/me", token=web)
    n_sessions = len(me.get("sessions") or []) if st == 200 else -1
    names = sorted(s.get("device_name") or s.get("device_id") or "?" for s in (me.get("sessions") or [])) if st == 200 else []
    check("Geraete-Grenze", "4. Geraet (2. iPad) wird abgewiesen", not r.get("ok"), f"4. Geraet gleicht ab: {r.get('ok')}")
    check("Geraete-Grenze", "5. Geraet (2. Windows-PC) wird abgewiesen", not r2.get("ok"),
          f"5. Geraet gleicht ab: {r2.get('ok')}; Anmeldungen im Konto: {n_sessions} {names}")
    check("Geraete-Grenze", "(Kontrolle) 4. Geraet bekommt alle Notizen", ipad2.strokes() == want, str(ipad2.strokes()))
    check("Geraete-Grenze", "(Kontrolle) 5. Geraet bekommt alle Notizen", win2.strokes() == want, str(win2.strokes()))

    # ---------------------------------------------------------------- 6. Anmeldewege
    log("\n6. Verschiedene Anmeldewege (Apple, Google, E-Mail)")
    probe = subprocess.run([PY, "-c", ANMELDEWEGE], cwd=ROOT, capture_output=True, text=True,
                           env=dict(os.environ, LERNAPP_MODE="hosted", LERNAPP_DATA_DIR=str(WORK / "konten"),
                                    LERNAPP_LOG_DIR=str(WORK / "konten"), LERNAPP_ENV_FILE=str(WORK / "konten/leer.env")))
    try:
        res = json.loads(probe.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        res = {}
        log(probe.stdout[-2000:] + probe.stderr[-2000:])
    check("Anmeldewege", "Apple mit derselben (bestaetigten) E-Mail -> dasselbe Konto", res.get("apple_same_email") is True, str(res))
    check("Anmeldewege", "Google mit derselben (bestaetigten) E-Mail -> dasselbe Konto", res.get("google_same_email") is True)
    check("Anmeldewege", "Apple mit 'E-Mail verbergen' -> dasselbe Konto", res.get("apple_hidden_email") is True,
          "neues, getrenntes Konto" if res.get("apple_hidden_email") is False else "")

    ok = sum(c["ok"] for c in CHECKS)
    log(f"\nErgebnis: {ok} von {len(CHECKS)} Pruefungen erfuellt, Dauer {time.time() - t0:.0f} s")
    if bericht:
        bericht.write_text(json.dumps({"checks": CHECKS, "log": LOG}, ensure_ascii=False, indent=1), encoding="utf-8")
    return 0


ANMELDEWEGE = r"""
import json, os
from pathlib import Path
Path(os.environ["LERNAPP_DATA_DIR"]).mkdir(parents=True, exist_ok=True)
from app import accounts
u = accounts.register("studi@example.org", "sehr-geheim-123", "luh")
accounts.mark_email_verified(u["id"])
a, _, _ = accounts.login_with_provider("apple", "apple-sub-1", "studi@example.org", True, "luh")
g, _, _ = accounts.login_with_provider("google", "google-sub-1", "studi@example.org", True, "luh")
h, _, _ = accounts.login_with_provider("apple", "apple-sub-2", "x7k2p9@privaterelay.appleid.com", True, "luh")
print(json.dumps({"apple_same_email": a["id"] == u["id"], "google_same_email": g["id"] == u["id"],
                  "apple_hidden_email": h["id"] == u["id"]}))
"""

if __name__ == "__main__":
    sys.exit(main())
