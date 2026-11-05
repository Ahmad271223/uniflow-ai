"""HTTP-Schnittstelle fuer geteilte Karteikarten-Stapel (04.11.2026, docs/KARTEIKARTEN-STAPEL-2026-11-04.md). Nur im
gehosteten Modus mit Sitzung (sonst 501 wie die Community); Fehler wie beim Konto: {"detail": "...", "code": "..."}.
Dieselben Pfade und Antworten hat der Swift-Kern (CardStackEndpoints.swift) ueber CloudKit.

- POST   /api/flashcard-stacks/{id}/share        eigenen Stapel in die Modul-Community kopieren (merkt shared_id)
- PUT    /api/flashcard-stacks/{id}/share        geteilte Kopie durch den aktuellen Stand ersetzen (Karten, Name)
- DELETE /api/flashcard-stacks/{id}/share        zurueckziehen (nur der Autor)
- GET    /api/community/card-stacks?module=<Schluessel>|module_id=<lokal>&week=   geteilte Stapel des Moduls (+ `weeks`)
- GET    /api/community/card-stacks/mine         eigene geteilte Stapel
- GET    /api/community/card-stacks/{id}         ein geteilter Stapel mit Karten
- POST   /api/community/card-stacks/{id}/adopt   als eigenen Stapel uebernehmen (Lernstand getrennt, 0 Credits)
- POST | DELETE /api/community/card-stacks/{id}/like
- POST   /api/community/card-stacks/{id}/report  {reason, note}

Tarif (04.11.2026): Teilen, Zurueckziehen und Uebernehmen sind eigene Karteikarten und gehoeren zu Plus
(`can_use_flashcards`, 403 "Karteikarten gibt es ab StudiNow Plus."); Uebernehmen kostet keine Credits und braucht keine
bestaetigte E-Mail. Lesen, Liken und Melden wie in der Community: seit 05.11.2026 ab Plus (`can_read_community`),
Like/Meldung mit bestaetigter E-Mail. Eigene geteilte Stapel auflisten und zurueckziehen geht in jedem Tarif.
Uebernehmen zaehlt seit 05.11.2026 im Kontingent `card_stacks_adopted` (Plus 4 je Monat, Pro AI Fair Use).
"""
from __future__ import annotations

from datetime import date

from fastapi import APIRouter, Body, HTTPException, Request

from . import cardshare, community, community_cards, config, db, entitlements

router = APIRouter(tags=["card-stacks"])


def _err(e: community.CommunityError) -> HTTPException:
    return HTTPException(e.status, {"detail": e.message, "code": e.code, **e.extra})


def _account(request: Request) -> dict:
    """Angemeldet im Dienst ohne Tarifpruefung (eigene geteilte Stapel auflisten und zurueckziehen)."""
    if not config.is_hosted():
        raise HTTPException(501, {"detail": "Geteilte Stapel gibt es nur im gehosteten Dienst (LERNAPP_MODE=hosted).", "code": "not_hosted"})
    u = getattr(request.state, "user", None)
    if not u:
        raise HTTPException(401, {"detail": "Anmeldung erforderlich.", "code": "unauthenticated"})
    return u


def _user(request: Request) -> dict:
    """Angemeldet und Community-Recht (ab Plus seit 05.11.2026, auch Lesen, Liken, Melden); Moderation ohne Tarif."""
    u = _account(request)
    if u.get("role") != "admin":
        entitlements.require(request, "can_read_community")
    return u


def _flashcards(request: Request) -> dict:
    """Angemeldet im Dienst, Recht auf eigene Karteikarten und Community (beide ab Plus; die Karteikarten-Meldung zuerst)"""
    u = _account(request)
    entitlements.require(request, "can_use_flashcards")
    _user(request)
    return u


def _adopt_quota(request: Request, shared_id: str) -> None:
    """Kontingent `card_stacks_adopted` (05.11.2026): Plus 4 Stapel je Monat, Pro AI unbegrenzt (Fair Use); derselbe
    Stapel zaehlt im Monat einmal. 429 quota_exhausted, wenn es aufgebraucht ist."""
    entitlements.consume(request, "card_stacks_adopted", f"stack:{shared_id}", once=True)


def _run(fn, *args, **kw):
    try:
        return fn(*args, **kw)
    except community.CommunityError as e:
        raise _err(e)


