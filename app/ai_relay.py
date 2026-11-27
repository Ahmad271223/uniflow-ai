"""StudiNow-KI am PC ueber das StudiNow-Konto (05.11.2026, docs/WINDOWS-LUECKEN-2026-11-05.md Abschnitt 4).

Die Windows-App (Einzelplatz, app/service_link.py) hat die Dateien, Seitentexte und Notizen auf dem PC; der Dienst hat
sie nicht. Darum baut der PC den Prompt wie fuer die eigene KI und gibt ihn mit dem Sitzungs-Token an den Dienst
(`POST /api/ai/relay`). Was Geld kostet, entscheidet allein der Dienst: Aufgabe (`task`) aus einer festen Liste, dazu
waehlt er selbst System-Text, Antwortschema, Zweck (Credits ja/nein, Modellmischung), Recht des Tarifs, Kontingent,
Hoechstlaenge des Prompts, bestaetigte E-Mail, Rate-Limit, Becken und die harte Obergrenze je Konto (Credits,
app/credits.py). Ein freier Prompt "an die KI" ist damit nicht moeglich; freie Fragen gibt es ohnehin (Modus "Frage").

Reihenfolge am PC wie auf dem iPad (`ai.source`): Geteiltes/Gespeichertes (0 Credits: eigener Erklaerungsspeicher,
Erklaerungsspeicher des Dienstes, Zwischenspeicher der StudiNow-KI, gemeinsame Wochentests) -> eigenes ChatGPT, wenn
verbunden -> StudiNow-KI mit Credits. Die Claude-Kommandozeile (`claude -p`) gibt es nur noch als Entwickler-Schalter
(`LERNAPP_AI_CLI=1`) bzw. im Entwicklungsserver ohne Konto-Pflicht.

Aufgaben (`TASKS`):
- `tutor:<modus>`  KI-Hilfe und KI-Start (Modi aus ai.TUTOR_MODES); Recht wie /api/ai/tutor, Kontingent ai_assist,
                   Credits; `cache` nur fuer geteilte ganze Seiten (gleiche Anfrage = gleiche Antwort, 0 Credits)
- `flashcards`     Karteikarten aus Seiten oder auf Auftrag (Modul, Woche); Recht can_use_ai_generated_questions,
                   ai_assist, Credits, Antwortschema ai.FLASHCARDS_SCHEMA
- `week_test`      Wochentest aus dem Dialog/Planer; Kontingent ai_tests_new (wie im Dienst), ohne Credits; der Dienst
                   prueft die Form (ai.check_week_test mit den Optionen) und versucht es hoechstens zweimal
- `weekly`         Wochentest mit Vorlesungs-Seitenmarkern (app/weekly.py: Erzeugen, Pruefen, Korrigieren); ohne
                   Credits, nur mit einem Tarif mit Wochentests
- `grade`          Bewertung eines abgegebenen Tests; ohne Credits, nur mit einem Tarif mit Wochentests
- `study_plan`     KI-Lernplan (07.11.2026, iPad AIStudyPlan.swift): Lernbloecke aus Modultiteln, Lehrwochen, Dateinamen,
                   Klausurterminen und Zeiten; Recht can_use_ai_explanations, Kontingent ai_assist, Credits
- `mail`           Uni-Mail "Mit KI verbessern" (13.11.2026): Rechtschreibung, Grammatik, Stil; Recht
                   can_use_ai_explanations (Pro AI, Probe), Kontingent ai_mail (50 je Monat), ohne Credits

Antwort: {answer, model, shared, replay, credits}; `shared` = Treffer im Zwischenspeicher der StudiNow-KI (0 Credits),
`credits` = Stand des Kontos mit `charged` (wie /api/ai/tutor im Dienst). Fehler wie im Dienst: {detail, code, ...}
mit 402 (Abo), 403 (plan_required, email_unverified), 409 (duplicate_request), 429 (credits_exhausted,
quota_exhausted, rate_limited), 503 (ai_not_configured...). Am PC reicht `RelayError` Status, Code und Zusatzfelder
unveraendert an die Oberflaeche weiter (Handler in app/server.py).

`GET /api/ai/source` (PC und Dienst): Weg der KI fuer die Oberflaeche {source, label, credits, linked, chatgpt, cli}.
"""
from __future__ import annotations

