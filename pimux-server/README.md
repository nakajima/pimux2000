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

For normal background use, install the server as a per-user service:

```sh
pimux server install
```

To remove it later:

```sh
pimux server uninstall
```

For ad-hoc foreground use on a host that has `pi` sessions:

```sh
pimux agent run http://location-of-server
```

If you omit the scheme, `http://` is assumed, so `pimux agent run localhost:3000` also works.
On startup, the agent:
- checks whether the server is reachable and responds like a pimux server
- if the server is unavailable at startup, stays running and keeps retrying the server websocket connection in the background
- reconciles `~/.pi/agent/extensions/pimux-live.ts` with the bundled extension and updates it if needed
- logs when it had to install/update the on-disk extension
- auto-requests `/reload` for an attached live pi session if it detects that session is still using an older command-capable `pimux-live.ts` runtime that is missing newer live payload fields
- warns if a running pi session is still sending **legacy body-only live payloads**, which usually means that pi session loaded an older extension before the update

For normal background use, install the agent as a per-user service:

```sh
pimux agent install http://location-of-server
```

That now also installs the bundled `pimux-live.ts` extension automatically.

To inspect the installed service:

```sh
pimux agent status
pimux agent logs
```

To remove the service later:

```sh
pimux agent uninstall
```

Platform behavior:
- on **macOS**, `pimux agent install` installs a per-user `launchctl` LaunchAgent
- on **Linux**, `pimux agent install` installs a per-user `systemd --user` service

If you want to install or update only the live extension manually, you can still run:

```sh
pimux install-extension
```

That writes:

```text
~/.pi/agent/extensions/pimux-live.ts
```

You can override the pi agent root with `PI_CODING_AGENT_DIR` or `--pi-agent-dir`.

To update the installed binary itself from the latest GitHub release:

```sh
pimux update
pimux update --check
```

Behavior:
- checks `nakajima/pimux2000` for the latest GitHub release
- downloads the matching macOS/Linux release archive for the current CPU architecture
- replaces the currently running executable in place
- automatically restarts any installed `pimux server` / `pimux agent` per-user service it finds
- reminds you to restart any additional foreground server or agent process manually

## Client API for the iOS app

### General notes

- All timestamps are RFC 3339 / ISO 8601 strings in UTC.
- Responses are JSON, except the live transcript stream which uses **chunked NDJSON**.
- `GET /sessions/{id}/messages` returns a **full snapshot**, not a delta.
- `GET /sessions/{id}/stream` is the client-facing live stream for an open session.
- The server talks to host agents over a **single persistent outbound WebSocket connection** from each agent.
- Transcript messages include both:
  - `body` — display-oriented plain text for compatibility
  - `blocks` — structured display blocks for the app, including thinking text and tool calls
