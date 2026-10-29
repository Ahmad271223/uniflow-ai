"""Der gemeinsame KI-Vertrag (packages/shared-contracts/ai/contract.json) passt zu app/ai.py und app/chatgpt_login.py.
Aendert sich ein Prompt, eine Pruefregel oder die Anmeldung, bitte `python tools/gen-ai-contract.py` laufen lassen:
das iPad baut seine Prompts byte-gleich aus diesem Vertrag (AIContractTests)."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_ai_contract_is_current():
    r = subprocess.run([sys.executable, str(ROOT / "tools" / "gen-ai-contract.py"), "--check"], cwd=ROOT,
                       capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, r.stdout + r.stderr