import contextvars
import json
import os
import uuid
from dataclasses import dataclass

from fastapi import APIRouter, Body, HTTPException, Request

from . import config

router = APIRouter(tags=["ai"])

# Rechte je Tutor-Modus (wie TUTOR_ENTITLEMENT in app/server.py)
# "ask" ist der KI-Chat (15.11.2026): ab Plus, dort allein aus gekauften Credits; alles andere bleibt KI-Lernhilfe
TUTOR_RIGHT = {"summary": "can_use_ai_summaries", "flashcards": "can_use_ai_generated_questions",
               "similar": "can_use_ai_generated_questions", "terms": "can_use_ai_explanations",
               "ask": "can_use_ai_chat"}


@dataclass(frozen=True)
class Task:
    purpose: str
    system: str                       # Schluessel in _systems()
    max_chars: int
    right: str | None = None          # Recht des Tarifs (app/plans.py)
    quota: str | None = None          # Monatskontingent (app/plans.py QUOTAS)
    schema: str | None = None         # "flashcards"
    needs_tests: bool = False         # nur mit einem Tarif, der Wochentests hat (ai_tests_new > 0)
    cache_ok: bool = False


def _tasks() -> dict[str, Task]:
    from . import ai
    out = {f"tutor:{m}": Task(f"tutor:{m}", "tutor", 60_000, TUTOR_RIGHT.get(m, "can_use_ai_explanations"), "ai_assist",
                              cache_ok=m != "flashcards") for m in ai.TUTOR_MODES}
    out["flashcards"] = Task("flashcards", "json", 60_000, "can_use_ai_generated_questions", "ai_assist", schema="flashcards")
    # 26.11.2026: nur mit Credits (Recht mit needs_credits; die Anfrage kostet Credits, ai_backend.CREDIT_PURPOSES)
    out["week_test"] = Task("weekly_test", "json", 120_000, right="can_generate_studora_ai_tests", quota="ai_tests_new")
    out["weekly"] = Task("weekly_test", "weekly", 120_000, needs_tests=True)
    out["grade"] = Task("test_grading", "json", 60_000, needs_tests=True)
    out["study_plan"] = Task("study_plan", "json", 40_000, "can_use_ai_explanations", "ai_assist")
    # Uni-Mail "Mit KI verbessern" (13.11.2026): Pro AI, 50 je Monat (plans.QUOTAS ai_mail), ohne Credits
    out["mail"] = Task("mail_rewrite", "mail", 12_000, "can_use_ai_explanations", "ai_mail")
    return out


def _systems(university: str | None = None) -> dict[str, str]:
    """System-Texte je Schluessel; `weekly` nach der Hochschule des Kontos (Audit P65-F7, weekly.system_text)"""
    from . import ai, weekly
    return {"tutor": ai.TUTOR_SYSTEM, "json": ai.SYSTEM, "weekly": weekly.system_text(university), "mail": ai.MAIL_INSTRUCTION}


def known_task(name: str) -> bool:
    return name in _tasks()


# ================================================================== Dienst: POST /api/ai/relay

def _err(status: int, code: str, detail: str, **extra) -> HTTPException:
    return HTTPException(status, {"detail": detail, "code": code, **extra})


def _plan_has_tests(user: dict) -> bool:
    from . import entitlements, plans
    plan = entitlements.plan_of(user)
    lim = plans.QUOTAS.get(plan, {}).get("ai_tests_new", 0)
    return lim is None or lim > 0


