#!/usr/bin/env python3
"""Rechts- und Store-Texte in docs/release ausfuellen: Der Inhaber traegt wenige Werte in eine JSON-Datei ein (Vorlage
docs/release/angaben.example.json), das Werkzeug ersetzt alle Platzhalter [[...]] in IMPRESSUM.md, DATENSCHUTZ.md,
NUTZUNGSBEDINGUNGEN.md, KONTO-LOESCHEN.md, APP-STORE.md und PLAY-STORE.md. README.md und BETRIEB.md bleiben unberuehrt
(sie beschreiben die Platzhalter nur).

Aufruf:
    python tools/rechtstexte-fuellen.py angaben.json --check         nur melden, was offen ist (Exit 1, wenn etwas offen
                                                                     oder ein Wert in der JSON leer ist)
    python tools/rechtstexte-fuellen.py angaben.json --out ORDNER    ausgefuellte Dateien in einen anderen Ordner schreiben
                                                                     (z. B. fuer LERNAPP_LEGAL_DIR oder Tests)
    python tools/rechtstexte-fuellen.py angaben.json                 docs/release/*.md an Ort und Stelle ueberschreiben
                                                                     (bewusste Entscheidung des Inhabers; danach
                                                                     tests/test_release_texts.py anpassen, siehe README)
    --src ORDNER                                                     Quelle statt docs/release (fuer Tests)

Stand 03.11.2026: Die Angaben des Inhabers stehen in docs/release/angaben.json und sind in docs/release/*.md an Ort
und Stelle eingesetzt. Offen sind nur noch [[Hoster]], [[Serverstandort]], [[Mail-Anbieter]] (Datenschutz 11),
[[Telefon]] (Play Store) sowie die Schalter und Pruefhinweise der Store-Texte; --check mit angaben.json zeigt sie.

Drei Arten von Platzhaltern:
  * Werte      -> ein Schluessel der JSON ([[Name]], [[E-Mail]], [[Domain]], ...); abgeleitet werden [[Anschrift]]
                  (Strasse + PLZ Ort), [[Jahr]] (aus dem Datum) und die Umsatzsteuer-Zeile des Impressums.
  * Schalter   -> optionale Satzteile der Store-Texte ([[ UND DER UNIVERSITÄT HILDESHEIM]] ...): JSON "funktionen",
                  true = Text bleibt, false = Text faellt weg.
  * Hinweise   -> Pruefhinweise fuer Anwalt oder Einreichung ([[Anwaltlich prüfen.]] ...): werden entfernt und gemeldet.
Ein Platzhalter, der hier nicht eingetragen ist, ist ein Fehler (Exit 1) - so faellt ein neuer Platzhalter auf.

Nach dem Fuellen prueft das Werkzeug, dass kein "[[" mehr vorkommt und kein TODO/TBD/XXX (Regel aus
tests/test_release_texts.py); erst dann schreibt es. Das Datum ist heute (TT.MM.JJJJ), wenn "datum" leer ist.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SRC = ROOT / "docs" / "release"
FILES = ("IMPRESSUM.md", "DATENSCHUTZ.md", "NUTZUNGSBEDINGUNGEN.md", "KONTO-LOESCHEN.md", "APP-STORE.md", "PLAY-STORE.md")
PLACEHOLDER = re.compile(r"\[\[(.+?)\]\]", re.S)
FORBIDDEN = ("TODO", "TBD", "XXX")
DATE_RE = re.compile(r"^\d{2}\.\d{2}\.\d{4}$")
HOST_RE = re.compile(r"^[a-z0-9-]+(\.[a-z0-9-]+)+$")

# Pflichtwerte (Zeichenketten, nicht leer) und optionale Werte (leer erlaubt)
REQUIRED = ("name", "strasse", "plz_ort", "email", "telefon", "domain", "hoster", "hoster_ort", "mail_anbieter",
            "aufsichtsbehoerde", "antwortfrist")
OPTIONAL = ("email_datenschutz", "ustid", "datenschutzbeauftragter", "datum")
COMPANY = ("firma", "rechtsform", "vertreten_durch", "registergericht", "registernummer")   # nur juristische Person
FEATURE_KEYS = ("ipad_hildesheim", "ipad_fristen", "ipad_skriptsuche", "ipad_community_online",
                "android_karteikarten", "android_community")

# Platzhalter (Text in den Klammern, Leerraum normalisiert) -> Schluessel der JSON; "@..." = abgeleitet
VALUES = {
    "Name": "name",
    "Straße Hausnummer": "strasse",
    "PLZ Ort": "plz_ort",
    "Anschrift": "@anschrift",
    "E-Mail": "@email",
    "Telefon": "telefon",
    "Domain": "@domain",
    "Hoster": "hoster",
    "Hosting-Anbieter": "hoster",          # aelterer Name desselben Platzhalters
    "Serverstandort": "hoster_ort",
    "Mail-Anbieter": "mail_anbieter",
    "Aufsichtsbehörde": "aufsichtsbehoerde",
    "Datum": "@datum",
    "Jahr": "@jahr",
    "7 Tagen": "antwortfrist",
    "Firma": "unternehmen.firma",
    "Rechtsform": "unternehmen.rechtsform",
    "Geschäftsführer/in Vorname Nachname": "unternehmen.vertreten_durch",
    "Amtsgericht Ort": "unternehmen.registergericht",
    "HRB …": "unternehmen.registernummer",
    "USt-IdNr.": "@umsatzsteuer",
    "Umsatzsteuer-Identifikationsnummer nach § 27a UStG: USt-IdNr. …": "@umsatzsteuer",
    "Kleinunternehmer nach § 19 UStG, keine USt-IdNr.": "@umsatzsteuer",
    "Falls doch benannt: Name und Kontakt.": "@datenschutzbeauftragter",
}
# Optionale Satzteile der Store-Texte -> Schalter in "funktionen" (alle genannten muessen true sein)
FEATURES = {
    " UND DER UNIVERSITÄT HILDESHEIM": ("ipad_hildesheim",),
    " bzw. Learnweb": ("ipad_hildesheim",),
    ", Abgabefristen und Ankündigungen der Lehrenden": ("ipad_fristen",),
    "• Abgabefristen, Quiz-Termine, Feiertage und vorlesungsfreie Zeit auf einen Blick": ("ipad_fristen",),
    " mit Fristen und Feiertagen": ("ipad_fristen",),
    ", mit Skriptsuche zur Aufgabe": ("ipad_skriptsuche",),
    # seit 04.11.2026: Community ueber CloudKit ist in 1.0 gebaut (Kanal nach Lehrwoche, Fragen und Antworten)
    "; dazu online in der Community deines Kurses nach Lehrwoche, mit Fragen und Antworten, unter Pseudonym, mit Melden und Sperren":
        ("ipad_community_online",),
    "• Eigene Karteikarten mit Wiederholung (Plus)": ("android_karteikarten",),
    "• Lösungen zu Übungsblättern mit anderen vergleichen – verschlüsselt, unter Pseudonym, mit Melden und Sperren (Plus)":
        ("android_community",),
    ", dazu Karteikarten und das Teilen von Lösungen": ("android_karteikarten", "android_community"),
}
# Pruefhinweise: werden beim Fuellen entfernt
NOTES = {
    "Anwaltlich prüfen.",
    "Anwaltlich prüfen: Widerrufsbelehrung und Erlöschen des Widerrufsrechts nach § 356 Abs. 5 BGB, Zuständigkeit von "
    "Apple/Google als Vertragspartner des Kaufs.",
    "mit Apple-Dokumentation zum Zeitpunkt der Einreichung abgleichen",
    "Mit der Google-Dokumentation zum Zeitpunkt der Einreichung abgleichen, ob die Sitzungs-Cookies anzugeben sind.",
    "…",   # PLAY-STORE.md erklaert die Klammer-Schreibweise; der Satz faellt mit den Schaltern weg
}


def norm(inner: str) -> str:
    """Mehrzeilige Platzhalter auf eine Zeile bringen (Leerraum zusammenziehen), Rand erhalten (" UND ..." zaehlt)."""
    return re.sub(r"\s*\n\s*", " ", inner)


class Angaben:
    """Werte aus der JSON samt Pruefung und abgeleiteten Werten."""

    def __init__(self, raw: dict):
        self.raw = raw
        self.errors: list[str] = []
        self.hints: list[str] = []
        self._check()

    @classmethod
    def load(cls, path: Path) -> "Angaben":
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as e:
            raise SystemExit(f"Fehler: {path} nicht lesbar: {e}")
        if not isinstance(raw, dict):
            raise SystemExit(f"Fehler: {path} muss ein JSON-Objekt sein")
        return cls(raw)

    def _str(self, key: str, required: bool) -> str:
        v = self.raw.get(key)
        if v is None:
            self.errors.append(f"{key}: fehlt in der JSON")
            return ""
        if not isinstance(v, str):
            self.errors.append(f"{key}: muss eine Zeichenkette sein")
            return ""
        if required and not v.strip():
            self.errors.append(f"{key}: leer")
        return v.strip()

    def _check(self) -> None:
        raw = self.raw
        self.values = {k: self._str(k, True) for k in REQUIRED}
        self.values.update({k: self._str(k, False) for k in OPTIONAL})
        kl = raw.get("kleinunternehmer")
        if not isinstance(kl, bool):
            self.errors.append("kleinunternehmer: fehlt oder ist nicht true/false")
            kl = False
        self.kleinunternehmer = kl
        if not self.values["ustid"] and not kl:
            self.errors.append("ustid: leer und kleinunternehmer ist nicht true – eins von beiden angeben")
        # juristische Person: alle Felder, sobald "firma" gesetzt ist
        company = raw.get("unternehmen")
        if not isinstance(company, dict):
            self.errors.append("unternehmen: fehlt (Objekt mit firma, rechtsform, vertreten_durch, registergericht, registernummer)")
            company = {}
        self.company = {k: (company.get(k) if isinstance(company.get(k), str) else "").strip() for k in COMPANY}
        self.juristisch = bool(self.company["firma"])
        if self.juristisch:
            for k in COMPANY:
                if not self.company[k]:
                    self.errors.append(f"unternehmen.{k}: leer (bei juristischer Person Pflicht)")
        for k in company:
            if k not in COMPANY and not k.startswith("_"):
                self.hints.append(f"unternehmen.{k}: unbekannter Schluessel, wird ignoriert")
        feats = raw.get("funktionen")
        if not isinstance(feats, dict):
            self.errors.append("funktionen: fehlt (Objekt mit true/false je Schalter)")
            feats = {}
        self.features = {}
        for k in FEATURE_KEYS:
            v = feats.get(k)
            if not isinstance(v, bool):
                self.errors.append(f"funktionen.{k}: fehlt oder ist nicht true/false")
                v = False
            self.features[k] = v
        for k in feats:
            if k not in FEATURE_KEYS and not k.startswith("_"):
                self.hints.append(f"funktionen.{k}: unbekannter Schalter, wird ignoriert")
        known = set(REQUIRED) | set(OPTIONAL) | {"kleinunternehmer", "unternehmen", "funktionen"}
        for k in raw:
            if k not in known and not k.startswith("_"):
                self.hints.append(f"{k}: unbekannter Schluessel, wird ignoriert")
        # Domain: nur der Hostname; die Texte bekommen https://
        dom = re.sub(r"^https?://", "", self.values["domain"]).rstrip("/")
        if dom and not HOST_RE.match(dom):
            self.errors.append(f"domain: '{dom}' ist kein Hostname (erwartet z. B. app.beispiel.de)")
        self.values["domain"] = dom
        # Datum: leer = heute
        d = self.values["datum"]
        if not d:
            d = dt.date.today().strftime("%d.%m.%Y")
            self.datum_auto = True
        else:
            self.datum_auto = False
            if not DATE_RE.match(d):
                self.errors.append(f"datum: '{d}' – erwartet TT.MM.JJJJ oder leer (= heute)")
        self.values["datum"] = d

    # ---- abgeleitete Werte -------------------------------------------------------------------------------------
    @property
    def anschrift(self) -> str:
        return f"{self.values['strasse']}, {self.values['plz_ort']}"

    @property
    def domain_url(self) -> str:
        return "https://" + self.values["domain"]

    @property
    def jahr(self) -> str:
        return self.values["datum"][-4:]

    @property
    def umsatzsteuer(self) -> str:
        if self.values["ustid"]:
            return f"USt-IdNr. nach § 27a UStG: {self.values['ustid']}"
        return "Kleinunternehmer nach § 19 UStG, keine USt-IdNr."

    def email_for(self, filename: str) -> str:
        if filename == "DATENSCHUTZ.md" and self.values["email_datenschutz"]:
            return self.values["email_datenschutz"]
        return self.values["email"]

    def value(self, key: str, filename: str) -> str | None:
        """Ersatztext fuer einen VALUES-Schluessel; None = Platzhalter entfernen."""
        if key == "@anschrift":
            return self.anschrift
        if key == "@email":
            return self.email_for(filename)
        if key == "@domain":
            return self.domain_url
        if key == "@datum":
            return self.values["datum"]
        if key == "@jahr":
            return self.jahr
        if key == "@umsatzsteuer":
            return self.umsatzsteuer
        if key == "@datenschutzbeauftragter":
            dsb = self.values["datenschutzbeauftragter"]
            return f"Datenschutzbeauftragte/r: {dsb}." if dsb else None
        if key.startswith("unternehmen."):
            return self.company[key.split(".", 1)[1]]
        return self.values[key]


def classify(inner: str) -> tuple[str, str]:
    """(Art, Ziel) eines Platzhalters: ('wert', Schluessel) | ('schalter', 'a+b') | ('hinweis', '') | ('unbekannt', '')."""
    n = norm(inner)
    if n in VALUES:
        return "wert", VALUES[n]
    if n in FEATURES:
        return "schalter", "+".join(FEATURES[n])
    if n in NOTES:
        return "hinweis", ""
    return "unbekannt", ""


def substitute(text: str, resolve) -> str:
    """Alle [[...]] durch resolve(inner) ersetzen; None entfernt den Platzhalter samt Leerzeichen/Satzzeichen davor
    bzw. die ganze Zeile, wenn er allein darin steht."""
    out, pos = [], 0
    for m in PLACEHOLDER.finditer(text):
        rep = resolve(m.group(1))
        start, end = m.start(), m.end()
        if rep is None:
            line_start = text.rfind("\n", 0, start) + 1
            line_end = text.find("\n", end)
            line_end = len(text) if line_end == -1 else line_end
            if not text[line_start:start].strip() and not text[end:line_end].strip():
                out.append(text[pos:line_start])
                pos = min(line_end + 1, len(text))
                continue
            out.append(re.sub(r"[;,]?[ \t]*$", "", text[pos:start]))
            pos = end
            continue
        out.append(text[pos:start])
        out.append(rep)
        pos = end
    out.append(text[pos:])
    return "".join(out)


def _impressum(text: str, a: Angaben) -> str:
    """Eine Variante behalten (A natuerliche Person, B juristische Person), Vorlagen-Hinweise entfernen,
    Umsatzsteuer-Block aufloesen."""
    keep, drop = ("B", "A") if a.juristisch else ("A", "B")
    text = re.sub(rf"\n## Variante {drop}[^\n]*\n.*?(?=\n## )", "", text, count=1, flags=re.S)
    text = re.sub(rf"^## Variante {keep}[^\n]*$", "## Angaben nach § 5 DDG", text, count=1, flags=re.M)
    text = re.sub(r"^## Für beide Varianten$", "## Weitere Angaben", text, count=1, flags=re.M)
    text = re.sub(r"^# Impressum – Vorlage$", "# Impressum", text, count=1, flags=re.M)
    text = text.replace("Eine der beiden Varianten verwenden und die Platzhalter ersetzen. ", "")
    text = re.sub(r"(\*\*Umsatzsteuer\*\*\n).*?(?=\n\n|\Z)", lambda m: m.group(1) + a.umsatzsteuer, text, count=1, flags=re.S)
    return re.sub(r"\n{3,}", "\n\n", text)


def _datenschutz(text: str, a: Angaben) -> str:
    dsb = a.values["datenschutzbeauftragter"]
    pat = (r"Einen Datenschutzbeauftragten gibt es nicht, weil die\s+gesetzlichen Voraussetzungen dafür nicht vorliegen\."
           r"\s*\[\[Falls doch benannt: Name und Kontakt\.\]\]")
    new = (f"Datenschutzbeauftragte/r: {dsb}." if dsb
           else "Einen Datenschutzbeauftragten gibt es nicht, weil die gesetzlichen Voraussetzungen dafür nicht vorliegen.")
    return re.sub(pat, new, text, count=1)


def _play_store(text: str) -> str:
    return re.sub(r" – Aussagen in `\[\[…\]\]` erst aufnehmen, wenn die Funktion in der\s+Android-App läuft\.", ".", text, count=1)


def fill(filename: str, text: str, a: Angaben) -> tuple[str, dict]:
    """Ausgefuellter Text und Zaehler {'ersetzt', 'behalten', 'entfernt', 'hinweise': [...], 'unbekannt': [...]}."""
    stats = {"ersetzt": 0, "behalten": 0, "entfernt": 0, "hinweise": [], "unbekannt": []}
    if filename == "IMPRESSUM.md":
        text = _impressum(text, a)
    elif filename == "DATENSCHUTZ.md":
        text = _datenschutz(text, a)
    elif filename == "PLAY-STORE.md":
        text = _play_store(text)

    def resolve(inner: str):
        kind, target = classify(inner)
        if kind == "wert":
            rep = a.value(target, filename)
            if rep is None:
                stats["entfernt"] += 1
            else:
                stats["ersetzt"] += 1
            return rep
        if kind == "schalter":
            if all(a.features[k] for k in target.split("+")):
                stats["behalten"] += 1
                return inner
            stats["entfernt"] += 1
            return None
        if kind == "hinweis":
            stats["hinweise"].append(norm(inner))
            return None
        stats["unbekannt"].append(norm(inner))
        return f"[[{inner}]]"   # bleibt stehen, die Nachpruefung schlaegt an

    return substitute(text, resolve), stats


def verify(filename: str, text: str) -> list[str]:
    """Regeln nach dem Fuellen: kein [[...]], kein TODO/TBD/XXX (tests/test_release_texts.py)."""
    problems = []
    for m in PLACEHOLDER.finditer(text):
        line = text.count("\n", 0, m.start()) + 1
        problems.append(f"{filename}:{line}: Platzhalter offen: [[{norm(m.group(1))}]]")
    for word in FORBIDDEN:
        if word in text:
            problems.append(f"{filename}: enthaelt '{word}'")
    return problems


def check(src: Path, a: Angaben) -> int:
    """Nur melden: offene Platzhalter je Datei mit Ziel, leere Werte. Exit 1, wenn etwas offen ist."""
    open_count = 0
    unknown = []
    for name in FILES:
        p = src / name
        if not p.is_file():
            print(f"{name}: fehlt in {src}")
            open_count += 1
            continue
        text = p.read_text(encoding="utf-8")
        hits = list(PLACEHOLDER.finditer(text))
        if not hits:
            print(f"{name}: keine offenen Platzhalter")
            continue
        print(f"{name}: {len(hits)} offen")
        for m in hits:
            line = text.count("\n", 0, m.start()) + 1
            kind, target = classify(m.group(1))
            shown = norm(m.group(1))
            if kind == "wert":
                if target == "@datum":
                    how = f"datum ({'heute: ' if a.datum_auto else ''}{a.values['datum']})"
                elif target == "@umsatzsteuer":
                    how = "ustid / kleinunternehmer"
                elif target == "@datenschutzbeauftragter":
                    how = "datenschutzbeauftragter (optional)"
                elif target == "@email":
                    how = "email" + (" bzw. email_datenschutz" if name == "DATENSCHUTZ.md" else "")
                else:
                    how = target.lstrip("@").replace("anschrift", "strasse + plz_ort").replace("domain", "domain (https://...)").replace("jahr", "datum (Jahr)")
                desc = f"-> {how}"
            elif kind == "schalter":
                state = all(a.features[k] for k in target.split("+"))
                desc = f"-> funktionen.{target} ({'bleibt' if state else 'faellt weg'})"
            elif kind == "hinweis":
                desc = "-> Pruefhinweis, wird entfernt"
            else:
                desc = "-> UNBEKANNT (in tools/rechtstexte-fuellen.py eintragen)"
                unknown.append(f"{name}:{line}")
            print(f"  {name}:{line}  [[{shown}]]  {desc}")
            open_count += 1
    print()
    if a.errors:
        print("Werte in der JSON mit Problemen:")
        for e in a.errors:
            print(f"  {e}")
    else:
        print("Werte in der JSON: vollstaendig" + (f" (datum leer -> heute {a.values['datum']})" if a.datum_auto else ""))
    for h in a.hints:
        print(f"  Hinweis: {h}")
    if unknown:
        print(f"Unbekannte Platzhalter: {', '.join(unknown)}")
    print(f"\n{open_count} Platzhalter offen in {src}" if open_count else f"\nAlles ausgefuellt in {src}")
    return 1 if (open_count or a.errors) else 0


def run(src: Path, out: Path, a: Angaben) -> int:
    if a.errors:
        print("Fehler in der JSON – nichts geschrieben:")
        for e in a.errors:
            print(f"  {e}")
        return 1
    for h in a.hints:
        print(f"Hinweis: {h}")
    results: dict[str, str] = {}
    problems: list[str] = []
    for name in FILES:
        p = src / name
        if not p.is_file():
            problems.append(f"{name}: fehlt in {src}")
            continue
        text, stats = fill(name, p.read_text(encoding="utf-8"), a)
        results[name] = text
        for u in stats["unbekannt"]:
            problems.append(f"{name}: unbekannter Platzhalter [[{u}]] – in tools/rechtstexte-fuellen.py eintragen")
        problems += verify(name, text)
        extra = ""
        if stats["behalten"] or stats["entfernt"]:
            extra += f", Schalter/Optionales: {stats['behalten']} behalten, {stats['entfernt']} entfernt"
        if stats["hinweise"]:
            extra += f", {len(stats['hinweise'])} Pruefhinweis(e) entfernt"
        print(f"{name}: {stats['ersetzt']} Werte eingesetzt{extra}")
        for h in stats["hinweise"]:
            print(f"    entfernt: [[{h}]]")
    if problems:
        print("\nNicht geschrieben – Nachpruefung fehlgeschlagen:")
        for pr in problems:
            print(f"  {pr}")
        return 1
    out.mkdir(parents=True, exist_ok=True)
    for name, text in results.items():
        (out / name).write_text(text, encoding="utf-8")
    if a.datum_auto:
        print(f"Datum: heute, {a.values['datum']}")
    print(f"\n{len(results)} Dateien geschrieben nach {out}" + (" (an Ort und Stelle)" if out.resolve() == src.resolve() else ""))
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Platzhalter in den Rechts- und Store-Texten (docs/release) ausfuellen.")
    ap.add_argument("angaben", type=Path, help="JSON mit den Werten (Vorlage: docs/release/angaben.example.json)")
    ap.add_argument("--check", action="store_true", help="nur melden, welche Platzhalter offen sind; nichts schreiben")
    ap.add_argument("--out", type=Path, help="Zielordner; ohne Angabe werden die Dateien in der Quelle ueberschrieben")
    ap.add_argument("--src", type=Path, default=DEFAULT_SRC, help="Quelle der Markdown-Dateien (Standard docs/release)")
    args = ap.parse_args(argv)
    a = Angaben.load(args.angaben)
    if args.check:
        return check(args.src, a)
    return run(args.src, args.out or args.src, a)


if __name__ == "__main__":
    sys.exit(main())