def _local_stack(conn, stack_id: int):
    from .server import _stack_row
    s = _stack_row(conn, stack_id)
    if not s:
        raise HTTPException(404, {"detail": "Stapel nicht gefunden", "code": "not_found"})
    return s


def _adopted_ids(conn) -> set[str]:
    return {r["source_ref"] for r in db.rows(conn, "SELECT source_ref FROM flashcard_stacks WHERE source=? AND source_ref IS NOT NULL",
                                              (cardshare.SOURCE_COMMUNITY,))}


# ---------------------------------------------------------------- Windows-App (05.11.2026): Stapel liegen auf dem PC

def _pc() -> bool:
    """Einzelplatz mit StudiNow-Konto: Teilen und Uebernehmen laufen ueber den Dienst (Karten werden mitgeschickt bzw.
    in die PC-Datenbank kopiert); Tarif, E-Mail und Mitgliedschaft prueft der Dienst."""
    if config.is_hosted():
        return False
    from . import ai_relay
    return ai_relay.linked()


def _service(method: str, path: str, body: dict | None = None) -> dict:
    from . import ai_relay
    return ai_relay.service_json(method, path, body, timeout=30)


def _pc_cards(conn, stack_id: int) -> tuple[dict, list[dict]]:
    s = _local_stack(conn, stack_id)
    return s, db.rows(conn, "SELECT question, answer FROM flashcards WHERE stack_id=? ORDER BY id", (stack_id,))


@router.post("/api/flashcard-stacks/{stack_id}/share")
def share_stack(request: Request, stack_id: int, body: dict = Body(default={})):
    """Kopie des eigenen Stapels (Karten: Frage und Antwort) in die Community seines Moduls; ohne Lehrwoche unter
    "Allgemein". Nur Stapel eines Moduls (subject), nie ueber Module hinweg. 409 wenn schon geteilt."""
    if _pc():
        with db.cursor() as conn:
            s, cards = _pc_cards(conn, stack_id)
            if s.get("shared_id"):
                raise HTTPException(409, {"detail": "Dieser Stapel ist schon geteilt.", "code": "already_shared"})
            m = db.row(conn, "SELECT id FROM modules WHERE name=?", (s.get("subject") or "",)) if s.get("subject") else None
            if not m:
                raise HTTPException(422, {"detail": "Nur Stapel eines Moduls lassen sich teilen.", "code": "no_module"})
            _, key = community_cards.module_key(conn, m["id"])
        out = _service("POST", "/api/community/card-stacks", {"community_key": key, "name": s["name"], "kind": s.get("kind") or "eigene",
                                                              "week": s.get("week"), "cards": cards})
        with db.cursor() as conn:
            conn.execute("UPDATE flashcard_stacks SET shared_id=? WHERE id=?", (out["id"], stack_id))
            out["stack"] = _local_stack(conn, stack_id)
        return out
    u = _flashcards(request)
    with db.cursor() as conn:
        s = _local_stack(conn, stack_id)
        if s.get("shared_id"):
            raise HTTPException(409, {"detail": "Dieser Stapel ist schon geteilt.", "code": "already_shared"})
        m = db.row(conn, "SELECT id FROM modules WHERE name=?", (s.get("subject") or "",)) if s.get("subject") else None
        if not m:
            raise HTTPException(422, {"detail": "Nur Stapel eines Moduls lassen sich teilen.", "code": "no_module"})
        name, key = community_cards.module_key(conn, m["id"])
        cards = db.rows(conn, "SELECT question, answer FROM flashcards WHERE stack_id=? ORDER BY id", (stack_id,))
    out = _run(community_cards.share, u, config.university(), key, s["name"], s.get("kind") or "eigene", s.get("week"), cards)
    with db.cursor() as conn:
        conn.execute("UPDATE flashcard_stacks SET shared_id=? WHERE id=?", (out["id"], stack_id))
        out["stack"] = _local_stack(conn, stack_id)
    return out


