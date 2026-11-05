"""Gemeinsame Wochentests: gleicher Kurs + gleiche Uebung -> hoechstens DREI Tests fuer alle, keiner je Person.

Der Schluessel haengt nur an Dingen, die fuer alle Studierenden gleich sind:
  - Hochschule (luh, hildesheim, ...)
  - Testdauer, gerundet auf feste Stufen
  - Fingerabdruecke der verwendeten Materialien: SHA-256 des Dateiinhalts
    (gleiche Folie, gleiches Uebungsblatt -> gleicher Abdruck, egal ueber welchen Weg die Datei kam)
Nicht im Schluessel: Modulname und Lehrwochen-Nummer (pro Nutzer verschieden einstellbar), Nutzer, Geraet.
Wer eine andere Uebungsgruppe mit anderem Blatt hat, bekommt dadurch automatisch einen eigenen Test.

Varianten (Regel des Inhabers, 04.11.2026): je Schluessel gibt es hoechstens MAX_VARIANTS = 3 Tests, egal wie viele
Studierende das Modul haben. Jeder Nutzer bekommt eine feste Variante `variant(user_id, key)` (SHA-256 ueber
"<user_id>|<key>", erste 4 Byte als Zahl, mod 3): bei 100 Studierenden teilen sich ca. 34/33/33 je einen Test.
Ablauf (`pick`): gibt es die eigene Variante schon, wird sie UEBERNOMMEN (keine KI); sonst wird nur erzeugt, solange
weniger als drei Varianten da sind (belegt die eigene, bei einem Wettlauf die naechste freie); bei drei vorhandenen
wird nie erzeugt. Die KI ist fuer Fragen, Karteikarten und PDF-Analyse da, nicht fuer einen Test je Person.

Version: aendert sich der Aufbau eines Tests (Prompt, Format), wird sie erhoeht, damit alte Tests nicht mit neuen
vermischt werden. "wt2" seit 29.10.2026: genau 15 Aufgaben (4 leicht, 6 mittel, 5 schwer), Altklausur im Schluessel;
"wt3" seit 04.11.2026: dazu Wahr/Falsch und Lueckentext als Aufgabenarten und eine Erklaerung je Aufgabe. Dieselbe Berechnung steht fuer die iPad-App in
packages/shared-contracts/fixtures/testshare/ (Erwartungswerte, auch fuer `variant`).
"""
from __future__ import annotations

import hashlib
import json
import uuid
from pathlib import Path

VERSION = "wt3"
MINUTE_STEPS = (15, 30, 45, 60, 90, 120)
# hoechstens so viele Tests je Schluessel (Regel des Inhabers: 3 Tests fuer 100 wie fuer 200 Studierende)
MAX_VARIANTS = 3
# Quellen eines uebernommenen Tests (tests.adopted_from); NULL = selbst erzeugt
ADOPTED_LOCAL = "local"          # anderer eigener Test mit demselben Schluessel (z. B. zweites Modul mit gleichen Dateien)
ADOPTED_SERVICE = "service"      # gemeinsamer Pool des Dienstes (V2, app/test_library.py)
ADOPTED_CLOUDKIT = "cloudkit"    # iPad V1 ohne Server (CloudKit, WeeklyTestCloudKit.swift)
# ein belegter, noch leerer Platz gilt so lange als "in Arbeit"; danach als verwaist (Geraet abgestuerzt)
PENDING_STALE_S = 10 * 60


def minutes_bucket(minutes: int | None) -> int:
    """Auf die naechste feste Stufe runden, damit 40 und 45 Minuten denselben Test teilen."""
    m = int(minutes or 45)
    return next((s for s in MINUTE_STEPS if m <= s), MINUTE_STEPS[-1])


def file_sha256(path: str | Path | None) -> str | None:
    if not path or not Path(path).is_file():
        return None
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def material_fingerprint(m: dict) -> str | None:
    """Inhalts-Hash der Datei. Ohne Inhalt (nicht geladen) kein Abdruck: dann wird nicht geteilt."""
    return m.get("content_sha256") or file_sha256(m.get("local_path"))


