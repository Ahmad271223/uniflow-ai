#!/usr/bin/env python3
"""Echter Lauf der Windows-App gegen den Dienst, ohne Attrappen (12.11.2026, docs/WINDOWS-FERTIG-2026-11-12.md).

Startet als eigene Prozesse auf 127.0.0.1 (freie Ports, Temp-Ordner, nichts vom Server des Inhabers auf Port 8765):
  - den Dienst (LERNAPP_MODE=hosted, Mail ins Protokoll),
  - zwei "Windows-PCs" (LERNAPP_DESKTOP=1, je eigene Datenbank, Konto-Pflicht wie in der App),
und nutzt ein "iPad" und ein zweites Konto B ueber die API des Dienstes (Bearer-Token, X-StudiNow-Client: ios).
Das Sitzungs-Token der Windows-Simulation liegt in einer Datei im Temp-Ordner, nie in der echten Windows-
Anmeldeinformationsverwaltung (Ziel "StudiNow/dienst-sitzung" gehoert der echten App).

Pruefen:
  Konto: anlegen (iPad-Seite), Anmelden an beiden PCs, Probe/Tarif, Token nicht in der Zustandsdatei, Abmelden.
  Abgleich: Modul und Notiz von PC 1 auf PC 2 und das "iPad"; gleichzeitige Aenderung derselben Notiz auf drei Geraeten
            (kein Strich geht verloren); Loeschen eines Moduls wandert mit.
  Community: PDFs melden, Kurs beitreten, Loesung von PC 1 veroeffentlichen (echtes Paket, Referenz solution_format.py),
            Konto B ("iPad") liest, laedt, liked, kommentiert; PC 2 desselben Kontos sieht Mitteilungen und antwortet;
            Fragen und Antworten in beide Richtungen.
Nicht geprueft (nur auf echten Geraeten): Apple-Anmeldung, StoreKit, Pencil, WebView2, Installer, CloudKit.

Aufruf (aus der Repo-Wurzel):  python tools/e2e-windows-konto.py        Ende mit Code 0 nur, wenn alles stimmt.
"""
from __future__ import annotations

import json
import os
import re
import secrets
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PW = "Lauf-" + secrets.token_urlsafe(12)       # nur fuer die Wegwerf-Konten dieses Laufs, jedes Mal neu
IOS = {"X-StudiNow-Client": "ios"}


# ---------------------------------------------------------------- Server (Unterbefehl --serve)

def serve(mode: str, port: int, data: Path, service_url: str | None) -> None:
    data.mkdir(parents=True, exist_ok=True)
    os.environ.update({"LERNAPP_DATA_DIR": str(data / "data"), "LERNAPP_LOG_DIR": str(data / "logs"),
                       "LERNAPP_ENV_FILE": str(data / ".env"), "LERNAPP_NO_SCHEDULER": "1", "LERNAPP_OCR": "off",
                       "LERNAPP_ALLOWED_HOSTS": f"127.0.0.1:{port},127.0.0.1,localhost"})
    if mode == "hosted":
        os.environ.update({"LERNAPP_MODE": "hosted", "LERNAPP_MAIL": "log", "LERNAPP_JOBS": "off"})
    else:
        os.environ.update({"LERNAPP_DESKTOP": "1", "LERNAPP_SERVICE_URL": service_url or ""})
    sys.path.insert(0, str(ROOT))
    from app import token_store
    token_store.use(token_store.FileStore(data / "service-token"))
    import uvicorn
    uvicorn.run("app.server:app", host="127.0.0.1", port=port, log_level="warning", access_log=False)


# ---------------------------------------------------------------- HTTP

def req(base: str, method: str, path: str, body=None, token: str | None = None, headers: dict | None = None):
    h = {"Content-Type": "application/json"}
    if token:
        h["Authorization"] = "Bearer " + token
    h.update(headers or {})
    data = None if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
    r = urllib.request.Request(base + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=90) as resp:
            b = resp.read()
            return resp.status, (json.loads(b) if b else None)
    except urllib.error.HTTPError as e:
        b = e.read()
        try:
            return e.code, json.loads(b)
        except ValueError:
            return e.code, b[:300]


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_up(base: str, proc: subprocess.Popen, what: str) -> None:
    end = time.time() + 90
    while time.time() < end:
        if proc.poll() is not None:
            raise SystemExit(f"{what} ist beim Start beendet (Code {proc.returncode})")
        try:
            if req(base, "GET", "/api/account/info")[0] == 200:
                return
        except OSError:
            pass
        time.sleep(0.5)
    raise SystemExit(f"{what} ist nach 90 s nicht erreichbar")