@router.post("/api/ai/relay")
async def relay(request: Request, body: dict = Body(...)):
    """StudiNow-KI fuer die Windows-App (nur im Dienst). Rumpf {task, prompt, request_id?, cache?, fresh?,
    second_opinion?, route_text?, options?, exam?, image? (nur tutor:*, Base64 JPEG/PNG)}. Asynchron wie /api/ai/tutor
    (app/ai_async.py): Pruefungen und Kontingent kurz im eigenen Thread-Begrenzer, der Anbieter asynchron."""
    from . import ai_async, ai_backend
    async with ai_async.slot():
        pre = await ai_async.db(_relay_prepare, request, body)
        user, task, name, prompt, rid, image, c = (pre[k] for k in ("user", "task", "name", "prompt", "rid", "image", "c"))
        extra: dict = {}
        if c is not None:
            if name.startswith("tutor:") and getattr(c, "replay", False):
                extra = await ai_async.db(_wissensbank_replay, user, rid)
        else:
            # Wissensbank (20.11.2026, app/wissensbank.py): passt der Wortlaut zu einer Stelle, bekommt das Konto beim
            # ersten Mal die Antwort daraus (1 Credit), bei einer Wiederholung die KI und die Ja/Nein-Frage
            wb = await ai_async.db(_wissensbank_plan, user, name, body)
            # Kein lieferbarer Treffer (21.11.2026, app/wissensbank_ki.py, Schalter Standard aus): eine gemerkte KI-Antwort
            # zur selben Stelle, sonst die KI - auf Wunsch mit Auszuegen aus der Wissensbank am Prompt
            ki = await ai_async.db(_wissensbank_ki_plan, user, name, body) if wb is None else None
            if task.quota:
                await ai_async.db(entitlements_consume, request, task.quota, rid)
            try:
                if wb is not None and wb.deliver:
                    from . import wissensbank
                    c = await ai_async.db(wissensbank.deliver, user, wb, rid)
                elif ki is not None and ki.gemerkt is not None:
                    from . import wissensbank_ki
                    c = await ai_async.db(wissensbank_ki.deliver, user, ki, rid)
                else:
                    full = prompt + ki.kontext.block if ki is not None and ki.kontext is not None else prompt
                    c = await _complete_async(user, task, name, full, rid, body, image)
            except HTTPException:
                if task.quota:
                    await ai_async.db(entitlements_refund, request, task.quota, rid)
                raise
            except ai_backend.AIUnavailable as e:
                if task.quota:
                    await ai_async.db(entitlements_refund, request, task.quota, rid)
                raise ai_async.http_error(e)
            except Exception:
                if task.quota:
                    await ai_async.db(entitlements_refund, request, task.quota, rid)
                raise
            if name.startswith("tutor:"):
                extra = await ai_async.db(_wissensbank_fields, user, wb, c)
                if ki is not None:
                    extra = {**extra, **await ai_async.db(_wissensbank_ki_fields, user, ki, c)}
        return await ai_async.db(_relay_answer, user, name, c, extra)


# ---------------------------------------------------------------- Vorab-Frage an die Wissensbank (21.11.2026)
# Befund am iPad: Bei "ganze Seite erklaeren" sieht die App zuerst in ihrem Erklaerungsspeicher nach (0 Credits) und ruft
# /api/ai/relay gar nicht mehr - die Wissensbank wurde fuer solche Seiten nie gefragt. Mit dieser Frage kann die App VOR
# dem Erklaerungsspeicher pruefen, ob die Wissensbank die Stelle liefert. Kein Treffer kostet nichts und erzeugt keine
# KI-Antwort. Eigener Pfad statt eines Schalters in /api/ai/relay: Ein aelterer Dienst kennt den Pfad nicht (404) und
# die App faellt auf ihren bisherigen Weg zurueck; einen unbekannten Schalter haette er uebergangen und die KI gerufen.

VORAB_GRUENDE = ("kein_treffer", "schon_geliefert", "nicht_berechtigt", "keine_angaben", "kontingent", "credits", "rate")


def _vorab_leer(name: str, grund: str) -> dict:
    return {"treffer": False, "grund": grund, "task": name}


