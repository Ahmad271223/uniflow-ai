"""Startet die Web-Oberflaeche: python serve.py  ->  http://localhost:8765

  python serve.py --lan   -> zusaetzlich im WLAN erreichbar (iPad), Zugriff von anderen Geraeten nur mit PIN

Laeuft der Server schon (Port belegt), wird nur der Browser geoeffnet.
"""
import socket
import sys
import webbrowser

import uvicorn

from app.config import PORT

URL = f"http://localhost:{PORT}"


def public_networks() -> list[str]:
    """Windows: Namen aktiver Netze mit Profil 'Oeffentlich' (z. B. eduroam, Cafe-WLAN). Leer, wenn nicht pruefbar."""
    if sys.platform != "win32":
        return []
    import subprocess
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-Command",
                              "Get-NetConnectionProfile | Where-Object NetworkCategory -eq 'Public' | ForEach-Object Name"],
                             capture_output=True, text=True, timeout=15).stdout
        return [line.strip() for line in out.splitlines() if line.strip()]
    except Exception:  # noqa: BLE001 - Pruefung ist Zusatzschutz, kein Startabbruch bei fehlender PowerShell
        return []


def port_in_use() -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        return s.connect_ex(("127.0.0.1", PORT)) == 0


if __name__ == "__main__":
    if port_in_use():
        print(f"Die Lern-App laeuft bereits: {URL}")
        if "--no-browser" not in sys.argv:
            webbrowser.open(URL)
        sys.exit(0)
    lan = "--lan" in sys.argv
    print(f"Lern-App startet: {URL}")
    if lan:
        import os
        public = public_networks()
        if public and "--public-ok" not in sys.argv:
            print("ABGEBROCHEN: WLAN-Modus in einem oeffentlichen Netz (" + ", ".join(public) + ").")
            print("  Andere Geraete in diesem Netz koennten den Server erreichen. Zu Hause: Netzwerk in Windows auf 'Privat'")
            print("  stellen. Bewusst trotzdem starten: serve.py --lan --public-ok")
            sys.exit(2)
        os.environ["LERNAPP_LAN"] = "1"
        try:
            ips = sorted({i[4][0] for i in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)} - {"127.0.0.1"})
            for ip in ips:
                print(f"  WLAN-Modus (iPad): http://{ip}:{PORT}  -> PIN steht unter Einstellungen > Zugang")
        except OSError:
            pass
    uvicorn.run("app.server:app", host="0.0.0.0" if lan else "127.0.0.1", port=PORT, reload=False)
