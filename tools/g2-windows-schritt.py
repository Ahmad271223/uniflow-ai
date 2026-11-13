#!/usr/bin/env python3
"""Ein Schritt der Windows-App im Rundgang ueber alle Geraete (tools/g2-geraete-rundgang.py, 13.11.2026).

Laeuft wie die Windows-App (Einzelplatz, LERNAPP_DESKTOP=1) mit eigenem Datenordner (LERNAPP_DATA_DIR, setzt der
Rundgang) und dem echten Abgleich (`sync_client.run`) gegen den Testdienst. Aufruf: g2-windows-schritt.py <befehl.json>
mit {out, actions: [{login: {email, password}} | {sql, params?} | {sync: true} | {query, name}]}.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import account_mode, db, service_link, sync_client  # noqa: E402

cmd = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
db.init_db()
out = []
for a in cmd.get("actions") or []:
    if "login" in a:
        # wie die Anmeldemaske der Windows-App (Dienst aus LERNAPP_SERVICE_URL): anmelden, dann Abo-Stand holen
        info = account_mode.login_password(a["login"]["email"], a["login"]["password"])
        out.append({"login": {"device_id": service_link.load_state().get("device_id"), "state": info.get("state"),
                              "plan": info.get("plan")}})
    elif "sql" in a:
        with db.cursor() as conn:
            conn.execute(a["sql"], a.get("params") or [])
    elif "sync" in a:
        out.append({"sync": sync_client.run(force=True)})
    elif "query" in a:
        with db.cursor() as conn:
            out.append({"name": a.get("name"), "rows": db.rows(conn, a["query"])})
Path(cmd["out"]).write_text(json.dumps(out, ensure_ascii=False, default=str), encoding="utf-8")
