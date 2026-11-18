"""Einem StudiNow-Konto einen Tarif schenken (duenner Aufruf von app/tarif_schenken.py).

Aus dem Repository mit dem Datenordner des Dienstes (LERNAPP_DATA_DIR):
  python tools/tarif-schenken.py --email tester@beispiel.de --plan pro_ai --unbefristet --ausfuehren
Im Container des Dienstes (tools/ ist nicht im Image, das Modul schon):
  docker compose exec app python -m app.tarif_schenken --email tester@beispiel.de --plan pro_ai --unbefristet --ausfuehren
Ohne --ausfuehren nur anzeigen. Zuruecknehmen: --zuruecknehmen. Alle Optionen: --help. Hintergrund: docs/release/BETRIEB.md.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.tarif_schenken import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main())
