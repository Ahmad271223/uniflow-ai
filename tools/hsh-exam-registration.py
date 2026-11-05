"""Pruefungsanmeldung an der Hochschule Hannover: Meldezeitraeume je Fakultaet/Abteilung aus den oeffentlichen
Termin- und Informationsseiten (nur aus dem Zwischenspeicher von tools/hsh-catalogs.py, 0 Anfragen) ->
packages/shared-contracts/exam-registration-hsh.json (Aufbau wie exam-registration-luh.json / -hildesheim.json;
Bericht docs/STUDIENGAENGE-HSH-2026-11-05.md, Abschnitt "Pruefungsanmeldung").

Angemeldet wird im Campusmanagement (HISinOne, "Pruefungen anmelden"); jede Abteilung legt ihren Zeitraum selbst fest.
Gelesen werden nur Saetze mit Datum, die eine Anmeldung zu Pruefungen nennen; was nicht gefunden wird, bleibt Link.

Aufruf im Projektordner:
  .venv/bin/python tools/hsh-exam-registration.py           # schreiben
  .venv/bin/python tools/hsh-exam-registration.py --check   # frisch bauen und vergleichen
"""
from __future__ import annotations

import importlib.util
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "packages" / "shared-contracts" / "exam-registration-hsh.json"
REGISTRY = ROOT / "packages" / "shared-contracts" / "study-sources-hsh.json"
CHECKED = "2026-11-05"

_spec = importlib.util.spec_from_file_location("hsh_catalogs", ROOT / "tools" / "hsh-catalogs.py")
CAT = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(CAT)  # type: ignore[union-attr]
CAT.NETWORK[0] = False

MONTHS = {"januar": 1, "februar": 2, "märz": 3, "maerz": 3, "april": 4, "mai": 5, "juni": 6, "juli": 7, "august": 8,
          "september": 9, "oktober": 10, "november": 11, "dezember": 12}
DAY = r"(?:Montag|Dienstag|Mittwoch|Donnerstag|Freitag|Samstag|Sonntag),?\s*"


def _iso(d: int, m: int, y: int) -> str:
    return f"{y:04d}-{m:02d}-{d:02d}"


def text_of(url: str) -> str | None:
    e = CAT.fetch(url)
    if not e or not e.get("abs"):
        return None
    if str(e["abs"]).endswith(".pdf"):
        return "\n".join(CAT.pdf_pages_cached(e["abs"], e.get("sha256")))
    return CAT.HP.html_text(Path(e["abs"]).read_text(errors="replace"))


def flat(t: str) -> str:
    return re.sub(r"\s+", " ", (t or "").replace("¨o", "ö").replace("¨u", "ü").replace("¨a", "ä"))


# ---------------------------------------------------------------- Leser (rein, getestet)

def windows_long(t: str) -> list[dict]:
    """'Montag, 7. September bis Montag, 14. September 2026 Anmeldung zu den Pruefungen im Pruefungszeitraum A'
    (Abteilung Informatik) und 'Montag, 02. November 2026 bis Sonntag, 29. November 2026 Anmeldung zu den Pruefungen'
    (Abteilung Wirtschaftsinformatik)"""
    out = []
    rx = re.compile(DAY + r"(\d{1,2})\.\s*([A-Za-zäöü]+)\s*(\d{4})?\s*bis\s*" + DAY + r"(\d{1,2})\.\s*([A-Za-zäöü]+)\s*(\d{4})\s*"
                    r"Anmeldung zu den Prüfungen(?: im (Prüfungszeitraum [A-Z]|[A-Za-zäöü]+ \d{4}))?")
    for m in rx.finditer(flat(t)):
        y2 = int(m.group(6))
        m1, m2 = MONTHS.get(m.group(2).lower()), MONTHS.get(m.group(5).lower())
        if not m1 or not m2:
            continue
        y1 = int(m.group(3)) if m.group(3) else (y2 if m1 <= m2 else y2 - 1)
        out.append({"start": _iso(int(m.group(1)), m1, y1), "end": _iso(int(m.group(4)), m2, y2),
                    "label": "Anmeldung zu den Prüfungen" + (f" ({m.group(7)})" if m.group(7) else "")})
    return out