- Live-cached message bodies and blocks may be capped.
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
  "version": "0.2.0"
}
```

### GET /hosts

Returns the hosts the server currently knows about, grouped by host location.

Response shape:

```json
[
  {
    "location": "nakajima@macbook",
    "auth": "none",
    "connected": true,
    "missing": false,
    "lastSeenAt": "2026-03-28T06:20:00.000Z",
    "sessions": [
      {
        "id": "4047b693-44a1-4917-884b-f7d8f2d5882a",
        "summary": "Build live transcript support for pimux",
        "createdAt": "2026-03-27T19:58:53.288Z",
        "updatedAt": "2026-03-27T20:10:02.000Z",
        "lastUserMessageAt": "2026-03-27T20:10:00.000Z",
        "lastAssistantMessageAt": "2026-03-27T20:10:02.000Z",
        "cwd": "/Users/nakajima/apps/pimux2000/pimux-server",
        "model": "anthropic/claude-sonnet-4-5",
        "contextUsage": {
          "usedTokens": 48676,
          "maxTokens": 200000
        }
      }
    ]
  }
]
```

Notes:
- Hosts are currently sorted by `location`.
- Treat session ordering as non-contractual; sort explicitly in the app if you care.
- Hosts are now persisted as an expected-host registry, so a host can still appear here as `missing: true` even when it is currently offline.
- When a host is missing, `sessions` is its last known snapshot from the most recent successful host report.

#### `GET /hosts` model

Each host object has:

- `location: string`
- `auth: "none" | "pk"`
- `connected: boolean` — whether the server currently has a live WebSocket to that host agent
- `missing: boolean` — convenience inverse of `connected` for UI purposes
- `lastSeenAt: string | null` — last successful host contact persisted by the server
- `sessions: Session[]` — last known session snapshot for that host

Each session object has:

- `id: string` — pi session id
- `summary: string` — one-line summary/title
- `createdAt: string`
- `updatedAt: string` — current session file modified time, used for recent-session filtering
- `lastUserMessageAt: string`
- `lastAssistantMessageAt: string`
- `cwd: string` — working directory for the session
- `model: string` — model name last associated with the session
- `contextUsage?: { usedTokens?: number, maxTokens?: number }` — best-effort last known context usage and model window for the session

### POST /hosts

Adds or updates a host in the server’s expected-host registry.

Request shape:

```json
{
  "location": "nakajima@macstudio",
  "auth": "none"
}
```

Notes:
- `auth` is optional and defaults to `"none"`
- newly added hosts start as `connected: false`, `missing: true`, with an empty `sessions` list until an agent reports in
- this is the endpoint the iOS app should use when adding a host so server-side persistence stays in sync

Status codes:
- `204 No Content` — host saved
- `400 Bad Request` — invalid request body or empty location

### DELETE /hosts/{location}

Deletes a host from the server’s expected-host registry.

Notes:
- `{location}` is the host location string as a URL path component
- deleting a host also removes its persisted session snapshot from the server
- currently connected hosts cannot be deleted; disconnect them first
- this is the endpoint the iOS app should use when deleting a host so server-side persistence stays in sync

Status codes:
- `204 No Content` — host deleted
- `404 Not Found` — host is unknown
- `409 Conflict` — host is currently connected

### GET /sessions

Returns a flat recent-session list for the iOS app.

Query params:
- `date=YYYY-MM-DD` — optional local calendar day filter, interpreted in the **server system timezone**

If `date` is omitted, the server returns sessions with `updatedAt` in the **last 24 hours**.

Filtering uses `updatedAt`, which is derived from the session file modified time on the host.

Response shape:

```json
[
  {
    "hostLocation": "nakajima@macbook",
    "hostConnected": true,
    "hostMissing": false,
    "hostLastSeenAt": "2026-03-28T06:20:00.000Z",
    "id": "4047b693-44a1-4917-884b-f7d8f2d5882a",
    "summary": "Build live transcript support for pimux",
    "createdAt": "2026-03-27T19:58:53.288Z",
    "updatedAt": "2026-03-27T20:10:02.000Z",
    "lastUserMessageAt": "2026-03-27T20:10:00.000Z",
    "lastAssistantMessageAt": "2026-03-27T20:10:02.000Z",
    "cwd": "/Users/nakajima/apps/pimux2000/pimux-server",
    "model": "anthropic/claude-sonnet-4-5",
    "contextUsage": {
      "usedTokens": 48676,
      "maxTokens": 200000
    }
  }
]
```

Notes:
- results are sorted newest-first by `updatedAt`
- `date=YYYY-MM-DD` means the local day from local midnight to the next local midnight in the server timezone
- `hostConnected`, `hostMissing`, and `hostLastSeenAt` mirror the owning host status so the app can gray out stale sessions from missing hosts
- `contextUsage` is best-effort metadata derived from the last known assistant usage payload plus the local model registry’s context window for the session model
- invalid `date` values return `400 Bad Request`

### POST /sessions/{id}/messages

Sends a new user message to an existing session.

Request shape:

```json
{
  "body": "continue from here"
}
```

Current behavior:
1. the server finds the owning host for the session
2. it sends a `sendMessage` request to that host's connected agent over the persistent agent WebSocket
3. the host agent chooses the best delivery path:
   - if the session is currently attached in a live `pi` process with the `pimux-live.ts` extension loaded, it asks that live extension to call `pi.sendUserMessage()` inside the already-running session
   - otherwise it falls back to a headless `pi --mode rpc --session ...` runner against the persisted session file
4. it waits for host confirmation that the message was accepted for delivery into the session
5. the app should then keep polling `GET /sessions/{id}/messages` to observe the message and the assistant response

Status codes:
- `204 No Content` — host confirmed the message was accepted
- `400 Bad Request` — invalid request body
- `404 Not Found` — session is unknown or not present on the owning host
- `502 Bad Gateway` — host-side delivery failed
- `504 Gateway Timeout` — timed out waiting for host confirmation

### GET /sessions/{id}/stream

Streams live updates for an open session as **NDJSON**.

Response content type:

```text
application/x-ndjson
```

Current behavior:
1. the server sends an initial `snapshot` event with the full current session snapshot
2. while the host keeps sending live updates, the server emits additional `snapshot` events with newer session state
3. the server also emits `sessionState` events when the owning host becomes connected or missing
4. the server emits periodic `keepalive` events so the app can distinguish an idle stream from a dead connection

Example events:

```json
{"type":"snapshot","sequence":1,"session":{"sessionId":"4047b693-44a1-4917-884b-f7d8f2d5882a","messages":[{"created_at":"2026-03-27T20:10:00.000Z","role":"user","body":"hello live","blocks":[{"type":"text","text":"hello live"}]}],"freshness":{"state":"live","source":"extension","asOf":"2026-03-27T20:10:00.000Z"},"activity":{"active":true,"attached":true},"warnings":[]}}
{"type":"sessionState","sequence":2,"connected":true,"missing":false,"lastSeenAt":"2026-03-28T06:20:00.000Z"}
{"type":"keepalive","sequence":3,"timestamp":"2026-03-28T06:20:10.000Z"}
```

Notes:
- events are newline-delimited JSON objects
- `sequence` is monotonic within a single stream connection
- the app should treat each `snapshot` as authoritative replacement state for the open session
- `GET /sessions/{id}/messages` remains the bootstrap and fallback path

### GET /sessions/{id}/messages

Returns the best transcript snapshot the server currently has for a session.

Current behavior:
1. if the server already has a cached snapshot, it returns it immediately
2. otherwise it asks the owning host agent to fetch the transcript over the persistent agent WebSocket
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
      "body": "hello live",
      "blocks": [
        { "type": "text", "text": "hello live" }
      ]
    },
    {
      "created_at": "2026-03-27T20:10:02.000Z",
      "role": "assistant",
      "body": "final live reply",
      "blocks": [
        { "type": "thinking", "text": "Planning the answer" },
        { "type": "text", "text": "final live reply" }
      ]
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
- `body: string` — compatibility/plain-text rendering field
- `blocks: MessageBlock[]` — structured display blocks for the app

`blocks` entries currently use:
- `type: "text" | "thinking" | "toolCall" | "other"`
- `text?: string`
- `toolCallName?: string`

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

- session list (`GET /hosts` or `GET /sessions`): every **2–5s** while visible
- open transcript:
  1. fetch `GET /sessions/{id}/messages` once for bootstrap
  2. open `GET /sessions/{id}/stream` for live updates while visible
  3. if the stream drops, retry it and use `GET /sessions/{id}/messages` as fallback
- stop polling/streaming when the relevant screen is not visible

## Host/agent setup for live updates

To get live active-session behavior instead of file-only fallback, the host must have:

1. the agent running, either with:
   - `pimux agent run http://...`
   - or `pimux agent install http://...` followed by the background service starting successfully
