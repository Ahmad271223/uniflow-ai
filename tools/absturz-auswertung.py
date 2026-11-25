"""Abstürze je Tag, App-Version und Geräteart zeigen (dünner Aufruf von app/crash_reports.py, nur lesen).

Aus dem Repository mit dem Datenordner des Dienstes (LERNAPP_DATA_DIR):
  python tools/absturz-auswertung.py --tage 14
Im Container des Dienstes (tools/ ist nicht im Image, das Modul schon):
  docker compose exec app python -m app.crash_reports --tage 14
Nur App Store: --quelle store. Als JSON: --json. Hintergrund: docs/ABSTURZMELDUNG-2026-11-25.md.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.crash_reports import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main())
