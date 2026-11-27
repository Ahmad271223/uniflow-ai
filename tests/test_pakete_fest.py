"""Sicherheitspruefung 27.11.2026: jede fremde Swift-Bibliothek der App (auch indirekte) steht mit exactVersion in
apps/apple/project.yml - so loest Xcode bei jedem Bau dieselben Versionen auf (wie Build 52: WhisperKit 1.1.1,
swift-argument-parser 1.8.2)."""
import re
from pathlib import Path

YML = Path(__file__).resolve().parents[1] / "apps" / "apple" / "project.yml"


def test_every_remote_package_has_an_exact_version():
    text = YML.read_text(encoding="utf-8")
    block = text.split("\npackages:\n", 1)[1].split("\nsettings:\n", 1)[0]
    entries = re.findall(r"^  ([A-Za-z0-9_-]+):\n((?:    .*\n|  #.*\n)*)", block + "\n", re.M)
    remote = {name: body for name, body in entries if "url:" in body}
    assert set(remote) >= {"WhisperKit", "swift-argument-parser"}, sorted(remote)
    for name, body in remote.items():
        assert re.search(r"exactVersion: \d+\.\d+\.\d+", body), f"{name} ohne feste Version"
        assert not re.search(r"(from|minorVersion|majorVersion|branch):", body), name
