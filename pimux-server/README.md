# pimux

A companion for the [`pi`](https://github.com/badlogic/pi-mono/tree/main/packages/coding-agent#readme) coding agent.

`pimux` has two runtime pieces:
- a single **server** that the app talks to over HTTP
- one **agent** per host running `pi`

For the iOS app, the important part is the HTTP API documented below.

## Quick start

Run the server:

```sh
pimux server
```

On each host that has `pi` sessions, run an agent pointing at that server:

```sh
pimux agent http://location-of-server
```

For live attached-session updates, also install the bundled pi extension on that host:

```sh
pimux install-extension
```

That writes:

```text
~/.pi/agent/extensions/pimux-live.ts
```

You can override the pi agent root with `PI_CODING_AGENT_DIR` or `--pi-agent-dir`.

## Client API for the iOS app

### General notes

- All timestamps are RFC 3339 / ISO 8601 strings in UTC.
- Responses are JSON.
- There is **no client-facing streaming endpoint yet**. The app should poll and replace its local snapshot.
- `GET /sessions/{id}/messages` returns a **full snapshot**, not a delta.
- Transcript message bodies are **display-oriented plain text**, not raw pi JSON blocks:
  - structured content is flattened
  - whitespace is collapsed
  - live-cached bodies may be capped
- Field naming is mixed on purpose:
  - session summary models use camelCase like `createdAt`
  - transcript messages use `created_at`

### Common error response

Non-2xx responses use this shape:

```json
{
  "error": "human readable message"
}
```

### GET /health

Simple liveness probe.

Response:

```text
OK
```

### GET /version

Response:

```json
{
  "version": "0.1.0"
}
```

### GET /hosts

Returns the hosts currently reported to the server, grouped by host location.

Response shape:

```json
[
  {
    "location": "nakajima@macbook",
    "sessions": [
      {
        "id": "4047b693-44a1-4917-884b-f7d8f2d5882a",
        "summary": "Build live transcript support for pimux",
        "createdAt": "2026-03-27T19:58:53.288Z",
        "lastUserMessageAt": "2026-03-27T20:10:00.000Z",
        "lastAssistantMessageAt": "2026-03-27T20:10:02.000Z",
        "cwd": "/Users/nakajima/apps/pimux2000/pimux-server",
        "model": "anthropic/claude-sonnet-4-5"
      }
    ]
  }
]
```

Notes:
- Hosts are currently sorted by `location`.
- Treat session ordering as non-contractual; sort explicitly in the app if you care.
- A session here means a session the host agent currently discovers from pi's session files.

#### `GET /hosts` model

Each session object has:

- `id: string` — pi session id
- `summary: string` — one-line summary/title
- `createdAt: string`
- `lastUserMessageAt: string`
- `lastAssistantMessageAt: string`
- `cwd: string` — working directory for the session
- `model: string` — model name last associated with the session

### GET /sessions/{id}/messages

Returns the best transcript snapshot the server currently has for a session.

Current behavior:
1. if the server already has a cached snapshot, it returns it immediately
2. otherwise it asks the owning host agent to fetch the transcript on demand
3. it waits up to about **5 seconds** for that host response
4. if the host cannot provide a transcript in time, the request fails

Response shape:

```json
{
  "sessionId": "4047b693-44a1-4917-884b-f7d8f2d5882a",
  "messages": [
    {
      "created_at": "2026-03-27T20:10:00.000Z",
      "role": "user",
      "body": "hello live"
    },
    {
      "created_at": "2026-03-27T20:10:02.000Z",
      "role": "assistant",
      "body": "final live reply"
    }
  ],
  "freshness": {
    "state": "live",
    "source": "extension",
    "asOf": "2026-03-27T20:10:02.000Z"
  },
  "activity": {
    "active": false,
    "attached": false
  },
  "warnings": []
}
```

Notes:
- `messages` are ordered oldest to newest.
- This is a full transcript snapshot for the currently selected branch that pimux knows about.
- `warnings` contains non-fatal notes. Persisted fallback responses currently include a warning explaining that the transcript was reconstructed from disk.

#### Message model

Each message has:

- `created_at: string`
- `role: string`
- `body: string`

Supported `role` values:

- `user`
- `assistant`
- `toolResult`
- `bashExecution`
- `custom`
- `branchSummary`
- `compactionSummary`
- `other`

#### Freshness model

```json
{
  "state": "live",
  "source": "extension",
  "asOf": "2026-03-27T20:10:02.000Z"
}
```

`state` can be:
- `live` — from the live extension path
- `persisted` — reserved supported value; clients should handle it
- `liveUnknown` — reconstructed from persisted session state, so recent in-memory updates may be missing

`source` can be:
- `extension` — from the pi live extension over local IPC
- `helper` — reserved supported value; clients should handle it
- `file` — reconstructed from a persisted session file

Practical current meanings:
- `state = "live"` and `source = "extension"` means the host had a live snapshot from the pi extension
- `state = "liveUnknown"` and `source = "file"` means the transcript was rebuilt from the session file on disk

#### Activity model

```json
{
  "active": true,
  "attached": true
}
```

Interpretation:
- `active = true`, `attached = true`
  - the session is currently attached/live in the host's extension-backed in-memory store
- `active = false`, `attached = false`
  - the session is not currently attached
  - this can still be paired with `freshness.state = "live"` for a recent detached snapshot

The app should treat `freshness` and `activity` separately.
For example, this is valid and expected:
- `freshness.state = "live"`
- `activity.active = false`
- `activity.attached = false`

That means “recently live snapshot, but not currently attached.”

#### Status codes for `GET /sessions/{id}/messages`

- `200 OK` — transcript snapshot returned
- `404 Not Found` — server does not know this session, or the owning host reported that it could not find it
- `502 Bad Gateway` — host-side fetch failed
- `504 Gateway Timeout` — server timed out waiting for the host to provide the transcript

### Recommended polling strategy

Current recommendation for the iOS app:

- session list (`GET /hosts`): every **2–5s** while visible
- open transcript (`GET /sessions/{id}/messages`): every **0.5–1s** while visible
- stop polling when the relevant screen is not visible

There is no SSE/WebSocket push path for the app yet.

## Host/agent setup for live updates

To get live active-session behavior instead of file-only fallback, the host must have:

1. `pimux agent http://...` running
2. `pimux install-extension` run once
3. the pi extension able to talk to the local agent over:

```text
<PI_CODING_AGENT_DIR>/pimux/live.sock
```

The live extension currently uses a Unix domain socket, so this live IPC path is Unix-only.
That is fine for macOS hosts running `pi`.

The agent keeps memory bounded by holding:
- full transcripts only for currently attached live sessions
- a tiny short-lived recently-detached cache
- metadata only for everything else, reconstructed on demand from persisted session files

## Internal agent/server endpoints

These exist for host agents and are **not** intended for the iOS app:

- `POST /report`
- `POST /agent/session-messages`
- `GET /agent/session-messages/pending`
- `POST /agent/session-messages/fetch-response`

## Smoke test

A local end-to-end smoke test for the live path is included:

```sh
./scripts/smoke-live.sh
```