def fingerprints(materials: list[dict]) -> list[str] | None:
    """Sortierte, eindeutige Inhalts-Hashes oder None, wenn eine Datei keinen hat (dann nicht teilen)."""
    prints = [material_fingerprint(m) for m in materials]
    if not prints or any(p is None for p in prints):
        return None
    return sorted(set(prints))


def share_key(university: str, minutes: int | None, materials: list[dict]) -> str | None:
    """Schluessel des gemeinsamen Wochentests oder None, wenn nicht sicher teilbar (Material ohne Inhalts-Hash)."""
    prints = fingerprints(materials)
    if prints is None:
        return None
    canon = json.dumps({"v": VERSION, "uni": university, "minutes": minutes_bucket(minutes), "materials": prints},
                       separators=(",", ":"), sort_keys=True)
    return f"{VERSION}:" + hashlib.sha256(canon.encode("utf-8")).hexdigest()


# ---------------------------------------------------------------- Varianten (gleiche Rechnung in TestShare.swift)

def variant(user_id: str, key: str) -> int:
    """Feste Variante 0..MAX_VARIANTS-1 eines Nutzers fuer einen Schluessel: SHA-256 ueber "<user_id>|<key>", die
    ersten 4 Byte als Zahl (big-endian), modulo MAX_VARIANTS. Deterministisch und gleichmaessig verteilt."""
    d = hashlib.sha256(f"{user_id}|{key}".encode("utf-8")).digest()
    return int.from_bytes(d[:4], "big") % MAX_VARIANTS


def pick(ready, assigned: int, pending=()) -> tuple[str, int | None]:
    """Was tun? `ready`: fertige Varianten (0..2), `pending`: belegte, noch leere (ein anderer erzeugt gerade), `assigned`
    die eigene. ("adopt", v): Variante v uebernehmen, keine KI. ("generate", v): erzeugen und als Variante v
    veroeffentlichen. ("none", None): nichts zu uebernehmen und kein Platz frei (eigener Test ohne Veroeffentlichung).
    Regel: eigene fertig -> uebernehmen; sonst erzeugen, solange weniger als MAX_VARIANTS Plaetze belegt sind (die
    eigene, bei einem Wettlauf die naechste freie); bei drei belegten nie erzeugen, sondern die naechste fertige
    uebernehmen."""
    def clean(vs):
        return {int(v) for v in vs if 0 <= int(v) < MAX_VARIANTS}
    have, taken = clean(ready), clean(ready) | clean(pending)
    if assigned in have:
        return "adopt", assigned
    if len(taken) < MAX_VARIANTS:
        for i in range(MAX_VARIANTS):
            v = (assigned + i) % MAX_VARIANTS
            if v not in taken:
                return "generate", v
    others = sorted(have, key=lambda x: (x - assigned) % MAX_VARIANTS)
    return ("adopt", others[0]) if others else ("none", None)


def shared_info(row: dict | None) -> dict | None:
    """`shared` im Test-JSON fuer die Oberflaeche ("Gemeinsamer Test · Variante 2 von 3"): variant 1-basiert,
    of = MAX_VARIANTS, adopted = uebernommen statt selbst erzeugt; None ohne Variante (nicht geteilter Test)."""
    if not row or row.get("share_variant") is None:
        return None
    return {"variant": int(row["share_variant"]) + 1, "of": MAX_VARIANTS, "adopted": bool(row.get("adopted_from"))}


