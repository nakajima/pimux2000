#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-4020}"
TMPDIR_ROOT="$(mktemp -d)"
SERVER_LOG="$TMPDIR_ROOT/server.log"
AGENT_LOG="$TMPDIR_ROOT/agent.log"
SESSION_DIR="$TMPDIR_ROOT/sessions/--tmp-live-project--"
SOCKET_PATH="$TMPDIR_ROOT/pimux/live.sock"

cleanup() {
  if [[ -n "${AGENT_PID:-}" ]]; then
    kill "$AGENT_PID" 2>/dev/null || true
    wait "$AGENT_PID" 2>/dev/null || true
  fi
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMPDIR_ROOT"
}
trap cleanup EXIT

mkdir -p "$SESSION_DIR"
cat > "$SESSION_DIR/2026-03-27T00-00-00-000Z_live-session.jsonl" <<'EOF'
{"type":"session","version":3,"id":"live-session","timestamp":"2026-03-27T00:00:00.000Z","cwd":"/tmp/live-project"}
EOF

cd "$ROOT_DIR"

echo "[smoke] building pimux"
cargo build >/dev/null

echo "[smoke] starting server on :$PORT"
PORT="$PORT" ./target/debug/pimux server >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
sleep 1

echo "[smoke] starting agent"
PATH=/usr/bin:/bin ./target/debug/pimux agent run "http://127.0.0.1:$PORT" \
  --pi-agent-dir "$TMPDIR_ROOT" \
  --summary-model dummy >"$AGENT_LOG" 2>&1 &
AGENT_PID=$!
sleep 2

if [[ ! -S "$SOCKET_PATH" ]]; then
  echo "[smoke] expected live socket at $SOCKET_PATH" >&2
  echo "--- agent log ---" >&2
  cat "$AGENT_LOG" >&2
  exit 1
fi

echo "[smoke] sending live session events"
python3 - <<'PY' "$SOCKET_PATH"
import json, socket, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
events = [
  {"type":"sessionAttached","sessionId":"live-session"},
  {"type":"sessionSnapshot","sessionId":"live-session","messages":[
    {"created_at":"2026-03-27T03:00:00Z","role":"user","body":"hello live"}
  ]},
  {"type":"assistantPartial","sessionId":"live-session","message":
    {"created_at":"2026-03-27T03:00:05Z","role":"assistant","body":"typing live"}
  }
]
for event in events:
    sock.sendall((json.dumps(event) + "\n").encode())
sock.close()
PY
sleep 1

echo "[smoke] checking live partial response"
LIVE_RESPONSE="$(curl -fsS "http://127.0.0.1:$PORT/sessions/live-session/messages")"
echo "$LIVE_RESPONSE"
python3 - <<'PY' "$LIVE_RESPONSE"
import json, sys
payload = json.loads(sys.argv[1])
assert payload["freshness"]["state"] == "live", payload
assert payload["freshness"]["source"] == "extension", payload
assert payload["activity"]["active"] is True, payload
assert payload["activity"]["attached"] is True, payload
assert payload["messages"][-1]["body"] == "typing live", payload
PY

echo "[smoke] checking live stream snapshot"
STREAM_EVENT="$(python3 - <<'PY' "$PORT"
import sys, urllib.request
port = sys.argv[1]
req = urllib.request.Request(
    f'http://127.0.0.1:{port}/sessions/live-session/stream',
    headers={'Accept': 'application/x-ndjson'},
)
with urllib.request.urlopen(req, timeout=5) as resp:
    while True:
        line = resp.readline().decode().strip()
        if line:
            print(line)
            break
PY
)"
echo "$STREAM_EVENT"
python3 - <<'PY' "$STREAM_EVENT"
import json, sys
payload = json.loads(sys.argv[1])
assert payload["type"] == "snapshot", payload
session = payload["session"]
assert session["activity"]["active"] is True, payload
assert session["messages"][-1]["body"] == "typing live", payload
PY

echo "[smoke] sending final assistant"
python3 - <<'PY' "$SOCKET_PATH"
import json, socket, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
event = {"type":"sessionAppend","sessionId":"live-session","messages":[
  {"created_at":"2026-03-27T03:00:10Z","role":"assistant","body":"final live reply"}
]}
sock.sendall((json.dumps(event) + "\n").encode())
sock.close()
PY
sleep 0.5

echo "[smoke] checking final live response"
FINAL_RESPONSE="$(curl -fsS "http://127.0.0.1:$PORT/sessions/live-session/messages")"
echo "$FINAL_RESPONSE"
python3 - <<'PY' "$FINAL_RESPONSE"
import json, sys
payload = json.loads(sys.argv[1])
assert payload["activity"]["active"] is True, payload
assert payload["activity"]["attached"] is True, payload
assert payload["messages"][-1]["body"] == "final live reply", payload
PY

echo "[smoke] sending detach"
python3 - <<'PY' "$SOCKET_PATH"
import json, socket, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
event = {"type":"sessionDetached","sessionId":"live-session"}
sock.sendall((json.dumps(event) + "\n").encode())
sock.close()
PY
sleep 0.5

echo "[smoke] checking detached cached response"
DETACHED_RESPONSE="$(curl -fsS "http://127.0.0.1:$PORT/sessions/live-session/messages")"
echo "$DETACHED_RESPONSE"
python3 - <<'PY' "$DETACHED_RESPONSE"
import json, sys
payload = json.loads(sys.argv[1])
assert payload["freshness"]["state"] == "live", payload
assert payload["freshness"]["source"] == "extension", payload
assert payload["activity"]["active"] is False, payload
assert payload["activity"]["attached"] is False, payload
assert payload["messages"][-1]["body"] == "final live reply", payload
PY

echo "[smoke] success"
