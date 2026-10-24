"""KI-Anbindung ueber die Claude Code CLI (`claude -p`).

Alle Funktionen liefern geparstes JSON. Die Prompts verlangen reines JSON als Antwort.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from datetime import date, timedelta

from .config import CLAUDE_MODEL, LOG_DIR


class AIError(RuntimeError):
    pass


def _claude_bin() -> str:
    b = shutil.which("claude") or shutil.which("claude.exe")
    if not b:
        raise AIError("Der Befehl 'claude' wurde nicht gefunden. Ist Claude Code installiert und im PATH?")
    return b


def ask(prompt: str, system: str = "", timeout: int = 600, allowed_tools: list[str] | None = None) -> str:
    """Schickt einen Prompt an `claude -p` und gibt den Antworttext zurueck.
    allowed_tools: z. B. ["Read"], damit Claude eine Bilddatei (Stundenplan-Screenshot) lesen darf."""
    env = {k: v for k, v in os.environ.items() if k not in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT")}
    env["PYTHONIOENCODING"] = "utf-8"
    cmd = [_claude_bin(), "-p", "--output-format", "json", "--model", CLAUDE_MODEL]
    if allowed_tools:
        cmd += ["--allowedTools", ",".join(allowed_tools)]
    if system:
        cmd += ["--append-system-prompt", system]
    try:
        proc = subprocess.run(cmd, input=prompt, capture_output=True, text=True, encoding="utf-8",
                              timeout=timeout, env=env, shell=False)
    except subprocess.TimeoutExpired as e:
        raise AIError(f"Claude hat nach {timeout}s nicht geantwortet") from e
    if proc.returncode != 0:
        raise AIError(f"claude -p Fehler ({proc.returncode}): {proc.stderr[:800]}")
    try:
        data = json.loads(proc.stdout)
        text = data.get("result") if isinstance(data, dict) else None
        if text is None:
            text = proc.stdout
    except json.JSONDecodeError:
        text = proc.stdout
    with open(LOG_DIR / "ai.log", "a", encoding="utf-8") as f:
        f.write(f"\n===== PROMPT ({len(prompt)} Zeichen) =====\n{prompt[:1500]}\n----- ANTWORT -----\n{text[:3000]}\n")
    return text


def parse_json(text: str):
    """Extrahiert das erste JSON-Objekt/-Array aus einem Antworttext."""
    t = text.strip()
    t = re.sub(r"^```(?:json)?\s*|\s*```$", "", t, flags=re.S)
    try:
        return json.loads(t)
    except json.JSONDecodeError:
        pass
    m = re.search(r"(\{.*\}|\[.*\])", t, flags=re.S)
    if m:
        try:
            return json.loads(m.group(1))
        except json.JSONDecodeError as e:
            raise AIError(f"KI-Antwort ist kein gueltiges JSON: {e}\n{t[:500]}") from e
    raise AIError(f"KI-Antwort enthaelt kein JSON:\n{t[:500]}")


SYSTEM = ("Du bist ein Lerncoach fuer ein Informatik-/Elektrotechnik-Studium (Leibniz Universitaet Hannover, "
          "1. Semester). Antworte ausschliesslich mit gueltigem JSON, ohne Erklaertext, ohne Markdown-Zaeune.")


# ----------------------------------------------------------------------------
# 1) Datei analysieren
# ----------------------------------------------------------------------------

def analyze_file(course_title: str, file_name: str, text: str) -> dict:
    prompt = f"""Analysiere diese Lernunterlage aus dem Kurs "{course_title}".
Dateiname: {file_name}

Gib ein JSON-Objekt mit genau diesen Feldern zurueck:
{{
  "doc_type": "vorlesung" | "uebung" | "loesung" | "skript" | "organisatorisch" | "klausur" | "sonstiges",
  "title": "kurzer sprechender Titel (max. 60 Zeichen)",
  "topics": ["Thema 1", "Thema 2", ...],              // 2-6 Stichworte
  "difficulty": 1-5,                                   // 1 = sehr leicht, 5 = sehr schwer, fuer Erstsemester
  "est_minutes": Zahl,                                 // realistische Lernzeit in Minuten zum Durcharbeiten
  "summary": "2-3 Saetze: worum geht es, was muss man danach koennen",
  "prerequisites": ["Vorwissen 1", ...]                // optional, kann leer sein
}}