2. the agent connected to the server over the persistent agent WebSocket
3. the `pimux-live.ts` extension installed:
   - `pimux agent install ...` does this automatically
   - or you can run `pimux install-extension` manually
4. the pi extension able to talk to the local agent over:

```text
<PI_CODING_AGENT_DIR>/pimux/live.sock
```

The live extension currently uses a Unix domain socket, so this live IPC path is Unix-only.
That is fine for macOS hosts running `pi`.

The agent keeps memory bounded by holding:
- full transcripts only for currently attached live sessions
- a tiny short-lived recently-detached cache
- metadata only for everything else, reconstructed on demand from persisted session files

## Local inspection command

### `pimux list`

Lists the local sessions the agent would discover.

```sh
pimux list
pimux list --date 2026-03-27
```

Options:
- `--pi-agent-dir <path>`
- `--summary-model <model>`
- `--date YYYY-MM-DD` — optional local calendar day filter using the system timezone

When `--date` is provided, it filters by `updatedAt` using the same local-day semantics as `GET /sessions?date=...`.
The command prints progress logs to stderr while discovering sessions and resolving LLM summaries.

## Server service details

### `pimux server`

Runs the server in the foreground.

```sh
pimux server
```

The server listens on port `3000` by default.
You can still override that with the `PORT` environment variable.

The server also persists its expected-host registry so hosts can be reported as missing after disconnects or server restarts.
The iOS app can manage that registry via `POST /hosts` and `DELETE /hosts/{location}`.
Default host-registry path:
- macOS: `~/Library/Application Support/pimux/expected-hosts.json`
- Linux: `${XDG_STATE_HOME:-~/.local/state}/pimux/expected-hosts.json`
- override with `PIMUX_SERVER_STATE_PATH`