def _vorab_prepare(request: Request, body: dict) -> dict:
    """Synchroner Teil der Vorab-Frage. Fehler (501, 401, 400, 409) wie /api/ai/relay; alles, was nur heisst "die
    Wissensbank liefert hier nichts", kommt als `leer` mit Grund zurueck (Status 200, keine Kosten)."""
    from . import ai_backend, entitlements, wissensbank
    if not config.is_hosted():
        raise _err(501, "not_hosted", "Diese Schnittstelle gibt es nur im StudiNow-Dienst.")
    user = getattr(request.state, "user", None)
    if not user:
        raise _err(401, "unauthenticated", "Anmeldung erforderlich.")
    name = str(body.get("task") or (f"tutor:{body.get('mode')}" if body.get("mode") else ""))
    task = _tasks().get(name)
    if task is None or not name.startswith("tutor:") or name.split(":", 1)[1] not in wissensbank.MODES:
        raise _err(400, "task_unknown", "Die Wissensbank gibt es nur für Erklären und Lösen.")
    wb = body.get("wissensbank")
    if not isinstance(wb, dict) or not str(wb.get("text") or "").strip():
        return {"name": name, "leer": "keine_angaben"}
    try:
        if task.right:
            entitlements.require(request, task.right)
        entitlements.require_verified_for_ai(request)
    except HTTPException as e:
        # 26.11.2026 neues Modell: der Tarif hat das Recht, es fehlen nur Credits (entitlements.require: 429) -> "credits",
        # wenn die Wissensbank fuer das Konto ueberhaupt gilt (sonst bleibt es "nicht_berechtigt")
        no_credits = e.status_code == 429 and wissensbank.enabled() and wissensbank.allowed_for(user)
        return {"name": name, "leer": "credits" if no_credits else "nicht_berechtigt"}
    rid = str(body.get("request_id") or uuid.uuid4().hex)[:80]
    try:
        c = ai_backend.replay(user["id"], rid)
    except ai_backend.AIUnavailable as e:
        raise _err(e.status, e.code, e.message, **e.extra)
    if c is not None:
        return {"user": user, "task": task, "name": name, "rid": rid, "c": c, "wb": None}
    if not wissensbank.enabled() or not wissensbank.allowed_for(user):
        return {"name": name, "leer": "nicht_berechtigt"}
    # nur die Angaben zur Stelle zaehlen; `ausschnitt` steht in den Angaben selbst (hier gibt es kein Bild)
    plan = _wissensbank_plan(user, name, {"wissensbank": wb, "fresh": bool(body.get("fresh"))})
    if plan is None:
        return {"name": name, "leer": "kein_treffer"}
    if not plan.deliver:
        return {"name": name, "leer": "schon_geliefert"}
    return {"user": user, "task": task, "name": name, "rid": rid, "c": None, "wb": plan}


@router.post("/api/ai/wissensbank")
async def wissensbank_vorab(request: Request, body: dict = Body(...)):
    """Vorab-Frage der App: Liefert die Wissensbank diese Stelle? Rumpf {mode: "explain"|"steps" (oder task:
    "tutor:<modus>"), request_id, wissensbank: {datei, kurs, seite, text, ausschnitt?}, fresh?}.

    Treffer: Antwort wie /api/ai/relay bei einer Wissensbank-Lieferung ({answer, model, shared, replay, credits, task,
    source: "wissensbank", wissensbank_key, wissensbank: {badge, status, hinweise}}) und `treffer: true`; 1 Credit
    (`tutor:wissensbank`), Kontingent und Rate-Limit wie dort. Dieselbe request_id noch einmal: dieselbe Antwort ohne
    neue Kosten (`replay: true`).
    Kein Treffer: Status 200, {treffer: false, grund, task} - ohne Kosten, ohne Eintrag im Verbrauch, ohne KI.
    `grund`: kein_treffer | schon_geliefert (dieses Konto hat die Stelle schon bekommen; ueber /api/ai/relay kaeme jetzt
    die KI mit der Ja/Nein-Frage) | nicht_berechtigt (Schalter aus, Tarif, Hochschule, E-Mail) | keine_angaben |
    kontingent | credits | rate."""
    from . import ai_async, ai_backend, wissensbank
    async with ai_async.slot():
        pre = await ai_async.db(_vorab_prepare, request, body)
        name = pre["name"]
        if "leer" in pre:
            return _vorab_leer(name, pre["leer"])
        user, task, rid, c, wb = (pre[k] for k in ("user", "task", "rid", "c", "wb"))
        if c is not None:
            # dieselbe request_id noch einmal: nur eine fruehere Wissensbank-Lieferung zaehlt als Treffer
            extra = await ai_async.db(_wissensbank_replay, user, rid)
            if extra.get("source") != "wissensbank":
                return _vorab_leer(name, "kein_treffer")
            return {**await ai_async.db(_relay_answer, user, name, c, extra), "treffer": True}
        if task.quota:
            try:
                await ai_async.db(entitlements_consume, request, task.quota, rid)
            except HTTPException:
                return _vorab_leer(name, "kontingent")
        try:
            c = await ai_async.db(wissensbank.deliver, user, wb, rid)
        except ai_backend.AIUnavailable as e:
            if task.quota:
                await ai_async.db(entitlements_refund, request, task.quota, rid)
            if e.code == "duplicate_request":
                raise ai_async.http_error(e)
            return _vorab_leer(name, "rate" if e.code == "ai_rate_limited" else "credits")
        except Exception:
            if task.quota:
                await ai_async.db(entitlements_refund, request, task.quota, rid)
            raise
        extra = await ai_async.db(_wissensbank_fields, user, wb, c)
        return {**await ai_async.db(_relay_answer, user, name, c, extra), "treffer": True}