# ---------------------------------------------------------------- Pruefungen

RESULTS: list[tuple[bool, str]] = []


def check(ok: bool, label: str, detail: str = "") -> bool:
    RESULTS.append((bool(ok), label))
    print(("  OK    " if ok else "  FEHLER ") + label + ((" -> " + detail) if (detail and not ok) else ""))
    return bool(ok)


def ids_of(doc: dict | None) -> list[str]:
    return sorted(o["id"] for p in (doc or {}).get("pages", {}).values() for o in p.get("objects", []))


def note(doc_ids: list[str]) -> dict:
    return {"version": 2, "pages": {"p1": {"objects": [{"id": i, "type": "stroke", "points": [1, 2, 3, 4]} for i in doc_ids]}},
            "pageOrder": [{"key": "p1", "type": "pdf", "index": 1}], "deletedPages": [], "note": "", "bookmarks": [], "outline": []}


def sync_until_quiet(pcs: list[str], rounds: int = 4) -> None:
    for _ in range(rounds):
        busy = 0
        for pc in pcs:
            s, d = req(pc, "POST", "/api/studora/sync", {})
            busy += int(isinstance(d, dict) and (d.get("pulled", 0) or d.get("pushed", 0) or d.get("applied", 0)))
        if not busy:
            return


def seed_course_and_pdf(data_dir: Path, pdf_path: Path, file_id: str) -> None:
    db = data_dir / "data" / "lernapp.db"
    d = data_dir / "data" / "files" / "kurs-1"
    d.mkdir(parents=True, exist_ok=True)
    p = d / pdf_path.name
    shutil.copy(pdf_path, p)
    c = sqlite3.connect(db, timeout=60)
    try:
        c.execute("INSERT OR IGNORE INTO courses(id, title, semester) VALUES ('kurs-1', 'Mathematik I', 'WiSe 26/27')")
        c.execute("INSERT OR REPLACE INTO files(id, course_id, name, mime, status, download_url, local_path, downloaded_at, kind, title, "
                  "page_count, seen_by_user, size) VALUES (?,'kurs-1','Blatt.pdf','application/pdf','gelesen','https://studip.example/f',?,"
                  "datetime('now'),'pdf','Uebungsblatt',2,1,?)", (file_id, str(p), p.stat().st_size))
        c.commit()
    finally:
        c.close()


