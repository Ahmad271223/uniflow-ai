"""Authenticated community operations; caller must supply verified user ID.

Never take actor_id from untrusted request bodies. Route layer must authenticate
the caller and pass its server-verified principal to these functions.
"""
from __future__ import annotations
import sqlite3
import uuid

class CommunityDenied(PermissionError):
    pass

def _id() -> str:
    return uuid.uuid4().hex

def _member(conn: sqlite3.Connection, group_id: str, actor_id: str) -> str:
    row = conn.execute(
        "SELECT m.role FROM community_memberships m JOIN community_users u ON u.id=m.user_id "
        "WHERE m.group_id=? AND m.user_id=? AND u.disabled_at IS NULL",
        (group_id, actor_id),
    ).fetchone()
    if row is None:
        raise CommunityDenied("Group membership required")
    return row[0]

def create_post(conn: sqlite3.Connection, *, actor_id: str, group_id: str,
                title: str, body: str, kind: str = "discussion") -> str:
    _member(conn, group_id, actor_id)
    if kind not in ("question", "discussion", "own_solution"):
        raise ValueError("Invalid post kind")
    if not (1 <= len(title.strip()) <= 160 and 1 <= len(body.strip()) <= 20000):
        raise ValueError("Invalid post length")
    post_id = _id()
    conn.execute(
        "INSERT INTO community_posts(id,group_id,author_id,title,body,kind) VALUES(?,?,?,?,?,?)",
        (post_id, group_id, actor_id, title.strip(), body.strip(), kind),
    )
    return post_id

def list_posts(conn: sqlite3.Connection, *, actor_id: str, group_id: str,
               limit: int = 30, offset: int = 0) -> list[dict]:
    _member(conn, group_id, actor_id)
    limit = min(max(limit, 1), 100)
    offset = max(offset, 0)
    rows = conn.execute(
        "SELECT id,group_id,author_id,title,body,kind,created_at FROM community_posts "
        "WHERE group_id=? AND deleted_at IS NULL ORDER BY created_at DESC,id DESC LIMIT ? OFFSET ?",
        (group_id, limit, offset),
    ).fetchall()
    return [dict(zip(("id","group_id","author_id","title","body","kind","created_at"), row)) for row in rows]

def create_comment(conn: sqlite3.Connection, *, actor_id: str, post_id: str,
                   body: str, parent_id: str | None = None) -> str:
    row = conn.execute("SELECT group_id FROM community_posts WHERE id=? AND deleted_at IS NULL", (post_id,)).fetchone()
    if row is None:
        raise CommunityDenied("Post unavailable")
    _member(conn, row[0], actor_id)
    if not 1 <= len(body.strip()) <= 10000:
        raise ValueError("Invalid comment length")
    if parent_id is not None:
        parent = conn.execute(
            "SELECT id FROM community_comments WHERE id=? AND post_id=? AND deleted_at IS NULL",
            (parent_id, post_id),
        ).fetchone()
        if parent is None:
            raise ValueError("Invalid parent comment")
    comment_id = _id()
    conn.execute(
        "INSERT INTO community_comments(id,post_id,author_id,parent_id,body) VALUES(?,?,?,?,?)",
        (comment_id, post_id, actor_id, parent_id, body.strip()),
    )
    return comment_id

def report_post(conn: sqlite3.Connection, *, actor_id: str, post_id: str, reason: str) -> str:
    row = conn.execute("SELECT group_id FROM community_posts WHERE id=? AND deleted_at IS NULL", (post_id,)).fetchone()
    if row is None:
        raise CommunityDenied("Post unavailable")
    _member(conn, row[0], actor_id)
    if not 1 <= len(reason.strip()) <= 1000:
        raise ValueError("Invalid reason")
    report_id = _id()
    conn.execute(
        "INSERT INTO community_reports(id,reporter_id,post_id,reason) VALUES(?,?,?,?)",
        (report_id, actor_id, post_id, reason.strip()),
    )
    return report_id

def delete_post(conn: sqlite3.Connection, *, actor_id: str, post_id: str) -> None:
    row = conn.execute(
        "SELECT group_id,author_id FROM community_posts WHERE id=? AND deleted_at IS NULL",
        (post_id,),
    ).fetchone()
    if row is None:
        raise CommunityDenied("Post unavailable")
    role = _member(conn, row[0], actor_id)
    if row[1] != actor_id and role not in ("moderator", "owner"):
        raise CommunityDenied("Insufficient permissions")
    conn.execute("UPDATE community_posts SET deleted_at=CURRENT_TIMESTAMP WHERE id=?", (post_id,))
    conn.execute(
        "INSERT INTO community_moderation_log(id,actor_id,action,target_type,target_id,reason) "
        "VALUES(?,?,'delete','post',?,'user/moderator action')",
        (_id(), actor_id, post_id),
    )