def _wissensbank_plan(user: dict, name: str, body: dict):
    """Vorpruefung der Wissensbank; ein Fehler darin laesst die KI wie bisher antworten (nie ein Abbruch)."""
    try:
        from . import wissensbank
        return wissensbank.plan(user, name, body)
    except Exception:  # noqa: BLE001 - KI-Module protokollieren nichts (P80-F3/F4)
        return None


def _wissensbank_fields(user: dict, wb, c) -> dict:
    try:
        from . import wissensbank
        delivered = wb is not None and wb.deliver
        token = wissensbank.offer_feedback(user, wb, c) if wb is not None and not wb.deliver else None
        return wissensbank.response_fields(wb, delivered=delivered, token=token)
    except Exception:  # noqa: BLE001 - KI-Module protokollieren nichts (P80-F3/F4)
        return {}


def _wissensbank_ki_plan(user: dict, name: str, body: dict):
    """Gemerkte Antwort bzw. Auszuege fuer die KI; ein Fehler darin laesst die KI wie bisher antworten."""
    try:
        from . import wissensbank_ki
        return wissensbank_ki.plan(user, name, body)
    except Exception:  # noqa: BLE001 - KI-Module protokollieren nichts (P80-F3/F4)
        return None


def _wissensbank_ki_fields(user: dict, ki, c) -> dict:
    try:
        from . import wissensbank_ki
        return wissensbank_ki.after(user, ki, c)
    except Exception:  # noqa: BLE001
        return {}


def _wissensbank_replay(user: dict, rid: str) -> dict:
    try:
        from . import wissensbank
        return wissensbank.replay_info(user, rid) or {}
    except Exception:  # noqa: BLE001
        return {}


def entitlements_consume(request: Request, quota: str, rid: str) -> None:
    from . import entitlements
    entitlements.consume(request, quota, rid)


def entitlements_refund(request: Request, quota: str, rid: str) -> None:
    from . import entitlements
    entitlements.refund(request, quota, rid)


def _relay_prepare(request: Request, body: dict) -> dict:
    """Synchroner Teil: Dienst, Konto, Aufgabe, Prompt-Groesse, Bild, Recht, bestaetigte E-Mail, Wiederholung (replay)."""
    from . import ai, ai_backend, entitlements
    if not config.is_hosted():
        raise _err(501, "not_hosted", "Diese Schnittstelle gibt es nur im StudiNow-Dienst.")
    user = getattr(request.state, "user", None)
    if not user:
        raise _err(401, "unauthenticated", "Anmeldung erforderlich.")
    name = str(body.get("task") or "")
    task = _tasks().get(name)
    if task is None:
        raise _err(400, "task_unknown", "Diese KI-Aufgabe gibt es nicht.")
    prompt = body.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        raise _err(400, "prompt_missing", "Es fehlt der Inhalt der Anfrage.")
    if len(prompt) > task.max_chars:
        raise _err(413, "prompt_too_large", "Die Anfrage ist zu groß. Bitte weniger Seiten oder weniger Text wählen.")
    # Antwortstil wie ChatGPT (18.11.2026): Apps bis 1.0.5 schicken noch die alten Modus-Texte; der Dienst setzt die
    # neuen ein, damit der Stil mit dem Server-Update fuer alle gilt (ai.upgrade_tutor_prompt)
    if name.startswith("tutor:"):
        prompt = ai.upgrade_tutor_prompt(name, prompt)
    # Bild ("Bereich an KI", 05.11.2026): nur bei tutor:*, Grenzen wie /api/ai/tutor (ai.tutor_image); die Schaetzung
    # der Credits zaehlt die Bild-Tokens je Modell mit (ai_backend.complete -> ai_prices)
    image = None
    if body.get("image"):
        if not name.startswith("tutor:"):
            raise _err(400, "image_not_allowed", "Bilder gibt es nur für die KI-Hilfe.")
        try:
            image = ai.tutor_image(body.get("image"))
        except ai.TutorImageError as e:
            raise _err(413 if "groß" in str(e) else 400, "image_invalid", str(e))
    if task.right:
        entitlements.require(request, task.right)
    if task.needs_tests and not _plan_has_tests(user):
        raise _err(403, "plan_required", "Wochentests mit der StudiNow-KI gibt es ab StudiNow Plus.", required_plan="plus")
    entitlements.require_verified_for_ai(request)
    rid = str(body.get("request_id") or uuid.uuid4().hex)[:80]
    try:
        c = ai_backend.replay(user["id"], rid)
    except ai_backend.AIUnavailable as e:
        raise _err(e.status, e.code, e.message, **e.extra)
    return {"user": user, "task": task, "name": name, "prompt": prompt, "rid": rid, "image": image, "c": c}


