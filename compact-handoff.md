# Transcript Schema V2 Handoff

_Last updated: 2026-04-09_

## Goal
Preserve tool-call/result linkage and raw role fidelity end-to-end, then backfill historical archive data so old sessions become linkable too.

## Why this work exists
Current raw Pi session files already contain the linkage we need:
- assistant tool-call blocks: `message.content[].type == "toolCall"` with `id`
- tool-result messages: `message.role == "toolResult"` with `toolCallId`

But our normalized archive currently drops both fields. We also collapse unknown roles to literal `"other"`, which loses fidelity and makes future message types hard to inspect.

## Findings from real raw session files
- tool-call blocks are common and have ids
- tool-result messages commonly carry `toolCallId`
- many assistant messages consist mostly or entirely of tool calls, so preserving/rendering them matters
- custom raw entry types like `convo-state`, `planning-mode-state`, and `active-session-registry-work-title-v2` exist in `.jsonl` files but are not top-level message roles

## Required data model changes
### Rust normalized transcript (`pimux-server/src/message.rs`)
- `Role::Other` must become raw-preserving, i.e. `Role::Other(String)` with custom serde
- add `Message.tool_call_id: Option<String>`
- add `MessageContentBlock.tool_call_id: Option<String>` for assistant `toolCall` blocks
- API transport structs must carry the same fields

### Parsing (`pimux-server/src/agent/transcript.rs`, `pimux-server/src/agent/send.rs`)
- preserve raw unknown roles instead of collapsing to `other`
- capture assistant tool-call block `id`
- capture tool-result `toolCallId`

## Archive / Postgres changes
### Schema versioning
Add to `sessions`:
- `transcript_schema_version SMALLINT NOT NULL DEFAULT 1`

Set to:
- `1` for legacy/incomplete transcripts
- `2` for transcripts preserving raw role + tool-call linkage

### Message storage
Add to `messages`:
- `tool_call_id TEXT`
- index on `tool_call_id` where non-null

Keep storing full normalized `message_json` JSONB.

### Migration mechanism
There is no standalone SQL migrator today. The current startup path always runs `SCHEMA_SQL` via `batch_execute`, so migrations must be written as idempotent SQL such as:
- `ALTER TABLE ... ADD COLUMN IF NOT EXISTS ...`
- `CREATE INDEX IF NOT EXISTS ...`

## Dedupe safety requirement
Current message dedupe hashes the full serialized normalized `Message` when `message_id` is absent.

If we simply add new fields, dedupe keys for old messages may change and create duplicates.

### Required fix
Replace dedupe hashing with an explicit legacy-compatible fingerprint payload that excludes the new linkage fields and preserves the old role label semantics for hashing.

Important: dedupe compatibility matters for naturally re-observed sessions before/without backfill.

## Historical backfill strategy
We want historical completeness, so backfill must use authoritative transcript reconstruction from raw session files, not the current archive rows.

### Source of truth
- fetch transcripts from the running server (`/sessions/{id}/messages?hostLocation=...`)
- that server will use live snapshots if present, else rebuild from raw `.jsonl` files on the host

### Backfill write strategy
For each backfilled session, do an authoritative transactional rewrite:
1. upsert session metadata
2. delete existing archived `messages` rows for `(host_location, session_id)`
3. insert rebuilt v2 message rows
4. set `sessions.transcript_schema_version = 2`

This avoids mixed-schema rows and avoids dedupe drift during replay.

### Existing command
There is already a server backfill entrypoint:
- CLI: `pimux server backfill`
- implementation: `pimux-server/src/server/mod.rs`

This should be upgraded to use authoritative transcript replacement instead of plain message upsert.

## UI / product implications
### Immediate fidelity fix
Preserving raw roles will stop collapsing unknown future roles into literal `other`.

### Follow-up rendering work
The web archive still does not render assistant tool-call blocks directly. Many assistant messages are tool-call-heavy or tool-call-only, so after schema v2 lands we should render those blocks explicitly and pair tool results using `tool_call_id`.

## Implementation order
1. **Land compact-safe plan doc** ✅
2. **Rust schema v2**
   - raw-preserving `Role`
   - `tool_call_id` on `Message`
   - `tool_call_id` on `MessageContentBlock`
3. **Parser updates**
   - preserve unknown roles
   - preserve tool-call ids
4. **Dedupe compatibility fix**
5. **Postgres schema migration**
   - `sessions.transcript_schema_version`
   - `messages.tool_call_id`
6. **Archive write-path updates**
   - write schema version 2
   - store `tool_call_id`
7. **Backfill upgrade**
   - rewrite session messages transactionally
8. **Validation**
   - tests for raw role preservation
   - tests for tool-call id preservation
   - tests for dedupe stability
   - tests for backfill replacement semantics
9. **Later UI follow-up**
   - render tool-call blocks in web archive
   - use linkage for result pairing

## Files expected to change first
- `pimux-server/src/message.rs`
- `pimux-server/src/agent/transcript.rs`
- `pimux-server/src/agent/send.rs`
- `pimux-server/src/server/postgres_backup.rs`
- `pimux-server/src/server/mod.rs`
- tests touching message parsing / archive backup

## Current implementation status
- [x] Compact-safe plan written
- [x] Rust schema v2 landed
- [x] Parsers preserve linkage
- [x] Dedupe compatibility fix landed
- [x] Postgres migration landed
- [x] Backfill upgraded to authoritative rewrite
- [x] Tests updated and passing
- [x] Web archive renders assistant tool-call blocks and tool-result backlinks
- [x] iOS transcript preserves and displays short tool-call ids

## Notes for post-compaction continuation
If context is compacted, resume with:
1. read this file
2. current archive/schema/backfill work is landed
3. current web archive now renders tool-call blocks and links results back to calls
4. current iOS app stores `toolCallID` on messages/blocks and shows short ids in transcript UI
5. next optional step is richer iOS pairing/navigation, not basic data preservation
6. run full `cargo test -q` in `pimux-server` and `xcodebuild -project pimux2000.xcodeproj -scheme pimux2000 -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`
