#!/usr/bin/env python3
"""Echter Dienst (LERNAPP_MODE=hosted) fuer die Swift-Tests des Geraete-Abgleichs (`DeviceSyncLiveTests`).

Nur lokal, mit Wegwerf-Daten. POST /__test/account {plan} legt ein bestaetigtes Konto nach der Probe an und liefert
das Token. Aufruf: .venv/bin/python tools/g2-testdienst.py [Port], dann in UniFlowCore:
G2_TEST_SERVICE=http://127.0.0.1:<Port> swift test --filter DeviceSyncLiveTests
"""
import os
import sys
import tempfile
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
data = tempfile.mkdtemp(prefix="g2-dienst-")
os.environ.update(LERNAPP_MODE="hosted", LERNAPP_DATA_DIR=data, LERNAPP_LOG_DIR=data, LERNAPP_ENV_FILE=os.path.join(data, "leer.env"))

import uvicorn  # noqa: E402
from fastapi import Body  # noqa: E402

from app import accounts, server  # noqa: E402


def make(body: dict = Body(...)):
    email = f"g2-{uuid.uuid4().hex[:10]}@example.org"
    user = accounts.register(email, "sehr-geheim-123", "luh")
    accounts.mark_email_verified(user["id"])
    token = accounts.login(email, "sehr-geheim-123")[1]
    accounts.end_trial(user["id"])
    accounts.set_plan(user["id"], body.get("plan") or "plus")
    return {"token": token, "id": user["id"]}


server.app.router.add_api_route("/__test/account", make, methods=["POST"])
server.app.router.routes.insert(0, server.app.router.routes.pop())   # vor der Web-Oberflaeche
uvicorn.run(server.app, host="127.0.0.1", port=int(sys.argv[1]) if len(sys.argv) > 1 else 8931, log_level="warning")