def _relay_answer(user: dict, name: str, c, extra: dict | None = None) -> dict:
    """`extra`: Felder der Wissensbank (`source`, `wissensbank_key`, `wissensbank`, `feedback_token`; mit
    app/wissensbank_ki.py dazu `wissensbank_kontext`, `gemerkt`), nur bei tutor:*"""
    from . import ai_backend
    state = ai_backend.credits_balance(user["id"])
    credits = {**state, "charged": int(getattr(c, "credits_charged", 0) or 0), "replay": bool(getattr(c, "replay", False))} if state else None
    return {"answer": c.text, "model": "cache" if c.model == "cache" else (c.source_model or c.model), "shared": c.model == "cache",
            "replay": bool(c.replay), "credits": credits, "task": name, **(extra or {})}


def _complete_kwargs(task: Task, name: str, rid: str, body: dict, image: bytes | None,
                     university: str | None = None) -> tuple[str, dict | None, dict]:
    from . import ai
    system = _systems(university)[task.system]
    schema = ai.FLASHCARDS_SCHEMA if task.schema == "flashcards" else None
    second = bool(body.get("second_opinion"))
    cache = bool(body.get("cache")) and task.cache_ok and not second and image is None
    route_text = str(body.get("route_text") or "")[:2000]
    kw = dict(schema=schema, cache=cache, request_id=rid, keep_result=True, fresh=bool(body.get("fresh")),
              route_hint="second_opinion" if second else None, route_text=route_text or None)
    return system, schema, kw


def _week_test_check(c, body: dict, options) -> str | None:
    from . import ai
    try:
        return ai.check_week_test(ai.parse_json(c.text), exam=bool(body.get("exam")), options=options)
    except ai.AIError as e:
        return str(e)


def _week_test_failed(why) -> HTTPException:
    return _err(502, "week_test_form", f"Die KI hat den Wochentest zweimal nicht in der geforderten Form geliefert ({why}). "
                                       "Bitte später erneut versuchen.")


def _complete(user: dict, task: Task, name: str, prompt: str, rid: str, body: dict, image: bytes | None = None):
    """Synchron (Tests, Werkzeuge); der Endpunkt nutzt _complete_async."""
    from . import ai, ai_backend
    system, _schema, kw = _complete_kwargs(task, name, rid, body, image, user.get("university"))
    if name != "week_test":
        return ai_backend.complete(user["id"], task.purpose, system, prompt, image=image, **kw)
    # Wochentest: Form im Dienst pruefen (wie ai.generate_test), hoechstens zwei Versuche
    options = ai.week_test_options(body.get("options") if isinstance(body.get("options"), dict) else None)
    why = None
    for attempt in range(2):
        c = ai_backend.complete(user["id"], task.purpose, system, prompt, **{**kw, "request_id": rid if attempt == 0 else f"{rid}#2",
                                                                              "keep_result": attempt == 0})
        why = _week_test_check(c, body, options)
        if why is None:
            return c
    raise _week_test_failed(why)