def user_id(conn) -> str:
    """Nutzerkennung fuer die Zuteilung: im Dienst das Konto, am Einzelplatz eine einmal erzeugte Kennung der
    Installation (settings.share_user_id). Sie verlaesst das Geraet nicht; der Dienst sieht nur die Variante."""
    from . import config
    uid = config.current_user_id()
    if uid:
        return uid
    r = conn.execute("SELECT value FROM settings WHERE key='share_user_id'").fetchone()
    if r and r[0]:
        return r[0]
    uid = uuid.uuid4().hex
    conn.execute("INSERT OR IGNORE INTO settings(key, value) VALUES ('share_user_id', ?)", (uid,))
    return conn.execute("SELECT value FROM settings WHERE key='share_user_id'").fetchone()[0]


def lookup_local(conn, key: str) -> dict | None:
    """Vorhandener Test mit demselben Schluessel in dieser Installation (zwei Module mit denselben Dateien). Dieselbe
    Person hat dieselbe Variante, darum ist jeder eigene Test mit dem Schluessel der richtige."""
    from . import db
    return db.row(conn, "SELECT title, questions, share_variant, adopted_from FROM tests WHERE share_key=? ORDER BY id LIMIT 1", (key,))


def obtain(key: str, uid: str, generate, log=print, wait_s: float | None = None) -> dict:
    """Gemeinsamen Test zum Schluessel holen oder erzeugen, nach der Varianten-Regel. Liefert
    {title, questions, share_variant, adopted_from}. Ohne Dienst (Einzelplatz) wird erzeugt und die eigene Variante
    nur gemerkt (adopted_from None). Im Dienst (hosted) ist der Pool app/test_library.py (shared_*): eigene Variante
    vorhanden -> uebernehmen; in Arbeit -> kurz warten, dann uebernehmen; sonst Platz belegen, erzeugen,
    veroeffentlichen (scheitert das Erzeugen, wird der Platz wieder frei)."""
    from . import config
    assigned = variant(uid, key)
    if not config.is_hosted():
        # Windows-App mit StudiNow-Konto (05.11.2026): derselbe Pool wie im Dienst ueber /api/v2/shared-tests
        got = obtain_via_service(key, generate, log=log, wait_s=wait_s)
        if got is not None:
            return got
        res = generate()
        return {"title": res.get("title"), "questions": res.get("questions") or [], "share_variant": assigned, "adopted_from": None}
    from . import test_library
    waited = False
    for _ in range(MAX_VARIANTS + 2):
        slots = test_library.shared_slots(key)
        ready = {v for v, s in slots.items() if s["status"] == "ready"}
        pending = {v for v, s in slots.items() if s["status"] == "pending"}
        if assigned in ready:
            return _adopt(slots[assigned], assigned, log, key)
        if assigned in pending and not waited:
            # ein anderer Nutzer erzeugt gerade genau diese Variante: einmal abwarten statt doppelt erzeugen
            waited = True
            done = test_library.shared_wait(key, assigned, timeout_s=test_library.SHARED_WAIT_S if wait_s is None else wait_s)
            if done:
                return _adopt(done, assigned, log, key)
            continue                                    # Lage neu ansehen (frei geworden oder weiter in Arbeit)
        action, v = pick(ready, assigned, pending)
        if action == "adopt":
            return _adopt(slots[v], v, log, key)
        if action == "none":
            break                                   # alle drei belegt, keine fertig: eigener Test ohne Veroeffentlichung
        if not test_library.shared_claim(key, v, uid):
            continue                                # Wettlauf: Platz gerade belegt, Lage neu ansehen
        try:
            res = generate()
            title, questions = res.get("title"), res.get("questions") or []
            test_library.shared_publish(key, v, uid, title, questions)
        except Exception:
            test_library.shared_release(key, v, uid)
            raise
        log(f"Gemeinsamer Wochentest erzeugt und geteilt ({key[:16]}…, Variante {v + 1} von {MAX_VARIANTS})")
        return {"title": title, "questions": questions, "share_variant": v, "adopted_from": None}
    res = generate()
    return {"title": res.get("title"), "questions": res.get("questions") or [], "share_variant": assigned, "adopted_from": None}


SERVICE_WAIT_S = 90.0
SERVICE_POLL_S = 5.0