def run() -> int:
    tmp = Path(tempfile.mkdtemp(prefix="studinow-e2e-"))
    procs: list[subprocess.Popen] = []
    try:
        ph, p1, p2 = free_port(), free_port(), free_port()
        H, W1, W2 = (f"http://127.0.0.1:{p}" for p in (ph, p1, p2))
        py = sys.executable
        env = dict(os.environ, PYTHONIOENCODING="utf-8")

        def spawn(*args):
            logf = open(tmp / f"{Path(str(args[2])).name}-{args[1]}.log", "wb")
            pr = subprocess.Popen([py, str(Path(__file__).resolve()), "--serve", *map(str, args)], cwd=str(ROOT), env=env, stdout=logf, stderr=logf)
            procs.append(pr)
            return pr
        print(f"Temp-Ordner {tmp}\nDienst {H}, Windows 1 {W1}, Windows 2 {W2}")
        h = spawn("hosted", ph, tmp / "dienst")
        w1 = spawn("desktop", p1, tmp / "pc1", H)
        w2 = spawn("desktop", p2, tmp / "pc2", H)
        wait_up(H, h, "Dienst"); wait_up(W1, w1, "Windows 1"); wait_up(W2, w2, "Windows 2")

        print("\n== Konto")
        email = f"e2e-{int(time.time())}@example.test"
        s, d = req(H, "POST", "/api/account/register", {"email": email, "password": PW, "university": "luh", "device_name": "iPad Testgeraet"}, headers=IOS)
        check(s == 201 and d.get("token"), "Konto auf dem 'iPad' angelegt", str(d)[:200])
        ipad = d["token"]
        mail = (tmp / "dienst" / "logs" / "mail.log").read_text(encoding="utf-8", errors="replace")
        tok = re.findall(r"verify=([A-Za-z0-9_-]+)", mail)[-1]
        check(req(H, "POST", "/api/account/verify-email", {"token": tok})[0] == 200, "E-Mail ueber den Link aus der Willkommensmail bestaetigt")
        s, st = req(W1, "GET", "/api/app-account/status")
        check(s == 200 and st["state"] == "signed_out" and st["locked"], "Windows 1 ohne Anmeldung: gesperrt, nur Anmeldebildschirm")
        s, pv = req(W1, "GET", "/api/app-account/providers")
        check(s == 200 and pv["reachable"] and pv["apple_browser"] is False, "Windows fragt den Dienst nach Anmeldewegen im Browser", str(pv))
        for name, pc in (("Windows 1", W1), ("Windows 2", W2)):
            s, st = req(pc, "POST", "/api/app-account/login", {"email": email, "password": PW})
            check(s == 200 and st["signed_in"] and st["state"] == "trial" and st["plan"] == "pro_ai", f"{name}: angemeldet, Probe mit Rechten wie Pro AI", str(st)[:200])
        sj = (tmp / "pc1" / "data" / "service-account.json").read_text(encoding="utf-8")
        check(PW not in sj and '"token"' not in sj and (tmp / "pc1" / "service-token").exists(), "Passwort und Token stehen nicht in der Zustandsdatei")
        s, devs = req(W1, "GET", "/api/studora/devices")
        check(s == 200 and len(devs["sessions"]) >= 3, "Geraeteliste im Dienst: iPad und beide PCs", str(devs)[:200])

        print("\n== Abgleich Notizen und Module")
        from pypdf import PdfWriter
        pdf = tmp / "blatt.pdf"
        wr = PdfWriter()
        for _ in range(2):
            wr.add_blank_page(595, 842)
        wr.add_metadata({"/Title": "Uebungsblatt"})
        with open(pdf, "wb") as f:
            wr.write(f)
        import hashlib
        sha = hashlib.sha256(pdf.read_bytes()).hexdigest()
        FILE = "studip-datei-e2e-1"
        for d_ in ("pc1", "pc2"):
            seed_course_and_pdf(tmp / d_, pdf, FILE)
        s, m = req(W1, "POST", "/api/modules", {"name": "Analysis I", "semester": "WiSe 26/27"})
        check(s == 200 and m.get("id"), "PC 1: Modul angelegt")
        mod_id = m["id"]
        check(req(W1, "PUT", f"/api/files/{FILE}/annotations", note(["a1", "a2"]))[0] == 200, "PC 1: zwei Striche geschrieben")
        sync_until_quiet([W1, W2])
        s, a = req(W2, "GET", f"/api/files/{FILE}/annotations")
        check(ids_of(a.get("data")) == ["a1", "a2"], "PC 2 hat die Notiz von PC 1", str(ids_of(a.get("data"))))
        s, mods = req(W2, "GET", "/api/modules")
        names = [x.get("name") for x in (mods if isinstance(mods, list) else mods.get("modules", []))]
        check("Analysis I" in names, "PC 2 hat das Modul von PC 1", str(names))
        s, ch = req(H, "GET", "/api/sync/changes?limit=2000", token=ipad)
        check(s == 200 and any(x["file_id"] == FILE for x in ch["changes"].get("annotations", [])) and ch["changes"].get("modules"),
              "Das 'iPad' sieht Notiz und Modul beim Dienst")
        # gleichzeitig: PC 1 + b1, PC 2 + c1, iPad + i1 (alle auf Basis desselben Stands)
        s, c1 = req(W1, "GET", f"/api/files/{FILE}/annotations")
        s, c2 = req(W2, "GET", f"/api/files/{FILE}/annotations")
        req(W1, "PUT", f"/api/files/{FILE}/annotations?base_version={c1['version']}", note(["a1", "a2", "b1"]))
        req(W2, "PUT", f"/api/files/{FILE}/annotations?base_version={c2['version']}", note(["a1", "a2", "c1"]))
        s, ch = req(H, "GET", "/api/sync/changes?limit=2000", token=ipad)
        ann = [x for x in ch["changes"]["annotations"] if x["file_id"] == FILE][0]
        doc = json.loads(ann["data"]) if isinstance(ann["data"], str) else ann["data"]
        doc["pages"]["p1"]["objects"].append({"id": "i1", "type": "stroke", "points": [9, 9, 9, 9]})
        s, pr = req(H, "POST", "/api/sync/push", {"device_id": "ipad-e2e", "items": [{"entity": "annotations", "id": FILE, "base_version": ann["sync_version"],
                    "updated_at": "2026-11-12T12:40:00.000Z", "data": doc, "op_id": "ipad-e2e-op-0001"}], "deletes": []}, token=ipad)
        check(s == 200, "'iPad' sendet seinen Strich", str(pr)[:200])
        sync_until_quiet([W1, W2], rounds=6)
        for name, pc in (("PC 1", W1), ("PC 2", W2)):
            s, a = req(pc, "GET", f"/api/files/{FILE}/annotations")
            check(ids_of(a.get("data")) == ["a1", "a2", "b1", "c1", "i1"], f"{name}: alle fuenf Striche nach gleichzeitiger Aenderung auf drei Geraeten", str(ids_of(a.get("data"))))
        s, ch = req(H, "GET", "/api/sync/changes?limit=2000", token=ipad)
        ann = [x for x in ch["changes"]["annotations"] if x["file_id"] == FILE][0]
        check(ids_of(json.loads(ann["data"]) if isinstance(ann["data"], str) else ann["data"]) == ["a1", "a2", "b1", "c1", "i1"], "Dienst/'iPad': derselbe Stand")
        req(W1, "DELETE", f"/api/modules/{mod_id}")
        sync_until_quiet([W1, W2])
        s, mods = req(W2, "GET", "/api/modules")
        names = [x.get("name") for x in (mods if isinstance(mods, list) else mods.get("modules", []))]
        check("Analysis I" not in names, "Geloeschtes Modul verschwindet auch auf PC 2", str(names))

        print("\n== Community (Windows <-> anderes Konto auf dem 'iPad')")
        for pc in (W1, W2):
            req(pc, "POST", "/api/studora/claims", {})
        s, keys = req(W1, "GET", "/api/courses/community-keys")
        key = keys["courses"][0]["key"]
        s, info = req(W1, "GET", "/api/community/info")
        check(s == 200 and info["plan_ok"] and info["can_share"], "Community ueber den Dienst erreichbar, Rechte in der Probe", str(info)[:200])
        # wie die Oberflaeche (community-spaces.js): erst die Kursschluessel melden, dann beitreten
        req(W1, "POST", "/api/community/claims", {"fingerprints": [], "course_keys": [key]})
        s, jn = req(W1, "POST", f"/api/community/communities/{key}/join", {"kind": "course"})
        check(s == 200, "PC 1 tritt der Kurs-Community bei", str(jn)[:200])
        from app import solution_format as sf
        sid = "6f1c1c0e-0000-4000-8000-00000000e2e1"
        stroke = {"id": "s1", "type": "stroke", "tool": "pen", "color": "#1f6fe0", "width": 2.2, "opacity": 1, "points": [50, 60, 200, 90, 300, 400],
                  "x": 0, "y": 0, "rotation": 0, "scaleX": 1, "scaleY": 1}
        content = {"format": sf.CONTENT_FORMAT, "formatVersion": 1, "solutionId": sid, "createdAt": "2026-11-12T10:00:00Z", "title": "Uebungsblatt",
                   "displayName": "", "document": {"sha256": sha, "pageCount": 2},
                   "pages": [{"key": "p1", "kind": "pdf", "pdfIndex": 1, "width": 595, "height": 842, "rotation": 0, "extraRotation": 0, "objects": [stroke]}],
                   "images": {}, "missingImages": []}
        package = sf.seal(content, None, b"\x01" * 32, b"\x02" * 12, secret=b"e2e-community-secret-0123456789ab")
        s, pub = req(W1, "POST", "/api/community/solutions", {"package": package, "title": "Uebungsblatt", "community_key": key})
        check(s == 201, "PC 1 veroeffentlicht eine Loesung (echtes Paket)", str(pub)[:200])
        solution_id = pub.get("solution_id")
        # zweites Konto B auf dem 'iPad'
        email_b = f"b-{int(time.time())}@example.test"
        s, db_ = req(H, "POST", "/api/account/register", {"email": email_b, "password": PW, "university": "luh", "device_name": "iPad B"}, headers=IOS)
        tb = db_["token"]
        mail = (tmp / "dienst" / "logs" / "mail.log").read_text(encoding="utf-8", errors="replace")
        req(H, "POST", "/api/account/verify-email", {"token": re.findall(r"verify=([A-Za-z0-9_-]+)", mail)[-1]})
        s, cl = req(H, "POST", "/api/community/claims", {"fingerprints": [sha], "course_keys": [key]}, token=tb, headers=IOS)
        check(s == 200 and cl["accepted"] == 1, "B meldet dieselbe PDF und den Kurs", str(cl))
        check(req(H, "POST", f"/api/community/communities/{key}/join", {"kind": "course"}, token=tb, headers=IOS)[0] == 200, "B tritt bei")
        s, ls = req(H, "GET", f"/api/community/solutions?fingerprint={sha}", token=tb, headers=IOS)
        check(s == 200 and [x["solution_id"] for x in ls["solutions"]] == [solution_id], "B findet die Loesung von PC 1")
        s, pk = req(H, "GET", f"/api/community/solutions/{solution_id}", token=tb, headers=IOS)
        opened = sf.open_package(pk["package"], None, b"e2e-community-secret-0123456789ab") if s == 200 else {}
        check(s == 200 and ids_of({"pages": {p["key"]: p for p in opened.get("pages", [])}}) == ["s1"], "B laedt und oeffnet das Paket: Strich von PC 1 ist da")
        check(req(H, "POST", f"/api/community/solutions/{solution_id}/like", {}, token=tb, headers=IOS)[1].get("likes") == 1, "B liked")
        s, cm = req(H, "POST", f"/api/community/solutions/{solution_id}/comments", {"text": "Danke, hilft mir sehr!", "page_key": "p1", "anchor": {"x": 0.4, "y": 0.3}}, token=tb, headers=IOS)
        check(s == 201, "B kommentiert mit Stelle auf der Seite", str(cm)[:160])
        s, nt = req(W2, "GET", "/api/community/notifications?unread=true")
        kinds = sorted({x["kind"] for x in nt.get("notifications", [])})
        check(s == 200 and {"comment", "like"} <= set(kinds), "PC 2 (anderes Geraet derselben Nutzerin) bekommt Mitteilungen: Kommentar und Like", str(kinds))
        s, rp = req(W2, "POST", f"/api/community/solutions/{solution_id}/comments", {"text": "Gern!", "parent_id": cm["id"]})
        check(s == 201, "PC 2 antwortet auf den Kommentar")
        s, nb = req(H, "GET", "/api/community/notifications?unread=true", token=tb, headers=IOS)
        check("reply" in [x["kind"] for x in nb.get("notifications", [])], "B bekommt die Antwort als Mitteilung")
        s, q = req(H, "POST", f"/api/community/courses/{key}/questions", {"title": "Wie loest man Aufgabe 3?", "body": "b) klappt nicht", "fingerprint": sha}, token=tb, headers=IOS)
        check(s == 201, "B stellt eine Frage im Kurs")
        s, ql = req(W1, "GET", f"/api/community/courses/{key}/questions")
        check(s == 200 and any(x["id"] == q["id"] for x in ql["questions"]), "PC 1 sieht die Frage von B")
        s, an = req(W1, "POST", f"/api/community/questions/{q['id']}/answers", {"body": "Substitution u = x^2."})
        check(s == 201, "PC 1 antwortet")
        s, qb = req(H, "GET", f"/api/community/questions/{q['id']}", token=tb, headers=IOS)
        check(s == 200 and qb.get("answer_count", qb.get("answers")) not in (0, None, []), "B sieht die Antwort von PC 1", str(qb)[:160])
        # Free-Konto darf nicht lesen (Tarifregel des Inhabers bleibt unveraendert)
        # Abmelden
        s, out = req(W2, "POST", "/api/app-account/logout", {})
        check(s == 200 and out["state"] == "signed_out" and not (tmp / "pc2" / "service-token").exists(), "Abmelden: Token auf PC 2 geloescht")
        s, st = req(W2, "GET", "/api/entitlements")
        check(st.get("access", {}).get("locked") is True, "PC 2 nach dem Abmelden gesperrt")
    finally:
        for pr in procs:
            if pr.poll() is None:
                pr.terminate()
        for pr in procs:
            try:
                pr.wait(15)
            except subprocess.TimeoutExpired:
                pr.kill()
        shutil.rmtree(tmp, ignore_errors=True)
    bad = [label for ok, label in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(bad)} von {len(RESULTS)} Pruefungen bestanden" + (("; FEHLER: " + "; ".join(bad)) if bad else ""))
    return 1 if bad else 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--serve":
        serve(sys.argv[2], int(sys.argv[3]), Path(sys.argv[4]), sys.argv[5] if len(sys.argv) > 5 else None)
    else:
        sys.path.insert(0, str(ROOT))
        raise SystemExit(run())