Inhalt (ggf. gekuerzt):
<<<
{text if text.strip() else "[kein Text extrahierbar - schaetze anhand des Dateinamens]"}
>>>"""
    return parse_json(ask(prompt, SYSTEM))


# ----------------------------------------------------------------------------
# 2) Wochenplan
# ----------------------------------------------------------------------------

def build_week_plan(week_start: date, materials: list[dict], subjects: list[dict], settings: dict,
                    carry_over: list[dict], today: date | None = None) -> dict:
    days = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]
    free = ", ".join(days[d] for d in settings["free_days"]) or "keine"
    today = today or date.today()
    past_note = ""
    if week_start <= today <= week_start + timedelta(days=6):
        past_note = f"- Heute ist {days[today.weekday()]}, der {today.isoformat()}. Tage vor heute NICHT belegen.\n"
    elif today < week_start:
        past_note = f"- Heute ist der {today.isoformat()}, die Planung gilt fuer die kommende Woche.\n"
    mat_lines = "\n".join(
        f"- file_id={m['id']} | Fach: {m['subject']} | Kurs: {m['course_title'][:40]} | {m.get('doc_type') or '?'} | "
        f"Schwierigkeit {m.get('difficulty') or '?'}/5 | ca. {m.get('est_minutes') or '?'} min | {m.get('title') or m['name']}"
        for m in materials
    ) or "- (keine neuen Materialien)"
    subj_lines = "\n".join(f"- {s['subject']} (Wochentest {s['test_minutes']} min)" for s in subjects)
    carry = "\n".join(f"- {c['title']} ({c.get('subject')})" for c in carry_over) or "- keine"
    prompt = f"""Erstelle einen Lernplan fuer die Woche ab Montag {week_start.isoformat()} (bis Sonntag {(week_start + timedelta(days=6)).isoformat()}).

Rahmen:
{past_note}- HARTES LIMIT: maximal {int(settings['hours_per_day'] * 60)} Minuten pro Tag (Summe aller Bloecke eines Tages, Tests eingeschlossen). Lernbeginn ab {settings['day_start']}
- Freie Tage (dort NICHTS einplanen, auch keine Tests): {free}
- Lieber weniger Bloecke als das Tageslimit ueberschreiten; nicht alles muss in diese Woche
- Bloecke zwischen 30 und 120 Minuten, Pausen nicht einplanen (werden automatisch gemacht)
- Reihenfolge nach Sinn: erst Vorlesung lesen, dann die passende Uebung, dann Wiederholung
- Schwierige Themen (4-5) auf mehrere Bloecke verteilen und frueh in der Woche
- Jedes Fach bekommt genau EINEN Block "test" mit der angegebenen Testdauer, bevorzugt am Ende der Woche (Fr/Sa), nie am freien Tag
- Nicht erledigte Punkte der Vorwoche zuerst einplanen

Faecher:
{subj_lines}

Nicht erledigt aus der Vorwoche:
{carry}

Neue / offene Materialien (nach Schwierigkeit und Kurs geordnet):
{mat_lines}

