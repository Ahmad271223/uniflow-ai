"""Windows-App: eigene Dokumente mit dem StudiNow-Dienst abgleichen (12.11.2026, docs/WINDOWS-FERTIG-2026-11-12.md E3).

Gegenstueck zu `/api/sync/own-documents` und `/api/sync/assets` (app/server.py); gemeinsame Regeln in app/own_docs.py.
Laeuft in `sync_client.run` mit dem Konto des Laufs:

    pruefen (Liste holen; ohne Recht can_sync_annotations: nichts) -> G2 abrufen -> eigene Dokumente -> G2 senden
    -> Bilder hochladen -> G2 abrufen -> Bilder herunterladen

Je Dokument merkt sich `own_doc_link` den Zeitpunkt des Dienstes (`meta_at`) und den Fingerabdruck dieses Geraets
(`own_docs.meta_hash`, Ordner als ID des Dienstes) vom letzten Abgleich. Damit gilt:
- nur hier geaendert -> hochladen; nur im Dienst geaendert -> uebernehmen; beides -> dieses Geraet gewinnt (zuletzt hier
  bearbeitet), der Inhalt einer PDF nur, wenn er sich wirklich unterscheidet (SHA-256)
- hier endgueltig geloescht (Grabstein) -> im Dienst loeschen; im Dienst geloescht -> hier loeschen, ausser es wurde hier
  seitdem geaendert (dann geht es neu hoch: lieber doppelt als verloren)
- Dateien ueber `own_docs.MAX_SYNC_BYTES` bleiben am Geraet und stehen im Ergebnis (`own_skipped`).
Fehler eines Dokuments (z. B. Speicher voll) stehen in `errors`; die anderen gleichen weiter ab.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path

from . import config, db, own_docs, service_link

MAX_ASSET = 15 << 20                     # wie server.MAX_ASSET_BYTES


class PlanRequired(Exception):
    pass


def ensure_tables(conn) -> None:
    own_docs.ensure_tables(conn)
    conn.execute("CREATE TABLE IF NOT EXISTS own_doc_link (file_id TEXT PRIMARY KEY, remote_meta_at TEXT, local_hash TEXT)")


def linked(conn, fid: str) -> bool:
    try:
        return bool(conn.execute("SELECT 1 FROM own_doc_link WHERE file_id=?", (fid,)).fetchone())
    except Exception:                       # noqa: BLE001 - Tabelle fehlt (noch kein Lauf)
        return False


class OwnDocsSync:
    def __init__(self, client):
        from .sync_client import SyncError
        self.SyncError = SyncError
        self.c, self.conn = client, client.conn
        self.stats = client.stats
        for k in ("own_up", "own_down", "own_deleted", "assets_up", "assets_down"):
            self.stats.setdefault(k, 0)
        self.stats.setdefault("own_skipped", [])
        self.stats.setdefault("own_documents", None)
        self.files_dir = own_docs.own_files_dir(config.data_dir())
        self.assets_dir = config.data_dir() / "assets"
        self.remote: dict | None = None

    # ------------------------------------------------ Dienst
    def call(self, method, path, body: bytes | None = None, query="", ctype="application/json"):
        status, _, data = service_link.call(method, path, body, query=query, content_type=ctype, token=self.c.token,
                                            url=self.c.url, timeout=service_link.UPLOAD_TIMEOUT)
        return status, data

    def json_call(self, method, path, body=None, query=""):
        status, data = self.call(method, path, json.dumps(body).encode() if body is not None else None, query=query)
        try:
            d = json.loads(data or b"{}")
        except ValueError:
            d = {}
        detail = d.get("detail") if isinstance(d, dict) else None
        code = (detail or {}).get("code") if isinstance(detail, dict) else (d.get("code") if isinstance(d, dict) else None)
        if status == 403 and code == "plan_required":           # entitlements.forbidden: {"detail": {"code": ...}}
            raise PlanRequired()
        if status >= 400:
            msg = detail.get("detail") if isinstance(detail, dict) else detail
            raise self.SyncError(msg if isinstance(msg, str) else f"Dienst antwortet {status}")
        return d

    # ------------------------------------------------ Ordner
    def remote_folder(self, local_id):
        if local_id is None:
            return None
        m = self.c.map_of_local("folders", local_id)
        return int(m["remote_id"]) if m else None

    def local_folder(self, remote_id):
        if remote_id is None:
            return None
        lid = self.c.local_of("folders", remote_id)
        return int(lid) if lid else None

    def local_view(self, f: dict) -> tuple[dict, str | None, int, str]:
        sha, size = own_docs.content_info(self.conn, f)
        meta = own_docs.meta_of(f)
        meta["folder_id"] = self.remote_folder(f.get("folder_id"))
        return meta, sha, size, own_docs.meta_hash(meta, sha)

    def set_link(self, fid, remote_meta_at, local_hash) -> None:
        self.conn.execute("INSERT INTO own_doc_link(file_id, remote_meta_at, local_hash) VALUES (?,?,?) ON CONFLICT(file_id) "
                          "DO UPDATE SET remote_meta_at=excluded.remote_meta_at, local_hash=excluded.local_hash",
                          (fid, remote_meta_at, local_hash))

    def drop_link(self, fid) -> None:
        self.conn.execute("DELETE FROM own_doc_link WHERE file_id=?", (fid,))

    def notes_changed(self, fid) -> bool:
        """Notizen hier seit dem letzten Abgleich geaendert (noch nicht gesendet)?"""
        a = db.row(self.conn, "SELECT sync_version FROM annotations WHERE file_id=?", (fid,))
        if not a:
            return False
        m = db.row(self.conn, "SELECT local_version FROM sync_link_map WHERE entity='annotations' AND remote_id=?", (fid,))
        return m is None or m["local_version"] != a["sync_version"]

    # ------------------------------------------------ Ablauf
    def probe(self) -> bool:
        """Liste des Dienstes holen; False ohne Recht (dann gleichen eigene Dokumente nicht ab)."""
        ensure_tables(self.conn)
        try:
            self.remote = self.json_call("GET", "/api/sync/own-documents")
        except PlanRequired:
            self.stats["own_documents"] = "plan_required"
            return False
        except (self.SyncError, service_link.LinkError):
            # aelterer Dienst ohne diesen Weg (404) oder gerade nicht erreichbar: G2 laeuft trotzdem
            self.stats["own_documents"] = "unavailable"
            return False
        self.stats["own_documents"] = "ok"
        return True

    def step(self, fn) -> None:
        """Ein Teilschritt; ein Fehler steht im Ergebnis, der Abgleich von Modulen, Notizen usw. laeuft weiter."""
        try:
            fn()
        except (self.SyncError, service_link.LinkError) as e:
            self.stats["errors"].append(f"Eigene Dokumente: {getattr(e, 'message', None) or e}")

    def run(self) -> None:
        remote = self.remote or {"documents": [], "tombstones": []}
        rdocs = {d["id"]: d for d in remote.get("documents") or [] if own_docs.ID_RE.fullmatch(str(d.get("id") or ""))}
        rtombs = {str(t.get("id")) for t in remote.get("tombstones") or []}
        links = {r["file_id"]: r for r in db.rows(self.conn, "SELECT * FROM own_doc_link")}
        local_tombs = {r["file_id"] for r in db.rows(self.conn, "SELECT file_id FROM own_doc_tombstones")}
        limit = int(remote.get("max_bytes") or own_docs.MAX_SYNC_BYTES)

        # 1. hier endgueltig geloescht -> im Dienst loeschen
        for fid in sorted(local_tombs):
            try:
                if fid in rdocs:
                    self.json_call("DELETE", f"/api/sync/own-documents/{fid}")
                    rdocs.pop(fid, None)
                    self.stats["own_deleted"] += 1
                self.drop_link(fid)
                self.conn.execute("DELETE FROM own_doc_tombstones WHERE file_id=?", (fid,))
            except self.SyncError as e:
                self.stats["errors"].append(f"Eigenes Dokument löschen: {e}")

        # 2. im Dienst geloescht -> hier loeschen, wenn hier seit dem letzten Abgleich unveraendert (Dokument und Notizen)
        for fid in sorted(rtombs - set(rdocs)):
            f = db.row(self.conn, "SELECT * FROM files WHERE id=? AND course_id='__user__'", (fid,))
            link = links.pop(fid, None)
            self.drop_link(fid)
            if f and link and self.local_view(f)[3] == link["local_hash"] and not self.notes_changed(fid):
                own_docs.delete_forever(self.conn, fid, self.assets_dir, tombstone=False)
                self.stats["own_deleted"] += 1

        # 3. Dokumente dieses Geraets
        for f in own_docs.own_rows(self.conn):
            fid = f["id"]
            if not own_docs.ID_RE.fullmatch(fid):
                continue
            r = rdocs.pop(fid, None)
            try:
                meta, sha, size, lh = self.local_view(f)
                if size > limit:
                    self.stats["own_skipped"].append(meta.get("title") or fid)
                    continue
                link = links.get(fid)
                if r is None:
                    self.upload(f, meta, sha, None, lh)
                    continue
                rh = own_docs.meta_hash({k: r.get(k) for k in own_docs.META_KEYS}, r.get("sha256"))
                if link is None:
                    if rh == lh:
                        self.set_link(fid, r.get("meta_at"), lh)
                    else:
                        self.apply_remote(r, sha)
                elif link["local_hash"] != lh:
                    self.upload(f, meta, sha, r, lh)
                elif link["remote_meta_at"] != r.get("meta_at"):
                    self.apply_remote(r, sha)
            except self.SyncError as e:
                self.stats["errors"].append(f"{f.get('title') or f.get('name') or fid}: {e}")

        # 4. nur im Dienst -> hierher holen
        for fid, r in sorted(rdocs.items()):
            if fid in local_tombs:
                continue
            if int(r.get("size") or 0) > limit:
                self.stats["own_skipped"].append(r.get("title") or fid)
                continue
            try:
                self.apply_remote(r, None)
            except self.SyncError as e:
                self.stats["errors"].append(f"{r.get('title') or fid}: {e}")

    def upload(self, f: dict, meta: dict, sha: str | None, r: dict | None, lh: str) -> None:
        fid = f["id"]
        d = self.json_call("PUT", f"/api/sync/own-documents/{fid}", meta)
        if sha and d.get("sha256") != sha:
            data = Path(f["local_path"]).read_bytes()
            status, raw = self.call("PUT", f"/api/sync/own-documents/{fid}/content", data, query=f"sha256={sha}",
                                    ctype="application/octet-stream")
            d = self._json_or_raise(status, raw)
        self.set_link(fid, d.get("meta_at"), lh)
        self.stats["own_up"] += 1

    def _json_or_raise(self, status, raw) -> dict:
        try:
            d = json.loads(raw or b"{}")
        except ValueError:
            d = {}
        if status >= 400:
            detail = d.get("detail") if isinstance(d, dict) else None
            msg = detail.get("detail") if isinstance(detail, dict) else detail
            raise self.SyncError(msg if isinstance(msg, str) else f"Dienst antwortet {status}")
        return d

    def apply_remote(self, r: dict, local_sha: str | None) -> None:
        fid = r["id"]
        meta = {k: r.get(k) for k in own_docs.META_KEYS}
        meta["folder_id"] = self.local_folder(r.get("folder_id"))
        data = None
        if r.get("has_content") and r.get("sha256") and r.get("sha256") != local_sha:
            status, data = self.call("GET", f"/api/files/{fid}/content")
            if status != 200:
                raise self.SyncError(f"Inhalt nicht abrufbar ({status})")
            if hashlib.sha256(data).hexdigest() != r["sha256"]:
                raise self.SyncError("Inhalt kam unvollständig an")
        try:
            own_docs.apply_meta(self.conn, fid, meta)
        except own_docs.OwnDocError as e:
            raise self.SyncError(e.message)
        if data is not None:
            target = own_docs.content_target(config.data_dir(), fid, meta)
            target.parent.mkdir(parents=True, exist_ok=True)
            part = target.with_name(target.name + ".part")
            part.write_bytes(data)
            os.replace(part, target)
            own_docs.set_content(self.conn, fid, target)
        f2 = db.row(self.conn, "SELECT * FROM files WHERE id=?", (fid,))
        self.set_link(fid, r.get("meta_at"), self.local_view(f2)[3])
        self.stats["own_down"] += 1

    # ------------------------------------------------ Bilder und PDF-Seiten in Notizen
    def remote_assets(self) -> dict:
        try:
            return self.json_call("GET", "/api/sync/assets").get("assets") or {}
        except PlanRequired:
            return {}

    def assets_up(self) -> None:
        remote = self.remote_assets()
        for d, n in sorted(own_docs.referenced_assets(self.conn)):
            if n in (remote.get(d) or {}):
                continue
            p = self.assets_dir / d / n
            if not p.is_file() or p.stat().st_size > MAX_ASSET:
                continue
            status, raw = self.call("PUT", f"/api/sync/assets/{d}/{n}", p.read_bytes(), ctype="application/octet-stream")
            if status == 404:
                continue                                 # Notiz liegt (noch) nicht im Dienst
            try:
                self._json_or_raise(status, raw)
                self.stats["assets_up"] += 1
            except self.SyncError as e:
                self.stats["errors"].append(f"Bild {n}: {e}")

    def assets_down(self) -> None:
        remote = self.remote_assets()
        for d, n in sorted(own_docs.referenced_assets(self.conn)):
            p = self.assets_dir / d / n
            if p.is_file() or n not in (remote.get(d) or {}):
                continue
            status, data = self.call("GET", f"/api/assets/{d}/{n}")
            if status != 200:
                self.stats["errors"].append(f"Bild {n}: Dienst antwortet {status}")
                continue
            p.parent.mkdir(parents=True, exist_ok=True)
            part = p.with_name(p.name + ".part")
            part.write_bytes(data)
            os.replace(part, p)
            self.stats["assets_down"] += 1