def windows_short(t: str) -> list[dict]:
    """'Pruefungsanmeldung Montag, 02.11. bis Sonntag, 22.11.2026' (BWL), 'Online-Anmeldung zu den Pruefungen ...
    14.10.2026 – 28.10.2026' (Maschinenbau), 'Anmeldung fuer die Pruefungen im CMS findet vom 02. November 2026 bis
    29. November 2026 statt' (Pruefungsplan WI)"""
    f = flat(t)
    out = []
    for m in re.finditer(r"Prüfungsanmeldung\s*" + DAY + r"(\d{1,2})\.(\d{1,2})\.(\d{4})?\s*bis\s*" + DAY +
                         r"(\d{1,2})\.(\d{1,2})\.(\d{4})", f):
        y2 = int(m.group(6))
        y1 = int(m.group(3)) if m.group(3) else y2
        out.append({"start": _iso(int(m.group(1)), int(m.group(2)), y1), "end": _iso(int(m.group(4)), int(m.group(5)), y2),
                    "label": "Prüfungsanmeldung"})
    m = re.search(r"Online-Anmeldung zu den Prüfungen findet wie folgt statt:?\s*(\d{1,2})\.(\d{1,2})\.(\d{4})\s*[–-]\s*"
                  r"(\d{1,2})\.(\d{1,2})\.(\d{4})", f)
    if m:
        out.append({"start": _iso(int(m.group(1)), int(m.group(2)), int(m.group(3))),
                    "end": _iso(int(m.group(4)), int(m.group(5)), int(m.group(6))), "label": "Online-Anmeldung zu den Prüfungen"})
    return out


def windows_yearly(t: str) -> dict | None:
    """'Folgende Anmeldezeitraeume gelten ...: Sommersemester: 15.05. bis 31.05. Wintersemester: 15.11. bis 30.11.'
    (Fakultaet III, Abteilung Information und Kommunikation) -> {ss: (TT.MM., TT.MM.), ws: (...)}"""
    m = re.search(r"Anmeldezeiträume gelten.*?Sommersemester:\s*(\d{1,2})\.(\d{1,2})\.\s*bis\s*(\d{1,2})\.(\d{1,2})\.\s*"
                  r"Wintersemester:\s*(\d{1,2})\.(\d{1,2})\.\s*bis\s*(\d{1,2})\.(\d{1,2})\.", flat(t))
    if not m:
        return None
    g = [int(x) for x in m.groups()]
    return {"ss": ((g[0], g[1]), (g[2], g[3])), "ws": ((g[4], g[5]), (g[6], g[7]))}


def withdraw_rule(t: str) -> str | None:
    f = flat(t)
    if re.search(r"bis (?:zu )?eine[rn]? Woche vor (?:der Prüfung|dem Prüfungstermin|Prüfungstermin)", f):
        return "Abmeldung bis eine Woche vor dem Prüfungstermin ohne Angabe von Gründen."
    m = re.search(r"Abmeldung von (?:der )?Prüfung(?:en)? (?:ist )?bis zum (\d{1,2}\.\d{1,2}\.\d{4}) möglich", f)
    if m:
        return f"Abmeldung bis zum {m.group(1)} im Campusmanagement."
    return None


# ---------------------------------------------------------------- Quellen je Abteilung

