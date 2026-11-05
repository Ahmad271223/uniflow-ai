"""Stand der Abgleich-Stufen und Module je Semester (app/sync_order.py; gleiche Antworten in der iPad-App:
UniFlowCore/Sync/SyncOrder.swift, `SyncOrderEndpoints`).

GET /api/sync-order        {"current": {...}, "older": {"mode", "total", "done", "pending", "running", "paused"}, "hint"}
GET /api/module-semesters  Module je Semester: aktuelles (Modul-IDs), naechstes, fruehere (neuestes zuerst) mit Zahlen
"""
from __future__ import annotations

from fastapi import APIRouter

from . import db, sync_order

router = APIRouter(tags=["sync-order"])


@router.get("/api/sync-order")
def api_status():
    with db.cursor() as conn:
        return sync_order.status(conn)


@router.get("/api/module-semesters")
def api_module_semesters():
    with db.cursor() as conn:
        return sync_order.modules_by_semester(conn)
