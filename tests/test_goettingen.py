"""Uni Goettingen (26.11.2026, docs/GOETTINGEN-2026-11-26.md): nur in den Apps angebunden. Der Dienst nimmt Konten mit
dieser Hochschule an, bietet sie in Web-App und PC-Server aber nicht zur Wahl; Mensen und Raeume kennt er. Die
Nachbildung des Stud.IP (apps/apple/DebugStub/goettingen) ist aktuell."""
import subprocess
import sys
from pathlib import Path

from app import config, mensa, rooms, universities

ROOT = Path(__file__).resolve().parents[1]


def test_known_but_not_offered():
    assert universities.valid("goettingen")
    assert "goettingen" in config.known_universities(), "Konten der Apps werden angenommen"
    assert "goettingen" not in universities.offered(), "Web-App und PC-Server bieten sie nicht an"
    assert universities.offered() == ["luh", "hildesheim", "hsh"]
    assert config.normalize_university("goettingen") == universities.DEFAULT, "ein PC-Server laeuft nie als Goettingen"
    p = universities.PROFILES["goettingen"]
    assert p["studip_base"] == "https://studip.uni-goettingen.de" and p["apps_only"] is True
    keys = [s["key"] for s in universities.services("goettingen")]
    assert keys == ["studip", "flexnow", "ecampus", "mail", "sub", "mensa", "lageplan", "studit", "uni"]
    assert [s["key"] for s in universities.services("goettingen") if s.get("connected")] == ["studip"]


def test_profile_for_devices():
    from app.server import university_profile
    p = university_profile("goettingen")
    assert p["login_url"] == "https://studip.uni-goettingen.de/dispatch.php/login"
    assert p["session_cookie"] == "Studip_Session"
    assert p["hosts"] == ["studip.uni-goettingen.de"], "nie die Anmeldeseiten der LUH"


def test_mensa_hidden_outside_goettingen():
    assert universities.hidden_regions("luh") == {"goettingen"}
    assert universities.hidden_regions("goettingen") == set()
    r = mensa.canteens_response("goettingen")
    assert r["default"] == "goe-zentralmensa" and [c["id"] for c in r["canteens"]][:3] == ["goe-zentralmensa", "goe-cgin", "goe-turm"]
    assert mensa.load_data()["sources"]["stwgoe"]["prices"] is False


def test_rooms():
    parts = rooms.parse("ZHG010 (ZHG)", "goettingen")["parts"]
    assert parts[0]["campus"] == "zentralcampus"


def test_lecture_periods_of_goettingen():
    """Stundenplan und Kalender: Goettinger Vorlesungszeit, nicht die der LUH (Rundgang 26.11.2026)."""
    from datetime import date
    from app import holidays
    assert holidays.default_term("goettingen", date(2026, 11, 26)) == {"name": "WiSe 2026/27", "start": "2026-10-26", "end": "2027-02-12"}
    assert holidays.default_term("goettingen", date(2027, 3, 1))["name"] == "SoSe 2027"
    assert holidays.lecture_free(date(2027, 1, 4), "goettingen")        # Weihnachtspause 28.12.-08.01.
    assert not holidays.lecture_free(date(2027, 1, 11), "goettingen")
    assert holidays.lecture_free(date(2026, 10, 20), "goettingen")      # vor dem Beginn am 26.10.


def test_stub_is_current():
    r = subprocess.run([sys.executable, "tools/build-goettingen-stub.py", "--check"], cwd=ROOT, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