F4 = "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ"
GROUPS = [
    {"id": "hsh-f4-informatik", "title": "Fakultät IV, Abteilung Informatik", "abbrs": ["BIN", "MIN", "MDI"],
     "page": "https://f4.hs-hannover.de/service/formulare-und-informationen/abteilung-informatik/termine",
     "docs": [f"{F4}/OFI/Informatik/Termine/2026-09-28-Abt_I_Termine_Wintersemester_26-27.pdf"]},
    {"id": "hsh-f4-wi", "title": "Fakultät IV, Abteilung Wirtschaftsinformatik", "abbrs": ["BIS", "VIF", "MDT"],
     "page": "https://f4.hs-hannover.de/service/formulare-und-informationen/abteilung-wirtschaftsinformatik/termine",
     "docs": [f"{F4}/OFI/WI/Termine-Sprechzeiten/26-09-29-WiSe2026-Abt.WI-Semestertermine.pdf",
              f"{F4}/Pruefungsplan/WI/26-10-20-Pruefungsplan-BIS-WiSe_2026.pdf"]},
    {"id": "hsh-f4-bwl", "title": "Fakultät IV, Abteilung Betriebswirtschaft", "abbrs": ["BBA", "IBS", "BBI", "MBD", "MMU"],
     "page": "https://f4.hs-hannover.de/service/formulare-und-informationen/abteilung-betriebswirtschaft/termine",
     "docs": [f"{F4}/OFI/BWL/Formulare_Und_Informationen/Semestertermine_Abteilung_BWL_WiSe26-27.pdf"]},
    {"id": "hsh-f2-m", "title": "Fakultät II, Abteilung Maschinenbau", "abbrs": ["MAB", "WIM", "IIM", "MTD", "KTD", "PTD", "WID", "IID",
                                                                              "WTD", "MED", "PEP", "WMM", "TPE", "MPD", "INPRO", "GEV"],
     "page": "https://f2.hs-hannover.de/service/quicklinks-abteilung-mmd/pruefungsplaene-abt-m-md",
     "docs": ["https://f2.hs-hannover.de/fileadmin/HsH/Fakultaet_II/Abt_M/Dokumente/Sonstiges/Informationen_Pruefungsanmeldung.pdf"]},
    {"id": "hsh-f2-bv", "title": "Fakultät II, Abteilung Bioverfahrenstechnik", "abbrs": ["BIU", "LVT", "MLV", "BML", "LMV", "TNR", "MMV"],
     "page": "https://f2.hs-hannover.de/service/quicklinks-abteilung-bv/pruefungsplaene-abt-bv",
     "docs": ["https://f2.hs-hannover.de/fileadmin/HsH/Fakultaet_II/Abt_BV/Service/Pruefungsplan/Wichtige_Info_zur_Pruefungsanmeldung.pdf"]},
    {"id": "hsh-f3-ik", "title": "Fakultät III, Abteilung Information und Kommunikation",
     "abbrs": ["BIM", "BIB", "BMI", "MMI", "BPR", "BJO", "BVM", "IMC", "MTV", "MKO", "DUAL"],
     "page": "https://f3.hs-hannover.de/studium/pruefungsangelegenheiten",
     "docs": ["https://f3.hs-hannover.de/studium/pruefungsangelegenheiten"]},
    {"id": "hsh-f3-dm", "title": "Fakultät III, Abteilung Design und Medien", "abbrs": ["BIA", "BME", "BMO", "BPD", "SKE", "BVK", "BFO", "MDM"],
     "page": "https://f3.hs-hannover.de/studium/pruefungsangelegenheiten", "docs": []},
    {"id": "hsh-f1", "title": "Fakultät I – Elektro- und Informationstechnik", "faculty": "f1",
     "page": "https://f1.hs-hannover.de/service/f1-quicklinks/zeit-stunden-u-pruefungsplan", "docs": []},
    {"id": "hsh-f5", "title": "Fakultät V – Diakonie, Gesundheit und Soziales", "faculty": "f5",
     "page": "https://f5.hs-hannover.de/studium/studieninformationen/ordnungen", "docs": []},
]


def term_label(start: str) -> str:
    y, m = int(start[:4]), int(start[5:7])
    if m >= 9 or m <= 2:
        y0 = y if m >= 9 else y - 1
        return f"WiSe {y0 % 100:02d}/{(y0 + 1) % 100:02d}"
    return f"SoSe {y % 100:02d}"


def collect() -> dict:
    tables, sources, rules = {}, [], []
    for g in GROUPS:
        periods, said = [], []
        for url in g["docs"]:
            t = text_of(url)
            if not t:
                continue
            found = windows_long(t) + windows_short(t)
            yearly = windows_yearly(t)
            if yearly:
                (sd, sm), (ed, em) = yearly["ws"]
                found.append({"start": _iso(sd, sm, 2026), "end": _iso(ed, em, 2026), "label": "Anmeldezeitraum Wintersemester"})
                (sd, sm), (ed, em) = yearly["ss"]
                found.append({"start": _iso(sd, sm, 2027), "end": _iso(ed, em, 2027), "label": "Anmeldezeitraum Sommersemester (jährlich gleich)"})
            seen = {(p["start"], p["end"]) for p in periods}
            for p in found:
                if (p["start"], p["end"]) not in seen:
                    seen.add((p["start"], p["end"]))
                    periods.append({**p, "source": url})
                    said.append(f"{p['label']}: {p['start']} bis {p['end']}")
            w = withdraw_rule(t)
            if w and w not in [r["text"] for r in rules if r["form"] == g["title"]]:
                rules.append({"form": g["title"], "withdraw_days_before": 7 if "eine Woche" in w else None, "text": w})
            if found:
                sources.append({"url": url, "title": g["title"], "says": "; ".join(said), "checked_at": CHECKED})
        if periods:
            terms: dict[str, list] = {}
            for i, p in enumerate(sorted(periods, key=lambda x: x["start"])):
                terms.setdefault(term_label(p["start"]), []).append(
                    {"kind": "meldung", "n": len(terms.get(term_label(p["start"]), [])) + 1, "label": p["label"],
                     "start": p["start"], "end": p["end"], "source": p["source"]})
            tables[g["id"]] = {"variant": None, "title": g["title"],
                               "terms": [{"term": k, "periods": v} for k, v in terms.items()]}
    return {"tables": tables, "sources": sources, "rules": rules}


