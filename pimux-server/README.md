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

Gets the messages for a session. The server should use ssh to ask the agent for the messages.

Response:

```json
[
  {
    created_at: date,
    role: string,
    body: string,
  }
]
```

## Agent

Each host you run `pi` on needs an agent running. It reports back to the server.

```sh
pimux agent http://location-of-server
```

The agent should find all pi sessions on the host, then report them to its server.