def obtain_via_service(key: str, generate, log=print, wait_s: float | None = None, sleep=None) -> dict | None:
    """Gemeinsamer Pool des Dienstes fuer die Windows-App (V2, app/library_api.py): eigene Variante (der Dienst rechnet
    sie aus dem Konto) fertig -> uebernehmen (keine KI, 0 Credits); in Arbeit -> bis `wait_s` warten (Abfrage alle 5 s);
    frei -> Platz belegen, mit der KI des PCs erzeugen (eigenes ChatGPT oder StudiNow-KI), veroeffentlichen; scheitert
    das Erzeugen, wird der Platz frei. None = ohne Konto oder ohne Netz: dann wie bisher nur eigener Test."""
    import time
    from . import ai_relay
    if not ai_relay.linked():
        return None
    sleep = sleep or time.sleep
    wait_s = SERVICE_WAIT_S if wait_s is None else wait_s
    try:
        d = ai_relay.service_json("GET", f"/api/v2/shared-tests/{key}", timeout=20)
    except ai_relay.RelayError as e:
        log(f"Gemeinsamer Wochentest: Dienst nicht erreichbar ({e.message}), eigener Test")
        return None
    waited = 0.0
    for _ in range(int(wait_s // SERVICE_POLL_S) + MAX_VARIANTS + 2):
        action = d.get("action")
        if action == "adopt" and isinstance(d.get("test"), dict):
            v = int(d.get("adopt_variant", d.get("variant", 0)))
            t = d["test"]
            log(f"Gemeinsamer Wochentest uebernommen ({key[:16]}…, Variante {v + 1} von {MAX_VARIANTS}, Dienst)")
            return {"title": t.get("title"), "questions": t.get("questions") or [], "share_variant": v, "adopted_from": ADOPTED_SERVICE}
        if action == "wait":
            if waited >= wait_s:
                break                                   # verwaist oder sehr langsam: eigener Test ohne Veroeffentlichung
            sleep(SERVICE_POLL_S)
            waited += SERVICE_POLL_S
        elif action == "generate":
            v = int(d.get("generate_as", d.get("variant", 0)))
            try:
                claim = ai_relay.service_json("POST", f"/api/v2/shared-tests/{key}/claim", {"variant": v}, timeout=20)
            except ai_relay.RelayError:
                return None
            if claim.get("claimed"):
                try:
                    res = generate()
                except Exception:
                    try:
                        ai_relay.service_json("DELETE", f"/api/v2/shared-tests/{key}/{v}", timeout=20)
                    except ai_relay.RelayError:
                        pass
                    raise
                title, questions = res.get("title"), res.get("questions") or []
                try:
                    ai_relay.service_json("POST", f"/api/v2/shared-tests/{key}/{v}", {"title": title, "questions": questions}, timeout=20)
                    log(f"Gemeinsamer Wochentest erzeugt und geteilt ({key[:16]}…, Variante {v + 1} von {MAX_VARIANTS}, Dienst)")
                    return {"title": title, "questions": questions, "share_variant": v, "adopted_from": None}
                except ai_relay.RelayError as e:
                    log(f"Gemeinsamer Wochentest nicht geteilt ({e.message})")
                    try:
                        ai_relay.service_json("DELETE", f"/api/v2/shared-tests/{key}/{v}", timeout=20)
                    except ai_relay.RelayError:
                        pass
                    return {"title": title, "questions": questions, "share_variant": None, "adopted_from": None}
        else:
            break
        try:
            d = ai_relay.service_json("GET", f"/api/v2/shared-tests/{key}", timeout=20)
        except ai_relay.RelayError:
            return None
    return None


def _adopt(slot: dict, v: int, log, key: str) -> dict:
    log(f"Gemeinsamer Wochentest uebernommen ({key[:16]}…, Variante {v + 1} von {MAX_VARIANTS})")
    return {"title": slot.get("title"), "questions": slot.get("questions") or [], "share_variant": v, "adopted_from": ADOPTED_SERVICE}
