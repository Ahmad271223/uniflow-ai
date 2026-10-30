"""Erzeugt packages/shared-contracts/fixtures/community/contract.json: Vertrag G4 (Community-Dienst) aus der Python-Referenz.

Aufgezeichnet gegen den echten Server im gehosteten Modus: Veroeffentlichen, Suchen, Laden, Zurueckziehen, Melden,
Sperren, Moderation und die Fehlerfaelle (Tarif, fremde Datei, Doppel). IDs, Tokens, Zeiten und Zufall sind ersetzt.
Dazu die Paketpruefung: welche Koepfe der Dienst annimmt und mit welchem Code er welche abweist.
Aufruf im Projektordner: python tools/gen-community-fixture.py [--check]
"""
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "community" / "contract.json"
FP = "a" * 64


def _setup_env() -> None:
    tmp = tempfile.mkdtemp(prefix="uniflow-community-fixture-")
    os.environ["LERNAPP_DATA_DIR"] = str(Path(tmp) / "data")
    os.environ["LERNAPP_LOG_DIR"] = str(Path(tmp) / "logs")
    os.environ["LERNAPP_ALLOWED_HOSTS"] = "test"
    sys.path.insert(0, str(ROOT))
    sys.path.insert(0, str(ROOT / "tests"))


_TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{40,50}$")
_HEX32_RE = re.compile(r"^[a-f0-9]{32}$")
_UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
_ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?$")
_B64_RE = re.compile(r"^[A-Za-z0-9+/]{16,}={0,2}$")


def scrub(x, ids: dict):
    if isinstance(x, dict):
        return {k: scrub(v, ids) for k, v in x.items()}
    if isinstance(x, list):
        return [scrub(v, ids) for v in x]
    if isinstance(x, str):
        if x in ids:
            return ids[x]
        if x.startswith("/api/"):                      # Pfade: IDs und Pseudonyme als Teilstrings
            for k, v in ids.items():
                x = x.replace(k, v)
            return re.sub(r"Studi-[0-9a-f]{8}", "<pseudonym>", x)
        if _TOKEN_RE.match(x):
            return "<token>"
        if _HEX32_RE.match(x):
            return "<user-id>"
        if _UUID_RE.match(x):
            return "<solution-id>"
        if x.startswith("Studi-") and len(x) == 14:
            return "<pseudonym>"
        if _ISO_RE.match(x) and not x.startswith("2026-10-26T10:00:00Z"):
            return "<zeit-utc>"
        if _B64_RE.match(x):
            return "<base64>"
    return x