### `pimux server install`

Installs the server as a **per-user** background service using the current binary path and current `PATH`, then starts it.

```sh
pimux server install
pimux server install --port 3000
```

Supported options:
- `--port <port>` — persist a `PORT` value for the installed service

Behavior:
- **macOS**: writes a LaunchAgent plist under `~/Library/LaunchAgents/`
- **Linux**: writes a `systemd --user` unit under `~/.config/systemd/user/`
- the installed service runs the equivalent of:

```sh
pimux server
```

Notes:
- reinstalling updates the service definition and reloads/restarts it
- on Linux, a `systemd --user` service may require user-session/linger setup depending on how that host is managed; this first implementation is per-user only

### `pimux server uninstall`

Stops and removes the per-user service definition.

```sh
pimux server uninstall
```

## Agent service details

### `pimux agent run`

Runs the agent in the foreground.

```sh
pimux agent run http://localhost:3000
```

Supported options:
- `--location <user@host>`
- `--auth none|pk`
- `--pi-agent-dir <path>`
- `--summary-model <model>`

Behavior:
- auto-normalizes `localhost:3000` to `http://localhost:3000`
- verifies `GET /health` and `GET /version` before starting
- opens a persistent outbound WebSocket to `/agent/connect`

### `pimux agent install`

Installs the agent as a **per-user** background service using the current binary path and current `PATH`.
It also installs the bundled `pimux-live.ts` extension.

```sh
pimux agent install http://localhost:3000
```

Supported options:
- `--location <user@host>`
- `--auth none|pk`
- `--pi-agent-dir <path>`
- `--summary-model <model>`
- `--force-extension` — overwrite an existing bundled live extension file if it differs

Behavior:
- **macOS**: writes a LaunchAgent plist under `~/Library/LaunchAgents/`
- **Linux**: writes a `systemd --user` unit under `~/.config/systemd/user/`
- the installed service runs the equivalent of:

```sh
pimux agent run http://localhost:3000 ...
```

Notes:
- reinstalling updates the service definition and reloads/restarts it
- `agent install` also installs the bundled live extension so live updates work without a second command in the common case
- `agent run` now also keeps the on-disk bundled live extension up to date at startup
- if an attached live pi session is command-capable but still sends older metadata-less live payloads, the agent now auto-requests `/reload` in that session once so it can load the updated extension without a manual restart
- if the agent logs a warning about **body-only live payloads**, the file on disk has been updated but one or more already-running pi sessions may still have older extension code loaded
- on Linux, a `systemd --user` service may require user-session/linger setup depending on how that host is managed; this first implementation is per-user only

### `pimux agent status`

Shows a small human-readable status summary for the per-user service.

```sh
pimux agent status
```

On macOS this reports LaunchAgent/plist/log status.
On Linux this reports `systemd --user` unit status and the journalctl command to inspect logs.
It also reports the bundled live extension file state as one of:
- `current`
- `stale`
- `missing`

### `pimux agent logs`

Shows recent service logs.

```sh
pimux agent logs
pimux agent logs --lines 200
pimux agent logs --follow
```

Behavior:
- **macOS**: reads or tails the LaunchAgent stdout/stderr log files
- **Linux**: proxies to `journalctl --user-unit pimux-agent.service`

### `pimux agent uninstall`

Stops and removes the per-user service definition.

```sh
pimux agent uninstall
```

This does **not** remove `pimux-live.ts`; keep it for future reinstalls or remove it manually if you want.

### `pimux update`

Downloads the latest release from `nakajima/pimux2000` for the current platform and replaces the current executable.

```sh
pimux update
pimux update --check
pimux update --force
```

Notes:
- `--check` only reports whether a newer release is available
- `--force` reinstalls the latest release even if the version already matches
- after a successful update, installed `pimux server` and `pimux agent` per-user services are restarted automatically when possible
- any additional foreground `pimux server` / `pimux agent` processes still need a manual restart
- if the current executable location is not writable, the command fails with a permission error

## Internal agent/server channel

These are used by host agents and are **not** intended for the iOS app:

- `GET /agent/connect` — WebSocket upgrade endpoint for the persistent server↔agent channel

The old agent polling and bulk-report HTTP endpoints have been removed.

## Smoke test

A local end-to-end smoke test for the live path is included:

```sh
./scripts/smoke-live.sh
```
