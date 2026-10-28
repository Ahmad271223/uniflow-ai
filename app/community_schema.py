"""Community data model for UniFlow.

This module intentionally does not expose public HTTP routes. A production community
must be connected to verified per-user authentication before any endpoint is enabled.
No original university PDFs or university credentials belong in community storage.
"""
from __future__ import annotations

import sqlite3

COMMUNITY_SCHEMA = """
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS community_users (
    id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL CHECK(length(display_name) BETWEEN 1 AND 80),
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    disabled_at TEXT
);
CREATE TABLE IF NOT EXISTS community_groups (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    university TEXT NOT NULL,
    visibility TEXT NOT NULL CHECK(visibility IN ('private','public')),
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS community_memberships (
    group_id TEXT NOT NULL REFERENCES community_groups(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES community_users(id) ON DELETE CASCADE,
    role TEXT NOT NULL CHECK(role IN ('member','moderator','owner')),
    joined_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY(group_id,user_id)
);
CREATE TABLE IF NOT EXISTS community_posts (
    id TEXT PRIMARY KEY,
    group_id TEXT NOT NULL REFERENCES community_groups(id) ON DELETE CASCADE,
    author_id TEXT NOT NULL REFERENCES community_users(id),
    title TEXT NOT NULL CHECK(length(title) BETWEEN 1 AND 160),
    body TEXT NOT NULL CHECK(length(body) BETWEEN 1 AND 20000),
    kind TEXT NOT NULL CHECK(kind IN ('question','discussion','own_solution')),
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_community_posts_group_created
    ON community_posts(group_id,created_at DESC);
CREATE TABLE IF NOT EXISTS community_comments (
    id TEXT PRIMARY KEY,
    post_id TEXT NOT NULL REFERENCES community_posts(id) ON DELETE CASCADE,
    author_id TEXT NOT NULL REFERENCES community_users(id),
    parent_id TEXT REFERENCES community_comments(id),
    body TEXT NOT NULL CHECK(length(body) BETWEEN 1 AND 10000),
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_community_comments_post ON community_comments(post_id,created_at);
CREATE TABLE IF NOT EXISTS community_reports (
    id TEXT PRIMARY KEY,
    reporter_id TEXT NOT NULL REFERENCES community_users(id),
    post_id TEXT REFERENCES community_posts(id),
    comment_id TEXT REFERENCES community_comments(id),
    reason TEXT NOT NULL CHECK(length(reason) BETWEEN 1 AND 1000),
    status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','reviewing','resolved','dismissed')),
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CHECK ((post_id IS NOT NULL) != (comment_id IS NOT NULL))
);
CREATE TABLE IF NOT EXISTS community_moderation_log (
    id TEXT PRIMARY KEY,
    actor_id TEXT NOT NULL REFERENCES community_users(id),
    action TEXT NOT NULL,
    target_type TEXT NOT NULL,
    target_id TEXT NOT NULL,
    reason TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
"""

def initialize_community(conn: sqlite3.Connection) -> None:
    """Create community tables without modifying existing UniFlow tables."""
    conn.executescript(COMMUNITY_SCHEMA)