async def _complete_async(user: dict, task: Task, name: str, prompt: str, rid: str, body: dict, image: bytes | None = None):
    from . import ai, ai_async, ai_backend
    system, _schema, kw = _complete_kwargs(task, name, rid, body, image, user.get("university"))
    if name != "week_test":
        return await ai_backend.complete_async(user["id"], task.purpose, system, prompt, image=image, **kw)
    options = ai.week_test_options(body.get("options") if isinstance(body.get("options"), dict) else None)
    why = None
    for attempt in range(2):
        c = await ai_backend.complete_async(user["id"], task.purpose, system, prompt,
                                            **{**kw, "request_id": rid if attempt == 0 else f"{rid}#2", "keep_result": attempt == 0})
        why = await ai_async.db(_week_test_check, c, body, options)
        if why is None:
            return c
    raise _week_test_failed(why)


# ================================================================== PC: Weg der KI und Aufruf des Dienstes

class RelayError(Exception):
    """Fehler des Dienstes fuer eine KI-Anfrage vom PC: Status, Code und Zusatzfelder gehen unveraendert an die
    Oberflaeche (Handler in app/server.py), damit 402/403/429 dort genauso ankommen wie im Web."""

    def __init__(self, status: int, code: str, message: str, extra: dict | None = None):
        super().__init__(message)
        self.status, self.code, self.message, self.extra = status, code, message, extra or {}

    def body(self) -> dict:
        return {"detail": self.message, "code": self.code, **{k: v for k, v in self.extra.items() if k not in ("detail", "code")}}


NO_AI = ("Für die KI melde dich mit deinem StudiNow-Konto an (Pro AI oder Probe, mit Credits) oder verbinde unter "
         "Einstellungen → KI dein ChatGPT.")
LABELS = {"chatgpt": "über dein ChatGPT · 0 Credits", "studinow": "StudiNow-KI · mit Credits",
          "cli": "Claude-Kommandozeile (Entwickler)", "none": "keine KI verbunden"}

_LAST: contextvars.ContextVar[dict | None] = contextvars.ContextVar("ai_relay_last", default=None)


def cli_enabled() -> bool:
    """`claude -p` nur als Entwickler-Schalter: LERNAPP_AI_CLI=1, oder im Entwicklungsserver ohne Konto-Pflicht und
    ohne LERNAPP_AI_CLI=0. In der Windows-App (Konto-Pflicht) nie von selbst."""
    v = os.environ.get("LERNAPP_AI_CLI")
    if v == "1":
        return True
    if v == "0":
        return False
    from . import account_mode
    return not account_mode.required()


def linked() -> bool:
    from . import service_link
    try:
        return bool(service_link.load_state().get("token"))
    except Exception:  # noqa: BLE001 - ohne Ablage: nicht verbunden
        return False


def source() -> str:
    """Weg der KI am PC: chatgpt | cli | studinow | none (Reihenfolge wie auf dem iPad, Geteiltes kommt vorher)."""
    if config.is_hosted():
        return "studinow"
    from . import ai
    if ai.uses_chatgpt():
        return "chatgpt"
    if os.environ.get("LERNAPP_AI_CLI") == "1":
        return "cli"
    if linked():
        return "studinow"
    return "cli" if cli_enabled() else "none"


def take() -> dict | None:
    """Ergebnis der letzten Anfrage an den Dienst in diesem Aufruf ({credits, shared, model}); danach leer."""
    v = _LAST.get()
    _LAST.set(None)
    return v


def take_credits() -> dict | None:
    v = take()
    return (v or {}).get("credits")


def _remember_credits(credits: dict | None) -> None:
    """Credits-Stand in den Abo-Zwischenspeicher der Windows-App (GET /api/entitlements zeigt ihn sofort), ohne die
    Kulanzzeit zu verlaengern (fetched_at bleibt)."""
    if not isinstance(credits, dict):
        return
    from . import account_mode
    try:
        cache = account_mode.load_cache()
        if not cache:
            return
        ent = dict(cache.get("entitlements") or {})
        ent["credits"] = {k: v for k, v in credits.items() if k not in ("charged", "replay")}
        account_mode.save_cache(ent, cache.get("user"), now=cache.get("fetched_at"))
    except Exception:  # noqa: BLE001 - nur Anzeige
        pass


