"""Leseprogramme fuer Modulhandbuch-Formate ausserhalb der FEI (Grundstock der Kataloge, einmal auf dem Mac gelesen,
nie auf dem Geraet; docs/STUDIENGAENGE-LUH-2026-11-04.md). Der modkat-Leser der FEI bleibt in app/study_catalog.py.

Register: Formatname (wie `catalog.format` in packages/shared-contracts/study-sources-luh.json) -> "modul:funktion".
Jede Funktion hat die Form parse(pages: list[str], meta: dict) -> (katalog, lokale_texte) mit Seitentexten wie
app.study_catalog.pdf_pages und meta wie parse_luh_modkat (university, program, degree, po, code, catalog_term,
regular_semesters, total_lp, source). Neue Formate: je eine Zeile in FORMATS.
"""
from __future__ import annotations

import importlib

FORMATS: dict[str, str] = {}
FORMATS["luh-modulbeschreibung"] = "app.catalog_formats.luh_modulbeschreibung:parse"
FORMATS["mb-modulkatalog"] = "app.catalog_formats.mb_modulkatalog:parse"
FORMATS["wiwi-modulhandbuch"] = "app.catalog_formats.wiwi_modulhandbuch:parse"
FORMATS["fbg-modulhandbuch"] = "app.catalog_formats.fbg_modulhandbuch:parse"
FORMATS["phil-kv-tabelle"] = "app.catalog_formats.phil_kv_tabelle:parse"
FORMATS["maphy-katalog"] = "app.catalog_formats.maphy_katalog:parse"


def get_parser(name: str):
    """Leseprogramm eines Formats (erst beim Aufruf geladen) oder None"""
    target = FORMATS.get(name)
    if not target:
        return None
    mod, _, func = target.partition(":")
    return getattr(importlib.import_module(mod), func)
