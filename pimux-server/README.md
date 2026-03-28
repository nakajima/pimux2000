# pimux

A companion for the [`pi`](https://github.com/badlogic/pi-mono/tree/main/packages/coding-agent#readme) coding agent. It consists of two parts:

## Server

You have one of these. It collects info from agents.

### Running it

```sh
pimux server
```

### Endpoints

#### GET /version

Response:

```json
{
  "version": "1.2.3"
}
```

#### POST /report

Used by agents to report their status.

Request:

```json
{
  "host": {
    "location": string,   // eg "nakajima@arch"
    "auth": "none" | "pk" // How it's reachable via ssh by the server. "none" is used when we can just use tailscale ssh. "pk" is when we need a key setup.
  },
  "active_sessions": [
    {
      "id": string,                   // pi's session id
      "summary": string,              // a one-liner summary of this session
      "createdAt": date,              // when the session was started
      "lastUserMessageAt": date,      // when the user last sent a message
      "lastAssistantMessageAt": date, // when the last ai message was snet
      "cwd": string,                  // the directory of the pi session
      "model": string,                // the LLM model the session is using
    }
  ]
}
```

#### GET /hosts

Response:

```json
[
  {
    "location": string
    "sessions": [
      {
        "id": string,                   // pi's session id
        "summary": string,              // a one-liner summary of this session
        "createdAt": date,              // when the session was started
        "lastUserMessageAt": date,      // when the user last sent a message
        "lastAssistantMessageAt": date, // when the last ai message was snet
        "cwd": string,                  // the directory of the pi session
        "model": string,                // the LLM model the session is using
      }
    ]
  },
  // ..
]
```

#### GET /sessions/:id/messages

Gets the best transcript snapshot the server currently has for a session.

Current implementation notes:
- The host remains the canonical source of session state.
- The server keeps **cached transcript snapshots** reported by agents for recent sessions.
- Agents now support a **live local IPC path** for active sessions, so extension-attached sessions can warm the server cache with `freshness.state = "live"` snapshots.
- To keep host memory bounded, agents keep full live transcripts only for currently attached sessions plus a very small short-lived recently-detached cache; everything else is reconstructed on demand.
- On a cache miss, the server queues an **on-demand fetch request** to the owning host and waits briefly for the agent to fulfill it.
- If the host does not respond in time, the server returns an error instead of silently returning stale data.
- Transcript responses include freshness metadata so callers can distinguish between live, persisted, and unknown freshness.

Response:

```json
{
  "sessionId": string,
  "messages": [
    {
      "created_at": date,
      "role": string,
      "body": string
    }
  ],
  "freshness": {
    "state": "live" | "persisted" | "liveUnknown",
    "source": "extension" | "helper" | "file",
    "asOf": date
  },
  "activity": {
    "active": boolean,
    "attached": boolean
  },
  "warnings": [string]
}
```

## Agent

Each host you run `pi` on needs an agent running. It reports back to the server.

```sh
pimux agent http://location-of-server
```

The agent should find all pi sessions on the host, then report them to its server.

### Live extension

For live active-session updates, install the bundled pi extension on the host:

```sh
pimux install-extension
```

This writes `pimux-live.ts` into pi's auto-discovered extensions directory:

```text
~/.pi/agent/extensions/pimux-live.ts
```

You can override the target root with `PI_CODING_AGENT_DIR` or `--pi-agent-dir`.

The extension sends live session updates to the local agent over a Unix socket at:

```text
<PI_CODING_AGENT_DIR>/pimux/live.sock
```