def service_json(method: str, path: str, body: dict | None = None, *, query: str = "", timeout: float | None = None) -> dict:
    """JSON-Anfrage an den Dienst mit dem Token des Kontos (KI, Erklaerungsspeicher, Wochentests, Stapel); Fehler als
    RelayError mit Status, Code und Zusatzfeldern des Dienstes (401 -> account_required)."""
    from . import service_link
    st = service_link.load_state()
    if not st.get("token"):
        raise RelayError(401, "account_required", "Bitte melde dich mit deinem StudiNow-Konto an. " + NO_AI)
    if path.startswith("/api/ai/"):
        # KI des Dienstes erst nach der Einwilligung "KI-Hilfe: Was wird gesendet?" (app/ai_consent.py, 428)
        from . import ai_consent
        ai_consent.require_for_relay()
    raw = json.dumps(body).encode() if body is not None else None
    try:
        status, _, data = service_link.call(method, path, raw, query=query, st=st,
                                            timeout=timeout or service_link.UPLOAD_TIMEOUT)
    except service_link.LinkError as e:
        raise RelayError(e.status, e.code, e.message)
    try:
        d = json.loads(data or b"{}")
    except ValueError:
        d = {}
    if status >= 400:
        d = d if isinstance(d, dict) else {}
        detail = d.get("detail")
        if isinstance(detail, dict):
            d = {**detail, **{k: v for k, v in d.items() if k != "detail"}}
            detail = d.get("detail")
        if status == 401:
            raise RelayError(401, "account_required", "Deine Anmeldung beim StudiNow-Konto ist abgelaufen. Bitte melde dich neu an.")
        msg = detail if isinstance(detail, str) and detail else f"Der StudiNow-Dienst antwortet mit Fehler {status}."
        raise RelayError(status, str(d.get("code") or "service_error"), msg,
                         {k: v for k, v in d.items() if k not in ("detail", "code")})
    if not isinstance(d, dict):
        raise RelayError(502, "service_error", "Unerwartete Antwort des StudiNow-Dienstes.")
    if isinstance(d.get("credits"), dict):
        _LAST.set({"credits": d["credits"], "shared": bool(d.get("shared")), "model": d.get("model")})
        _remember_credits(d["credits"])
    return d


def complete(task: str, prompt: str, *, request_id: str | None = None, cache: bool = False, fresh: bool = False,
             second_opinion: bool = False, route_text: str = "", options: dict | None = None, exam: bool | None = None,
             image: bytes | None = None) -> dict:
    """Eine Anfrage an die StudiNow-KI des Dienstes mit dem Token des Kontos; {answer, model, shared, replay, credits}.
    Fehler als RelayError mit Status und Code des Dienstes."""
    body = {"task": task, "prompt": prompt, "request_id": (request_id or uuid.uuid4().hex)[:80]}
    if cache:
        body["cache"] = True
    if fresh:
        body["fresh"] = True
    if second_opinion:
        body["second_opinion"] = True
    if route_text:
        body["route_text"] = route_text[:2000]
    if options is not None:
        body["options"] = options
    if exam is not None:
        body["exam"] = bool(exam)
    if image:
        import base64
        body["image"] = base64.b64encode(image).decode("ascii")      # nur tutor:* (Bereich an KI)
    d = service_json("POST", "/api/ai/relay", body)
    if not isinstance(d.get("answer"), str):
        raise RelayError(502, "service_error", "Unerwartete Antwort der StudiNow-KI.")
    _LAST.set({"credits": d.get("credits"), "shared": bool(d.get("shared")), "model": d.get("model")})
    return d


# ================================================================== GET /api/ai/source

def _balance() -> dict | None:
    """Credits des Kontos am PC aus dem Abo-Stand (account-cache.json, beim Start und nach jeder Antwort aktuell)."""
    from . import account_mode
    c = ((account_mode.load_cache() or {}).get("entitlements") or {}).get("credits")
    return c if isinstance(c, dict) else None


@router.get("/api/ai/source")
def ai_source(request: Request):
    if config.is_hosted():
        from . import ai_backend
        u = getattr(request.state, "user", None)
        credits = ai_backend.credits_balance(u["id"]) if u else None
        return {"source": "studinow", "label": LABELS["studinow"], "credits": credits, "linked": True, "chatgpt": False, "cli": False}
    src = source()
    from . import ai
    return {"source": src, "label": LABELS[src], "credits": _balance() if linked() else None, "linked": linked(),
            "chatgpt": ai.uses_chatgpt(), "cli": src == "cli", "message": NO_AI if src == "none" else None}