Gib ein JSON-Objekt zurueck:
{{
  "notes": "2-3 Saetze: wie die Woche aufgebaut ist und worauf der Fokus liegt",
  "items": [
    {{"day": 0-6, "start_time": "HH:MM", "duration_min": Zahl, "subject": "Fachname exakt wie oben",
      "file_id": "file_id oder null", "title": "konkrete Aufgabe, z. B. 'GDS Kap. 2 lesen + Zusammenfassung'",
      "kind": "lernen" | "ueben" | "wiederholen" | "test"}}
  ]
}}
day: 0=Montag ... 6=Sonntag. Keine Ueberschneidungen am gleichen Tag."""
    return parse_json(ask(prompt, SYSTEM))


# ----------------------------------------------------------------------------
# 2b) Tutor im Editor (freier Text, Markdown)
# ----------------------------------------------------------------------------

TUTOR_SYSTEM = ("Du bist ein geduldiger Tutor fuer ein Informatik-/Elektrotechnik-Studium im ersten Semester "
                "(Leibniz Universitaet Hannover). Antworte auf Deutsch, klar strukturiert in Markdown, mit kurzen "
                "Absaetzen und Formeln als Text. Beziehe dich konkret auf den gegebenen Seiteninhalt.")

TUTOR_MODES = {
    "explain": "Erklaere den markierten Text bzw. die Formel verstaendlich. Erst einfach, dann etwas genauer, mit einem kleinen Beispiel.",
    "explain_simple": "Erklaere so einfach wie moeglich, als waere ich Anfaenger. Keine Fachbegriffe ohne Erklaerung.",
    "summary": "Fasse die Seite in 5-8 Stichpunkten zusammen und nenne, was man danach koennen muss.",
    "steps": "Loese die Aufgabe (markierter Text oder Seiteninhalt) Schritt fuer Schritt. Erklaere jeden Schritt kurz.",
    "hints": "Gib NUR Hinweise zur Loesung der Aufgabe, keine fertige Loesung. Maximal 3 Hinweise, vom allgemeinen zum konkreten.",
    "check": "Pruefe meine Loesung (unter 'Meine Loesung'). Sage, was richtig ist, wo Fehler sind und wie man sie behebt. Gib am Ende eine Einschaetzung in Punkten von 10.",
    "similar": "Erstelle eine aehnliche Uebungsaufgabe mit gleichem Schwierigkeitsgrad und gib die Loesung getrennt darunter an.",
    "terms": "Definiere die Fachbegriffe auf dieser Seite kurz und praezise (Begriff: Definition).",
    "flashcards": "Erstelle 6-10 Karteikarten aus dem Seiteninhalt. Antworte NUR mit JSON: [{\"question\": \"...\", \"answer\": \"...\"}]",
}


def tutor(mode: str, page_text: str, selection: str = "", question: str = "", own_solution: str = "",
          course: str = "", file_name: str = "", page: int | None = None) -> str:
    instr = TUTOR_MODES.get(mode, TUTOR_MODES["explain"])
    parts = [f"Kurs: {course}", f"Datei: {file_name}" + (f", Seite {page}" if page else ""), "", f"AUFGABE: {instr}"]
    if selection.strip():
        parts += ["", "MARKIERTER TEXT:", "<<<", selection.strip()[:4000], ">>>"]
    if own_solution.strip():
        parts += ["", "MEINE LOESUNG:", "<<<", own_solution.strip()[:4000], ">>>"]
    if question.strip():
        parts += ["", f"MEINE FRAGE: {question.strip()[:1000]}"]
    parts += ["", "SEITENINHALT (Kontext):", "<<<", (page_text or "").strip()[:9000] or "[kein Text extrahierbar]", ">>>"]
    return ask("\n".join(parts), TUTOR_SYSTEM)


# ----------------------------------------------------------------------------
# 3) Test erzeugen und bewerten
# ----------------------------------------------------------------------------

def generate_test(subject: str, duration_min: int, materials: list[dict]) -> dict:
    n_q = 8 if duration_min <= 60 else 12
    mats = "\n\n".join(
        f"### {m.get('title') or m['name']} ({m.get('doc_type')}, Schwierigkeit {m.get('difficulty')})\n{(m.get('text') or '')[:3500]}"
        for m in materials
    )
    prompt = f"""Erstelle einen Wochentest fuer das Fach "{subject}" mit einer Bearbeitungszeit von {duration_min} Minuten.
Etwa {n_q} Aufgaben, Mischung aus Multiple-Choice (genau eine richtige Antwort), Kurzantwort und Rechen-/Programmieraufgaben.
Schwierigkeit gemischt (leicht bis klausurnah). Aufgaben muessen sich auf die Materialien unten beziehen.
Punkte insgesamt = 100.

Materialien dieser Woche:
{mats}

Gib ein JSON-Objekt zurueck:
{{
  "title": "Wochentest {subject} – Thema(n)",
  "questions": [
    {{"nr": 1, "type": "mc" | "short" | "calc", "question": "Aufgabentext (LaTeX-frei, Formeln als Text)",
      "options": ["A ...", "B ...", "C ...", "D ..."],   // nur bei mc
      "answer": "Musterloesung / richtige Option",
      "points": Zahl}}
  ]
}}"""
    return parse_json(ask(prompt, SYSTEM))


def grade_test(subject: str, questions: list[dict], answers: dict) -> dict:
    qa = []
    for q in questions:
        nr = str(q["nr"])
        qa.append(f"Aufgabe {nr} ({q['points']} P., {q['type']}): {q['question']}\n"
                  f"  Musterloesung: {q['answer']}\n  Antwort des Studierenden: {answers.get(nr, '') or '[keine Antwort]'}")
    prompt = f"""Bewerte diesen Wochentest im Fach "{subject}". Sei fair aber streng, Teilpunkte sind erlaubt.
Bei Multiple-Choice zaehlt nur die exakte Option (Buchstabe oder Text).

{chr(10).join(qa)}

Gib ein JSON-Objekt zurueck:
{{
  "total": Zahl,
  "max": Zahl,
  "per_question": [{{"nr": 1, "points": Zahl, "max": Zahl, "feedback": "1-2 Saetze, was richtig/falsch war"}}],
  "summary": "3-4 Saetze Gesamtfeedback mit konkreten Lernempfehlungen",
  "weak_topics": ["Thema", ...]
}}"""
    return parse_json(ask(prompt, SYSTEM))
