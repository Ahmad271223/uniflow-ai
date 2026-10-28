# Cloud-first Cross-platform Sync — Implementation Contract (draft)

Status: proposed implementation, **not production-ready**. Existing LAN PIN + SQLite single-user architecture must not be exposed publicly.

## User experience
- One account across Windows, iPad, iPhone, macOS.
- On sign-in, list course and document metadata immediately; fetch PDF bytes on demand from private object storage.
- Keep recently opened documents in per-account local cache for offline access.
- Download new Stud.IP documents through an authorized integration; honor university permissions and copyright.
- Save every edit to a durable local outbox **before** displaying "locally saved". Only display "synced" after server ACK of that exact operation.
- Server sends invalidation notifications (WebSocket/push); client also reconciles using a cursor on foreground, reconnect and periodic refresh. Notifications are not the source of truth.
- Opening a document on another device fetches a consistent document revision and replays authorized operations.

## Storage model
PostgreSQL: users, devices, university_connections, courses, memberships, documents, document_acl, document_revisions, document_operations, sync_cursors, annotation_snapshots.
Private S3-compatible storage: immutable originals and attachment versions; optional content-addressed deduplication only inside authorized sharing boundaries.
Each original: object_key, sha256, size, mime, source_system, source_id, source_revision, owner/tenant, authorization metadata.
Never place credentials, document bytes, user data or secrets in .env. Secrets go to a secret manager / OS credential store; .env for local configuration only.

## Operation protocol
- Device creates globally unique operation_id, document_id, stable page_id and object_id.
- Persist outbox atomically with local edit. Upload in order with auth and idempotency key.
- POST /v1/documents/{id}/operations with base_revision and operation list.
- Server authenticates user, authorizes document, deduplicates operation_id, validates schema and applies in one DB transaction.
- ACK returns committed_revision, accepted operation IDs and server cursor.
- On 409, fetch changes since base_revision, rebase nonconflicting operations; never silently overwrite same-object concurrent edits. Surface unresolved conflicts.
- Tombstones for deletes; document deletion conflicts with offline edits must preserve a recoverable copy.
- Never clear dirty state based on stale snapshot: only ACK exact operation IDs. Uploads in flight do not block new local edits.
- Stable stroke IDs across PKDrawing conversion; preserve native Apple fidelity alongside cross-platform vector representation.
- Client supports schema version negotiation and unknown-field preservation.

## File API (proposed)
GET /v1/sync?cursor=... => changed document metadata, operations, next_cursor
GET /v1/documents/{id} => metadata, revision, permissions, signed read URL after auth
POST /v1/documents/{id}/operations => idempotent ACK
POST /v1/documents/{id}/download-url => short-lived authorized URL
GET /v1/documents/{id}/operations?after_revision=N => paginated operation log
GET /v1/me/devices => registered sessions

## Device integration
Windows Tauri: secure local DB/cache, OS credentials, reconnect sync worker, multi-window safe locking.
Apple SwiftUI/PDFKit/PencilKit: account-scoped local DB/cache, Keychain credentials, BGTask best-effort only, foreground reconciliation mandatory.
Both: same contract fixtures, deterministic operation ordering, same PDF page coordinate system, correct rotation and zoom transforms.

## Security
TLS only; OAuth/OIDC or equivalent session model; per-object authorization on every request; rate limits; audit events; encrypted transport; protected private buckets; no LAN PIN in public service. Prevent cross-user access via direct object keys and predictable IDs.

## Acceptance gates
1. Edit iPad offline; kill app; relaunch; edit remains.
2. Reconnect; exact operation ACK; Windows sees edit within target latency when online.
3. Edit during an in-flight upload; later edit remains pending and reaches server.
4. Concurrent edits on separate pages both survive.
5. Concurrent same-object edits never silently overwrite.
6. Duplicate retries never duplicate strokes.
7. Delete on Windows while iPad offline edits: recoverable conflict.
8. Account A cannot read account B metadata, original bytes, annotations or signed URLs.
9. 100-page PDF + thousands of strokes survives export and device round-trip.
10. 30k connected users and realistic editing/download load measured in staged load tests (not assumed).
11. Revoked course access blocks subsequent downloads.
12. Cold-start on new device lists metadata before PDF download, then opens PDF on demand.

## Migration plan
1. Add new cloud API and storage behind feature flags without changing LAN mode.
2. Add outbox and stable IDs in native Apple and web editor; regression tests.
3. Add Windows Tauri package and native secure storage.
4. Migrate local SQLite data to account-scoped cloud with explicit consent, idempotent imports and rollback.
5. Run security review, E2E tests and load tests; only then deploy.