@router.put("/api/flashcard-stacks/{stack_id}/share")
def replace_shared_stack(request: Request, stack_id: int):
    """Geteilte Kopie durch den aktuellen Stand des eigenen Stapels ersetzen (Karten, Name); Kennung, Likes und
    Uebernahmen bleiben, wer schon uebernommen hat, behaelt seine Kopie. 404 not_shared, wenn der Stapel nicht geteilt ist.
    Aus der Cloud-Sitzung vom 04.11.2026 ("Stapel ersetzen") an das Stapel-Modell angepasst."""
    if _pc():
        with db.cursor() as conn:
            s, cards = _pc_cards(conn, stack_id)
        if not s.get("shared_id"):
            raise HTTPException(404, {"detail": "Dieser Stapel ist nicht geteilt.", "code": "not_shared"})
        out = _service("PUT", f"/api/community/card-stacks/{s['shared_id']}", {"name": s["name"], "cards": cards})
        with db.cursor() as conn:
            out["stack"] = _local_stack(conn, stack_id)
        return out
    u = _flashcards(request)
    with db.cursor() as conn:
        s = _local_stack(conn, stack_id)
        sid = s.get("shared_id")
        cards = db.rows(conn, "SELECT question, answer FROM flashcards WHERE stack_id=? ORDER BY id", (stack_id,))
    if not sid:
        raise HTTPException(404, {"detail": "Dieser Stapel ist nicht geteilt.", "code": "not_shared"})
    out = _run(community_cards.replace, u, sid, s["name"], cards)
    with db.cursor() as conn:
        out["stack"] = _local_stack(conn, stack_id)
    return out


@router.delete("/api/flashcard-stacks/{stack_id}/share")
def unshare_stack(request: Request, stack_id: int):
    # Zurueckziehen geht in jedem Tarif (wie bei Loesungen): wer nach der Probe oder nach dem Herabstufen auf Free
    # faellt, muss Geteiltes trotzdem aus der Community nehmen koennen (Entscheidung Koordinator 04.11.2026)
    if _pc():
        with db.cursor() as conn:
            sid = _local_stack(conn, stack_id).get("shared_id")
        if not sid:
            raise HTTPException(404, {"detail": "Dieser Stapel ist nicht geteilt.", "code": "not_shared"})
        out = _service("DELETE", f"/api/community/card-stacks/{sid}")
        with db.cursor() as conn:
            conn.execute("UPDATE flashcard_stacks SET shared_id=NULL WHERE id=?", (stack_id,))
            out["stack"] = _local_stack(conn, stack_id)
        return out
    u = _account(request)
    with db.cursor() as conn:
        s = _local_stack(conn, stack_id)
        sid = s.get("shared_id")
    if not sid:
        raise HTTPException(404, {"detail": "Dieser Stapel ist nicht geteilt.", "code": "not_shared"})
    out = _run(community_cards.withdraw, u, sid)
    with db.cursor() as conn:
        conn.execute("UPDATE flashcard_stacks SET shared_id=NULL WHERE id=?", (stack_id,))
        out["stack"] = _local_stack(conn, stack_id)
    return out


@router.get("/api/community/card-stacks")
def list_card_stacks(request: Request, module: str = "", module_id: int | None = None, week: int | None = None):
    """Geteilte Stapel eines Moduls (Schluessel `module` oder lokale `module_id`), `week` 0 = Allgemein; `adopted`
    sagt, ob dieses Geraet den Stapel schon uebernommen hat; `weeks` zaehlt alle sichtbaren Stapel je Woche
    ("0" = Allgemein), unabhaengig vom Filter."""
    u = _user(request)
    with db.cursor() as conn:
        key = module
        if module_id is not None:
            _, key = community_cards.module_key(conn, module_id)
            if not key:
                raise HTTPException(404, {"detail": "Modul nicht gefunden", "code": "not_found"})
        adopted = _adopted_ids(conn)
    every = _run(community_cards.listing, u, key, None, adopted)
    weeks: dict[str, int] = {}
    for x in every:
        k = str(x["week"] or 0)
        weeks[k] = weeks.get(k, 0) + 1
    if week is not None:
        every = [x for x in every if (x["week"] is None if week == 0 else x["week"] == week)]
    return {"community_key": key, "stacks": every, "weeks": weeks}


@router.get("/api/community/card-stacks/mine")
def my_card_stacks(request: Request):
    return {"stacks": community_cards.mine(_account(request))}


@router.get("/api/community/card-stacks/{stack_id}")
def get_card_stack(request: Request, stack_id: str):
    return _run(community_cards.get, _user(request), stack_id)