def degree_slug(degree: str) -> str:
    d = re.sub(r"[^a-z]", "", (degree or "").lower())
    return {"bsc": "bsc", "msc": "msc", "ba": "ba", "ma": "ma", "beng": "beng", "meng": "meng", "mba": "mba",
            "llb": "llb"}.get(d, "bachelor" if d.startswith("b") else ("master" if d.startswith("m") else d or "x"))


def build() -> dict:
    data = collect()
    reg = json.loads(REGISTRY.read_text(encoding="utf-8"))
    programs, seen = [], set()
    for p in reg.get("programs") or []:
        slug = re.sub(r"[^a-z0-9]+", "-", p["program"].lower().replace("ä", "ae").replace("ö", "oe").replace("ü", "ue")
                      .replace("ß", "ss")).strip("-") + "-" + degree_slug(p["degree"])
        if slug in seen:
            continue
        seen.add(slug)
        g = next((g for g in GROUPS if (p.get("abbr") or "").upper() in g.get("abbrs", [])), None) or \
            next((g for g in GROUPS if g.get("faculty") == p.get("faculty_key")), None)
        programs.append({"slug": slug, "name": p["program"], "degree": p["degree"], "faculty": p.get("faculty"),
                         "url": g["page"] if g else "https://campusmanagement.hs-hannover.de/",
                         "table": g["id"] if g and g["id"] in data["tables"] else None, "variant": None,
                         "checked_at": CHECKED})
    programs.sort(key=lambda x: x["slug"])
    return {
        "v": 1, "university": "hsh",
        "note": ("HsH: Meldezeitraeume je Abteilung aus den oeffentlichen Termin- und Informationsseiten der Fakultaeten "
                 "(sources, gelesen am checked_at); angemeldet wird im Campusmanagement (HISinOne). Abteilungen ohne "
                 "gefundenen Zeitraum nur mit Link (table null). Neu lesen: tools/hsh-exam-registration.py. "
                 "docs/STUDIENGAENGE-HSH-2026-11-05.md"),
        "checked_at": CHECKED,
        "general": {"url": "https://campusmanagement.hs-hannover.de/qisserver/pages/cm/exa/nominalactualcomparison/sollistvergleichBaum.xhtml?_flowId=sollistvergleich-flow",
                    "title": "Prüfungen anmelden (Campusmanagement der Hochschule Hannover)"},
        "qis_menu": "https://campusmanagement.hs-hannover.de/qisserver/pages/cm/exa/nominalactualcomparison/sollistvergleichBaum.xhtml?_flowId=sollistvergleich-flow",
        "system": "HISinOne",
        "hint": ("Im Campusmanagement: Mein Studium → „Prüfungen anmelden“, Prüfung im Baum suchen und „Anmelden“ selbst "
                 "auslösen. StudiNow füllt nichts aus und schickt nichts ab."),
        "disclaimer": ("Verbindlich sind die Angaben im Campusmanagement und auf den Seiten deiner Fakultät. Jede Abteilung "
                       "legt ihren Anmeldezeitraum selbst fest; Labore, Projekte und Abschlussarbeiten melden teils anders an."),
        "sources": data["sources"],
        "rules": data["rules"],
        "tables": data["tables"],
        "programs": programs,
    }


def main(argv: list[str]) -> int:
    data = build()
    text = json.dumps(data, ensure_ascii=False, indent=1) + "\n"
    if "--check" in argv:
        if not OUT.exists() or OUT.read_text(encoding="utf-8") != text:
            print("exam-registration-hsh.json veraltet (tools/hsh-exam-registration.py ausfuehren)")
            return 1
        print("ok")
        return 0
    OUT.write_text(text, encoding="utf-8")
    print(f"{len(data['tables'])} Abteilungen mit Zeitraum, {len(data['programs'])} Studiengaenge -> {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