def build() -> dict:
    from conftest import asgi_call
    from app import accounts, community, config, db
    from app.server import app
    config.MODE = "hosted"
    for p in (accounts.db_path(), community.db_path()):
        p.unlink(missing_ok=True)
    flows: list[dict] = []
    ids: dict[str, str] = {}

    def call(step, method, path, body=None, token=None):
        headers = {"Authorization": f"Bearer {token}"} if token else None
        st, _, raw = asgi_call(app, method, path, body=json.dumps(body) if body is not None else None, headers=headers)
        data = json.loads(raw) if raw else None
        flows.append({"step": step, "method": method, "path": scrub(path, ids), "auth": bool(token), "request": scrub(body, ids),
                      "status": st, "response": scrub(data, ids)})
        return st, data

    def user(email, plus=True, admin=False, uni="luh"):
        st, d = call(f"Konto {email.split('@')[0]} anlegen", "POST", "/api/account/register", {"email": email, "password": "sehr-geheim-123", "university": uni})
        accounts.mark_email_verified(d["user"]["id"])           # Veroeffentlichen verlangt eine bestaetigte Adresse
        accounts.end_trial(d["user"]["id"])                     # "Free" meint den Stand nach der 7-Tage-Probe
        if plus:
            accounts.set_plan(d["user"]["id"], "plus")
        if admin:
            accounts.set_role(d["user"]["id"], "admin")
        t = config.set_user_context(d["user"]["id"], uni)
        try:
            db.init_db()
            with db.cursor() as conn:
                conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, active, created_at) VALUES ('c1', 'Mathe I', 'vorlesung', 1, '2026-10-26')")
                conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status, content_sha256, download_url) VALUES "
                             "('f1', 'c1', 'Blatt 3.pdf', 'pdf', 'neu', ?, 'https://studip.example/file-refs/f1/download')", (FP,))
        finally:
            config.reset_user_context(t)
        return d["user"], d["token"]

    autor, ta = user("autor@beispiel.de")
    leser, tl = user("leser@beispiel.de")
    free, tf = user("free@beispiel.de", plus=False)
    admin, tadm = user("admin@beispiel.de", admin=True)
    pkg = community.sample_package(FP, pages=2, page_count=12, display_name="Erika", solution_id="6f1c1c0e-0000-4000-8000-000000000001")
    ids[pkg["header"]["solutionId"]] = "<solution-id>"
    call("Regeln des Dienstes", "GET", "/api/community/info", token=ta)
    call("Veroeffentlichen", "POST", "/api/community/solutions", {"package": pkg, "title": "Blatt 3"}, token=ta)
    call("Veroeffentlichen ohne Plus", "POST", "/api/community/solutions", {"package": pkg}, token=tf)
    bad = json.loads(json.dumps(pkg)); bad["header"]["document"]["sha256"] = "b" * 64; bad["header"]["solutionId"] = "6f1c1c0e-0000-4000-8000-000000000002"
    ids[bad["header"]["solutionId"]] = "<solution-id-2>"
    call("Veroeffentlichen fuer eine PDF, die nicht aus dem eigenen Abgleich stammt", "POST", "/api/community/solutions", {"package": bad}, token=ta)
    call("Veroeffentlichen: Paket beschaedigt", "POST", "/api/community/solutions", {"package": {**pkg, "fremd": 1}}, token=ta)
    call("Veroeffentlichen durch ein anderes Konto (gleiche Loesung)", "POST", "/api/community/solutions", {"package": pkg}, token=tl)
    call("Suchen zur eigenen PDF", "GET", "/api/community/solutions?fingerprint=" + FP, token=tl)
    call("Suchen zu einer fremden PDF", "GET", "/api/community/solutions?fingerprint=" + "c" * 64, token=tl)
    sid = pkg["header"]["solutionId"]
    call("Laden", "GET", f"/api/community/solutions/{sid}", token=tl)
    call("Meine Veroeffentlichungen", "GET", "/api/community/mine", token=ta)
    # Geraete melden ihre PDFs (Windows-App, iPad: Abgleich auf dem Geraet), Likes, Kommentare, Rangliste (28.10.2026)
    call("Geraet meldet seine PDFs", "POST", "/api/community/claims", {"fingerprints": [FP, "kaputt"]}, token=tl)
    call("Gefaellt mir", "POST", f"/api/community/solutions/{sid}/like", token=tl)
    call("Gefaellt mir: eigene Loesung", "POST", f"/api/community/solutions/{sid}/like", token=ta)
    st, c1 = call("Kommentar an einer Stelle der Seite", "POST", f"/api/community/solutions/{sid}/comments",
                  {"text": "Hier fehlt die Begründung für Schritt 2.", "page_key": "p1", "anchor": {"x": 0.42, "y": 0.31}}, token=tl)
    ids[c1["id"]] = "<comment-id>"
    flows[-1]["response"]["id"] = "<comment-id>"
    st, r1 = call("Antwort des Autors", "POST", f"/api/community/solutions/{sid}/comments", {"text": "Danke, ergänze ich.", "parent_id": c1["id"]}, token=ta)
    ids[r1["id"]] = "<reply-id>"
    flows[-1]["response"]["id"] = "<reply-id>"
    call("Kommentieren ohne Plus", "POST", f"/api/community/solutions/{sid}/comments", {"text": "Danke"}, token=tf)
    call("Kommentare lesen", "GET", f"/api/community/solutions/{sid}/comments", token=tl)
    call("Kommentar bearbeiten", "PATCH", f"/api/community/comments/{c1['id']}", {"text": "Hier fehlt die Begründung."}, token=tl)
    call("Suchen: mit Likes und Kommentaren", "GET", "/api/community/solutions?fingerprint=" + FP, token=tl)
    call("Rangliste ohne Rolle", "GET", "/api/community/admin/leaderboard", token=tl)
    call("Rangliste fuer den Inhaber", "GET", "/api/community/admin/leaderboard", token=tadm)

    # Teil 2 (28.10.2026): Fragen je Kurs (Schluessel wie CommunityKeys.courseKey), Antworten, Lesezeichen,
    # Benachrichtigungen, seitenweise
    import hashlib
    key = hashlib.sha256(("uniflow.community.course.v1\0luh\0" + "kurs-beispiel").encode()).hexdigest()
    ids[key] = "<course-key>"
    st, q = call("Frage im Kurs stellen", "POST", f"/api/community/courses/{key}/questions",
                 {"title": "Wie zeige ich Konvergenz?", "body": "Aufgabe 2b", "fingerprint": FP, "page": 3}, token=tl)
    ids[q["id"]] = "<question-id>"
    flows[-1]["response"]["id"] = "<question-id>"
    call("Frage ohne Plus", "POST", f"/api/community/courses/{key}/questions", {"title": "x"}, token=tf)
    call("Fragen des Kurses", "GET", f"/api/community/courses/{key}/questions?limit=30", token=ta)
    st, a = call("Antwort", "POST", f"/api/community/questions/{q['id']}/answers", {"body": "Sandwich-Lemma benutzen."}, token=ta)
    ids[a["id"]] = "<answer-id>"
    flows[-1]["response"]["id"] = "<answer-id>"
    call("Antwort hilfreich", "POST", f"/api/community/answers/{a['id']}/vote", token=tl)
    call("Antwort als Loesung markieren", "POST", f"/api/community/questions/{q['id']}/accept", {"answer_id": a["id"]}, token=tl)
    call("Frage mit Antworten", "GET", f"/api/community/questions/{q['id']}", token=ta)
    call("Lesezeichen setzen", "POST", f"/api/community/bookmarks/question/{q['id']}", token=ta)
    call("Lesezeichen", "GET", "/api/community/bookmarks", token=ta)
    st, n = call("Benachrichtigungen", "GET", "/api/community/notifications", token=ta)
    for x in flows[-1]["response"].get("notifications", []):
        x["id"] = "<notification-id>"
    call("Alles gelesen", "POST", "/api/community/notifications/read", {}, token=ta)
    call("Frage melden", "POST", f"/api/community/questions/{q['id']}/report-post", {"reason": "spam"}, token=ta)
    call("Kommentar loeschen", "DELETE", f"/api/community/comments/{r1['id']}", token=ta)
    call("Melden", "POST", f"/api/community/solutions/{sid}/report", {"reason": "foreignMaterial", "note": "Folien enthalten"}, token=tl)
    call("Melden: schon gemeldet", "POST", f"/api/community/solutions/{sid}/report", {"reason": "spam"}, token=tl)
    call("Melden: eigene Loesung", "POST", f"/api/community/solutions/{sid}/report", {"reason": "spam"}, token=ta)
    call("Autor sperren (nur fuer mich)", "POST", f"/api/community/solutions/{sid}/block", token=tl)
    call("Gesperrte Autoren", "GET", "/api/community/blocks", token=tl)
    call("Suchen nach dem Sperren: leer", "GET", "/api/community/solutions?fingerprint=" + FP, token=tl)
    pseud = community.pseudonym(autor["id"])
    call("Sperre aufheben", "DELETE", f"/api/community/blocks/{pseud}", token=tl)
    call("Moderation ohne Rolle", "GET", "/api/community/moderation", token=tl)
    call("Moderation: Warteschlange", "GET", "/api/community/moderation", token=tadm)
    call("Moderation: verbergen", "POST", f"/api/community/solutions/{sid}/moderate", {"action": "hide", "reason": "pruefen"}, token=tadm)
    call("Moderation: wiederherstellen", "POST", f"/api/community/solutions/{sid}/moderate", {"action": "restore"}, token=tadm)
    call("Zurueckziehen durch ein anderes Konto", "DELETE", f"/api/community/solutions/{sid}", token=tl)
    call("Zurueckziehen", "DELETE", f"/api/community/solutions/{sid}", token=ta)
    call("Laden nach dem Zurueckziehen", "GET", f"/api/community/solutions/{sid}", token=tl)
    call("Ohne Sitzung", "GET", "/api/community/info")

    checks = []
    for name, mut, code in (("gueltig", lambda p: None, None), ("formatVersion 2", lambda p: p.update(formatVersion=2), "unsupported_version"),
                            ("Zusatzfeld oben", lambda p: p.update(extra=1), "package_invalid"), ("pages 0", lambda p: p["header"]["contents"].update(pages=0), "package_invalid"),
                            ("plaintextBytes passt nicht", lambda p: p["header"]["encryption"].update(plaintextBytes=1), "package_invalid"),
                            ("kein Paket", lambda p: p.update(format="x"), "not_a_solution")):
        p = json.loads(json.dumps(pkg)); mut(p)
        try:
            community.validate_package(p); checks.append({"case": name, "ok": True, "package": scrub(p, ids)})
        except community.CommunityError as e:
            checks.append({"case": name, "ok": False, "code": e.code, "status": e.status, "package": scrub(p, ids)})
    errors = {}
    for f in flows:
        r = f["response"]
        if isinstance(r, dict) and r.get("code"):
            errors.setdefault(r["code"], {"status": f["status"], "message": r["detail"]})
    errors["not_hosted"] = {"status": 501, "message": "Die Community gibt es nur im gehosteten Dienst (LERNAPP_MODE=hosted)."}
    config.MODE = "local"
    for p in (accounts.db_path(), community.db_path()):
        p.unlink(missing_ok=True)
    return {"_hinweis": "Erzeugt mit tools/gen-community-fixture.py aus der Python-Referenz (app/community.py); nicht von Hand aendern.",
            "rules": {"plan_required": "plus", "authorization": "Veroeffentlichen, Suchen und Laden nur fuer PDFs aus dem eigenen Hochschul-Abgleich (files.content_sha256 mit download_url)",
                      "reports_to_hide": community.REPORTS_TO_HIDE, "reasons": list(community.REPORT_REASONS), "format": community.FORMAT,
                      "format_version": community.FORMAT_VERSION, "max_package_bytes": community.MAX_PACKAGE_BYTES,
                      "pseudonym": "Studi-<8 hex>, stabil je Konto, nie Konto-ID oder E-Mail",
                      "endpoints": ["GET /api/community/info", "POST /api/community/solutions", "GET /api/community/solutions?fingerprint=",
                                    "GET /api/community/solutions/{id}", "DELETE /api/community/solutions/{id}", "GET /api/community/mine",
                                    "POST /api/community/solutions/{id}/report", "POST /api/community/solutions/{id}/block",
                                    "DELETE /api/community/blocks/{pseudonym}", "GET /api/community/blocks",
                                    "GET /api/community/moderation", "POST /api/community/solutions/{id}/moderate",
                                    "POST /api/community/claims", "POST|DELETE /api/community/solutions/{id}/like",
                                    "GET|POST /api/community/solutions/{id}/comments", "PATCH|DELETE /api/community/comments/{id}",
                                    "POST /api/community/comments/{id}/report", "GET /api/community/admin/leaderboard",
                                    "GET|POST /api/community/courses/{course_key}/questions?limit=&before=&fingerprint=",
                                    "GET|PATCH|DELETE /api/community/questions/{id}", "POST /api/community/questions/{id}/answers",
                                    "POST /api/community/questions/{id}/accept", "PATCH|DELETE /api/community/answers/{id}",
                                    "POST|DELETE /api/community/answers/{id}/vote", "POST /api/community/{questions|answers}/{id}/report-post",
                                    "GET /api/community/bookmarks", "POST|DELETE /api/community/bookmarks/{solution|question}/{id}",
                                    "GET /api/community/notifications?unread=", "POST /api/community/notifications/read"],
                      "course_key": "SHA-256 hex von 'uniflow.community.course.v1\\0<hochschule>\\0<kurs-id>' (wie CommunityKeys.courseKey)",
                      "notification_kinds": ["comment", "reply", "like", "answer", "accepted"]},
            "package-checks": checks, "errors": dict(sorted(errors.items())), "flows": flows}


def main(check: bool) -> bool:
    _setup_env()
    sys.path.insert(0, str(ROOT / "tools"))
    from schema_source import write_or_check
    text = json.dumps(build(), ensure_ascii=False, indent=1) + "\n"
    OUT.parent.mkdir(parents=True, exist_ok=True)
    return write_or_check(OUT, text, check)


if __name__ == "__main__":
    ok = main("--check" in sys.argv)
    sys.exit(0 if ok or "--check" not in sys.argv else 1)
