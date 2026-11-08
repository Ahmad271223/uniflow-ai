"""TestFlight-Tester freischalten: Probe des StudiNow-Kontos verlaengern (duenner Aufruf von app/tester_freischalten.py).

Aus dem Repository mit dem Datenordner des Dienstes (LERNAPP_DATA_DIR):
  python tools/tester-freischalten.py --email tester@beispiel.de --tage 14 --ausfuehren
Im Container des Dienstes (tools/ ist nicht im Image, das Modul schon):
  docker compose exec app python -m app.tester_freischalten --email tester@beispiel.de --tage 14 --ausfuehren
Ohne --ausfuehren nur anzeigen. Alle Optionen: --help. Hintergrund: docs/release/TESTFLIGHT-500-2026-11-08.md.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.tester_freischalten import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main())
