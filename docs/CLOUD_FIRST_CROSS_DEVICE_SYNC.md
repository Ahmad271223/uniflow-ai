# UniFlow Cloud-first Cross-Device Sync — implementation contract

Status: architecture contract only; NOT implemented, deployed or tested. Do not merge as a feature completion.

## Product invariant
One authenticated user sees the same authorized courses, original documents, annotations, comments, calendar and progress on Windows, iPad and iPhone. Device-local caches may lag but must never silently lose confirmed or pending edits.

## Current blockers
Existing single-user LAN PIN / loopback bypass and SQLite deployment must not be exposed publicly. Native iPad DocumentStore currently needs audit of in-flight edit acknowledgement and per-page conflict merges. Windows README says desktop shell not started.

## Target topology
- HTTPS API with authenticated sessions, device registration, per-user authorization and PostgreSQL.
- Private object storage for original documents, immutable versions and previews. Only ingest university materials with authorized access and appropriate rights; enforce course/user access.
- Metadata and file versions in PostgreSQL; file bytes addressed by immutable object key, checksum and size.
- Per-device encrypted/local durable cache, durable operation outbox, and sync cursor.
- Separate import workers for authorized Stud.IP connectors, bounded retries, rate limits, deduplication where access rights permit.
- Event notifications via WebSocket/SSE while foregrounded; reconnect/poll fallback. Notifications are hints, not source of truth.
- Background refresh on Apple is opportunistic, not guaranteed at exact times.

## Required identifiers and operations
Use immutable user_id, course_id, document_id, document_version_id, page_id, object_id, operation_id, device_id. Original PDFs are immutable. Annotations are separate. Acknowledgement identifies exact operation_id or committed revision; never clear dirty flags merely because an earlier upload succeeded. Operation replay must be idempotent. Retain tombstones and support server cursor pagination. Same-page concurrent edits must not be resolved by blind page replacement.

## Minimum API contract (proposed, not yet implemented)
- GET /v1/me
- GET /v1/sync/changes?cursor=...
- POST /v1/sync/operations (idempotency per operation_id; per-item acknowledgements)
- GET /v1/documents/{id} (metadata, rights, version, availability)
- POST /v1/documents/{id}/download-ticket (short-lived authorized URL)
- GET /v1/documents/{id}/annotations?since=...
- GET /v1/import-jobs and POST /v1/import-jobs (authorized integration only)

## Device behavior
1. Login; fetch sync cursor and metadata; render cached files immediately.
2. New university file: import worker validates rights, stores immutable original, emits document-created event.
3. All signed-in devices update library automatically when foregrounded; lazy-download original on first open; offline pin optional.
4. Each edit persists to local outbox BEFORE showing saved status; batch upload in background.
5. Server validates owner, document access, schema, operation ID and base revision, applies atomically, returns exact acks.
6. Client deletes only acknowledged outbox items, applies remote operations without erasing pending edits.
7. Offline deletion or concurrent same-object edits enter explicit conflict resolution; never silently discard data.
8. Logout removes tokens and private cached data according to clear account/device policy.

## Acceptance tests (not yet executed)
- Windows edit -> iPad and iPhone converge after reconnect.
- iPad PencilKit drawing -> Windows renders same position and retains stable IDs.
- 2 devices edit same page offline -> both nonconflicting strokes survive.
- Upload in flight + newer local stroke -> newer stroke remains pending and eventually synced.
- Duplicate operation replay -> one server-side effect.
- Delete while offline edit exists -> conflict surfaced, data retained.
- Different users cannot fetch one another's document, annotation or download URL.
- New Stud.IP slide -> authorized library event -> device downloads lazily; no university PDF in public bucket.
- Large PDF download resume, hash verification and corrupted cache recovery.
- Scale test: 30k concurrent sessions, with realistic mix of sync, downloads, and notifications, no assumed pass.

## Implementation order
P0 account/authorization/tenant isolation; P0 atomic local outbox and lossless sync; P0 private document storage and access checks; P1 Windows desktop packaging; P1 native Apple parity; P1 import workers/events; P1 30k load validation. Maintain existing LAN mode separately until migrated.

## Release gate
No public rollout, claims of completion, paid infrastructure or production migration until code, tests, security review, licensing review and load measurements are complete.
