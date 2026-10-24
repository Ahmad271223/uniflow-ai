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
        os.environ["LERNAPP_LAN"] = "1"
        try:
            ips = sorted({i[4][0] for i in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)} - {"127.0.0.1"})
            for ip in ips:
                print(f"  WLAN-Modus (iPad): http://{ip}:{PORT}  -> PIN steht unter Einstellungen > Zugang")
        except OSError:
            pass
    uvicorn.run("app.server:app", host="0.0.0.0" if lan else "127.0.0.1", port=PORT, reload=False)
