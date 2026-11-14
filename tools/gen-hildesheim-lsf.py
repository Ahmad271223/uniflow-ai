"""Erzeugt packages/shared-contracts/study-sources-hildesheim-lsf.json aus der Uebersicht der LSF-"Studiengangsplaene"
der Universitaet Hildesheim (abgerufen 14.11.2026 ohne Anmeldung, 12 Anfragen; Eingabe liegt nur lokal:
~/Studora-Builds/hildesheim/lsf-plaene-2026-11-14/uebersicht.json).

Wichtig: Ein LSF-"Studiengangsplan" ist das Wochenraster der Veranstaltungen des laufenden Semesters, KEIN
Studienverlaufsplan (kein Fachsemester, kein Modul, keine LP). Uebernommen werden nur Nummer, Text (Schreibweise im
LSF), Art, Variante, Link und - nur bei sicherer Zuordnung (exakt, regel, regel-po-abweichend, kombination) - der
Registerschluessel. `tools/gen-study-catalog-fixture.py` haengt daraus je Studiengang einen Link (`lsf`) und die
Schreibweisen (`lsf_names`, "aus LSF-Übersicht", nicht bestaetigt) an und legt die Neben-/Begleitfaecher ohne
Registereintrag als waehlbare Eintraege ohne Katalog an.
Aufruf im Projektordner: python tools/gen-hildesheim-lsf.py [Eingabe] [--check]
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "packages" / "shared-contracts" / "study-sources-hildesheim-lsf.json"
DEFAULT_IN = Path.home() / "Studora-Builds" / "hildesheim" / "lsf-plaene-2026-11-14" / "uebersicht.json"
SURE = ("exakt", "regel", "regel-po-abweichend", "kombination")


def build(src: dict) -> dict:
    out = []
    for e in src.get("eintraege") or []:
        if not isinstance(e, dict) or not isinstance(e.get("nummer"), int) or not e.get("text"):
            continue
        out.append({"nummer": e["nummer"], "text": e["text"], "art": e.get("art"), "studiengang": e.get("studiengang"),
                    "variante": e.get("variante"), "url": e.get("url"),
                    "register_key": e.get("register_key") if e.get("zuordnung") in SURE else None})
    out.sort(key=lambda x: x["nummer"])
    return {"v": 1, "university": "hildesheim", "source": src.get("quelle"), "fetched": src.get("abgerufen"),
            "semester": src.get("semester"),
            "note": ("Uebersicht der LSF-Studiengangsplaene: je Eintrag das Wochenraster der Veranstaltungen des laufenden "
                     "Semesters, kein Studienverlaufsplan (kein Fachsemester, kein Modul, keine LP). Schreibweisen aus der "
                     "LSF-Uebersicht, nicht bestaetigt. Erzeugt von tools/gen-hildesheim-lsf.py - nicht von Hand aendern."),
            "entries": out}


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    src_path = Path(args[0]) if args else DEFAULT_IN
    if not src_path.exists():
        print("Eingabe fehlt (nur lokal):", src_path)
        return 0 if "--check" in sys.argv[1:] else 1
    content = json.dumps(build(json.loads(src_path.read_text(encoding="utf-8"))), ensure_ascii=False, indent=1) + "\n"
    if "--check" in sys.argv[1:]:
        ok = OUT.exists() and OUT.read_text(encoding="utf-8") == content
        print(("aktuell: " if ok else "VERALTET: ") + str(OUT.relative_to(ROOT)))
        return 0 if ok else 1
    OUT.write_text(content, encoding="utf-8")
    print("geschrieben:", OUT.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
