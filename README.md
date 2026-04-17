# pimux2000

`pimux2000` is an iOS/iPadOS app for browsing and interacting with `pi` coding-agent sessions through a companion `pimux` server.

This repository contains both:
- the **SwiftUI app** (`pimux2000/`)
- the **Rust server/agent** used to discover hosts, sync sessions, and expose the HTTP API the app talks to (`pimux-server/`)

## Repo layout

- `pimux2000/` — app source
- `pimux2000Tests/` — unit tests for app behavior and data flow
- `pimux2000UITests/` — UI and screenshot tests
- `pimux-server/` — Rust server/agent CLI and HTTP API
- `scripts/` — helper scripts, including screenshot generation
- `docs/` — implementation notes and handoff docs

## Quick start

### iOS app

1. Open `pimux2000.xcodeproj` in Xcode.
2. Build and run the `pimux2000` app target.
3. In the app, configure the server URL to point at a running `pimux` server.

The app stores its local SQLite database in the app documents directory.

### Server

From the repo root:

```sh
PIMUX_BACKUP_POSTGRES_URL=postgres://... cargo run --manifest-path pimux-server/Cargo.toml -- server
```

That starts the local `pimux` server process. `PIMUX_BACKUP_POSTGRES_URL` is required because the iOS app now reads server-backed session data from Postgres. For broader usage, the Rust project also supports managed server and agent installation flows.

See the server README for details:

- [`pimux-server/README.md`](pimux-server/README.md)

## Development notes

### App architecture

The app is a SwiftUI client backed by GRDB for local persistence. At startup it:
- configures image loading
- opens or creates the local database
- optionally installs UI test fixtures
- creates a `PimuxServerClient` when a server URL is configured

### Server architecture

The Rust project provides the `pimux` binary. It includes:
- a server process that exposes the HTTP API used by the app
- an agent process that runs on hosts with `pi` sessions
- live transcript/session synchronization support

## Testing

### App tests

Run from Xcode:
- `pimux2000Tests`
- `pimux2000UITests`

### Server tests

```sh
cargo test --manifest-path pimux-server/Cargo.toml
```

## Screenshots and utilities

Helper scripts live in `scripts/`:

- `scripts/generate-screenshots.sh`
- `scripts/list-active-pi-sessions.py`

## More documentation

- Server/API details: [`pimux-server/README.md`](pimux-server/README.md)
- Additional internal docs: [`docs/README_DOCUMENTATION.md`](docs/README_DOCUMENTATION.md)