@router.post("/api/community/card-stacks/{stack_id}/adopt")
def adopt_card_stack(request: Request, stack_id: str):
    """Als eigenen Stapel uebernehmen: Kopie der Karten (Fach 1, heute faellig) in einem neuen Stapel des lokalen Moduls
    mit Art und Woche des geteilten Stapels; schon uebernommen -> der vorhandene Stapel. 0 Credits, ab Plus, ohne
    bestaetigte E-Mail. Am PC (Windows-App): Karten vom Dienst, Stapel in der PC-Datenbank, Zaehler im Dienst."""
    pc = _pc()
    if pc:
        shared = _service("GET", f"/api/community/card-stacks/{stack_id}")
    else:
        u = _flashcards(request)
        shared = _run(community_cards.get, u, stack_id)
    with db.cursor() as conn:
        ex = db.row(conn, "SELECT id FROM flashcard_stacks WHERE source=? AND source_ref=?", (cardshare.SOURCE_COMMUNITY, shared["id"]))
        if ex:
            return {"stack": _local_stack(conn, ex["id"]), "already": True, "count": 0}
        m = community_cards.module_for_key(conn, shared["community_key"])
        if not m:
            raise HTTPException(404, {"detail": "Dieses Modul gibt es auf diesem Gerät nicht.", "code": "module_not_here"})
        if pc:
            _service("POST", f"/api/community/card-stacks/{stack_id}/adopted")    # Tarif und Kontingent prueft der Dienst
        else:
            _adopt_quota(request, shared["id"])
        now = db.now_iso()
        cur = conn.execute("INSERT INTO flashcard_stacks(name, subject, file_id, created_at, kind, week, source, source_ref) VALUES (?,?,?,?,?,?,?,?)",
                           (shared["name"], m["name"], None, now, shared["kind"], shared["week"], cardshare.SOURCE_COMMUNITY, shared["id"]))
        sid = cur.lastrowid
        today = date.today().isoformat()
        for c in shared["cards_list"]:
            conn.execute("INSERT INTO flashcards(file_id, subject, question, answer, created_at, box, due, stack_id) VALUES (NULL,?,?,?,?,1,?,?)",
                         (m["name"], c["question"], c["answer"], now, today, sid))
        out = {"stack": _local_stack(conn, sid), "already": False, "count": len(shared["cards_list"])}
    if not pc:
        community_cards.count_adopted(u, shared["id"])
    return out


@router.post("/api/community/card-stacks/{stack_id}/like")
def like_card_stack(request: Request, stack_id: str):
    return _run(community_cards.like, _user(request), stack_id, True)


@router.delete("/api/community/card-stacks/{stack_id}/like")
def unlike_card_stack(request: Request, stack_id: str):
    return _run(community_cards.like, _user(request), stack_id, False)


@router.post("/api/community/card-stacks/{stack_id}/report")
def report_card_stack(request: Request, stack_id: str, body: dict = Body(...)):
    return _run(community_cards.report, _user(request), stack_id, body.get("reason") or "", body.get("note"))


# ---------------------------------------------------------------- Dienst: Stapel der Windows-App (Karten im Rumpf)

@router.post("/api/community/card-stacks", status_code=201)
def share_card_stack_from_device(request: Request, body: dict = Body(...)):
    """Windows-App: eigenen Stapel teilen, die Karten liegen auf dem PC und kommen mit {community_key, name, kind,
    week, cards}; dieselben Regeln wie POST /api/flashcard-stacks/{id}/share (Tarif, E-Mail, Mitglied)."""
    u = _flashcards(request)
    return _run(community_cards.share, u, config.university(), body.get("community_key"), body.get("name"),
                body.get("kind") or "eigene", body.get("week"), body.get("cards"))


@router.put("/api/community/card-stacks/{stack_id}")
def replace_card_stack_from_device(request: Request, stack_id: str, body: dict = Body(...)):
    u = _flashcards(request)
    return _run(community_cards.replace, u, stack_id, body.get("name"), body.get("cards"))


@router.delete("/api/community/card-stacks/{stack_id}")
def withdraw_card_stack_from_device(request: Request, stack_id: str):
    return _run(community_cards.withdraw, _account(request), stack_id)


@router.post("/api/community/card-stacks/{stack_id}/adopted")
def count_card_stack_adopted(request: Request, stack_id: str):
    """Windows-App hat den Stapel in ihre eigene Datenbank uebernommen: nur zaehlen (ab Plus, wie Uebernehmen)."""
    u = _flashcards(request)
    shared = _run(community_cards.get, u, stack_id)
    _adopt_quota(request, shared["id"])
    community_cards.count_adopted(u, stack_id)
    return {"ok": True}
