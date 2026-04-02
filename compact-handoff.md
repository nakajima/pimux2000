# Compact Handoff

## What this handoff is for
This handoff is for the **next step after compaction**.

The immediate goal is to fix the current builtin-command integration smell:

- `pimux-live.ts` currently registers extension shadow commands for:
  - `/name`
  - `/compact`
  - `/reload`
- Pi warns at startup that these conflict with built-in interactive commands:
  - `Extension command '/name' conflicts with built-in interactive command. Skipping in autocomplete.`
  - same for `/compact` and `/reload`
- user explicitly considers these warnings bad and sees them as evidence that we are integrating at the wrong layer

### Desired outcome
Keep builtin support working in pimux/iOS, but **stop registering fake extension commands that collide with Pi built-ins**.

---

## Core diagnosis
Current live builtin support for `name` / `compact` / `reload` works by sending fake slash text into the attached live Pi runtime:

- server builtin endpoint
- agent `handle_builtin_command(...)`
- `try_run_live_builtin_command(...)`
- `live_store.send_user_message(session_id, "/name ...")` / `"/compact"` / `"/reload"`
- `pimux-live.ts` shadow extension commands intercept those strings

That works functionally, but it is the wrong abstraction boundary because:

- the commands become visible to Pi as extension commands
- Pi emits builtin conflict warnings
- autocomplete skips them
- we are pretending builtins are extension commands instead of using an internal control path

### Correct direction
Do **not** register `/name`, `/compact`, or `/reload` as extension commands.

Instead:

- keep them as pimux-internal live control actions
- send them over the live bridge / IPC directly
- execute them inside the live extension runtime without exposing them to Pi’s slash-command registry

---

## Current working state to preserve
These things are already working and should remain working after the cleanup:

### Mirrored UI primitives
End-to-end mirrored UI support exists for:

- `confirm`
- `select`
- `input`
- `editor`

### Terminal-only unsupported UI fallback
Recently added and working in principle:

- protocol version is now `6`
- `ctx.ui.custom(...)` is detected as terminal-only UI
- server streams `terminalOnlyUiState`
- iOS shows a terminal-only banner
- debug command exists:
  - `/pimux-debug test-custom-ui [title]`

### Current supported iOS builtins
These are currently exposed in the app:

- `/copy`
- `/name`
- `/compact`
- `/new`
- `/fork`
- `/session`
- `/reload`

### Current builtin behavior that must be preserved
- `/copy`: app-native only
- `/session`: app-native only
- `/name`: live when attached; headless RPC fallback when detached
- `/compact`: live when attached; headless RPC fallback when detached
- `/reload`: **live only**; detached should still return:
  - `reload requires an attached live pi session`
- `/new` and `/fork`: headless/server-backed path remains fine as-is

---

## Important separate issue: missing third-party extension commands
This is related context, but **separate** from the builtin warning fix.

Custom pirot commands like `/todo` or `/pirot` were not visible because the active runtime appeared to be using:

- `~/.pi/agent/extensions`

while the pirot-specific extensions live under:

- `~/apps/pirot/.pi/agent/extensions`

That means:

- builtin warning cleanup will remove the bad warnings
- but it will **not by itself** make `/todo` / `/pirot` appear
- that remains a runtime / agent-dir loading issue to diagnose separately if still present

Do not conflate these two problems.

---

## Recommended implementation plan

## Phase 1: remove builtin shadow commands from `pimux-live.ts`
Delete these registrations from the extension:

- `pi.registerCommand("name", ...)`
- `pi.registerCommand("compact", ...)`
- `pi.registerCommand("reload", ...)`

Keep these normal extension commands:

- `/pimux-debug`
- `/pimux`

and any other true extension commands.

### Expected result
Pi should stop printing builtin conflict warnings at startup.

---

## Phase 2: add internal live builtin command IPC
Replace fake slash-text execution with dedicated internal live actions.

### Best shape
Extend the live extension ↔ agent Unix-socket protocol with a new command/result pair for builtin actions.

Suggested command shape:

- `builtinCommand`
  - `requestId`
  - `sessionId`
  - `action`

The action can either:

### Option A: reuse the existing builtin request enum shape
Reuse the existing semantic actions already present on the server side for the subset that needs live execution:

- `setSessionName { name }`
- `compact { customInstructions? }`
- `reload`

This is probably the simplest route.

### Option B: introduce a smaller live-only enum
A dedicated live-only enum would also be fine, but is probably unnecessary.

### Recommendation
Prefer **reusing the existing builtin action semantics** where possible, but only for the live-supported subset.

---

## Phase 3: teach `pimux-live.ts` to execute builtin actions internally
Inside `pimux-live.ts`, handle the new inbound builtin action messages directly.

### Needed capabilities
The extension will need access to the active live session context when executing:

- `ctx.reload()`
- `ctx.compact({ customInstructions })`
- session naming operation

### Likely approach
Cache the current attached `ExtensionContext` / command-capable session context when sessions attach or switch, similar to how current session state is already tracked.

The runtime already tracks:

- `currentSessionId`
- latest snapshot/messages/ui state
- current mirrored dialog state

Extend that with something like:

- current live context for the attached session

Then execute inbound builtin commands directly against that context.

### Notes per builtin
#### `/reload`
Should call the real reload API internally, not send the string `/reload`.

#### `/compact`
Should call the real compact API internally, preserving optional custom instructions.

#### `/name`
Should set the session name directly through the proper runtime API rather than via a fake slash command.

---

## Phase 4: update the agent live store to support builtin action dispatch
In Rust, add live IPC support analogous to the existing dialog-action flow.

Likely files:

- `pimux-server/src/agent/live.rs`
- maybe `pimux-server/src/agent/mod.rs`

### Needed pieces
Add:

- outbound live agent command for builtin action
- inbound builtin action result
- inflight request tracking with timeout
- error mapping similar to:
  - send user message
  - get commands
  - ui dialog action

### Important
This is **extension ↔ agent** plumbing only.

The outer server ↔ agent builtin endpoint already exists and can remain.

---

## Phase 5: change server-side builtin execution to use live builtin IPC
Update the live-attached branch of builtin execution in:

- `pimux-server/src/agent/mod.rs`

### Current code path to replace
Today, attached live builtins go through:

- `try_run_live_builtin_command(...)`
- which calls `live_store.send_user_message(...)`
- which injects fake slash text

That should be replaced for:

- `SetSessionName`
- `Compact`
- `Reload`

with something like:

- `live_store.send_builtin_command(...)`

### What stays the same
Detached/headless behavior stays the same:

- `/name` fallback to headless RPC
- `/compact` fallback to headless RPC
- `/reload` no detached fallback

So the agent-side builtin behavior should remain semantically identical from the app’s point of view.

---

## Phase 6: remove the now-obsolete fake live builtin helper
After the new live builtin IPC is working, remove or narrow:

- `try_run_live_builtin_command(...)`

If it is no longer used, delete it.

If some future action still needs slash-text injection, keep it only for those truly textual cases.

But `name` / `compact` / `reload` should no longer use it.

---

## Files most likely to change

### Definitely
- `pimux-server/extensions/pimux-live.ts`
- `pimux-server/src/agent/live.rs`
- `pimux-server/src/agent/mod.rs`

### Possibly
- `pimux-server/src/session.rs`
  - only if it helps to reuse/reshape builtin action types
- `compact-handoff.md`
  - update after implementation

### Probably not needed
- `pimux-server/src/channel.rs`
  - server↔agent builtin command transport already exists
- iOS files
  - the app should not need changes if semantics stay the same

---

## Protocol/version note
Current live protocol version is:

- `6`

If the extension ↔ agent IPC message schema changes for internal builtin actions, bump it again, likely to:

- `7`

Make sure both sides are bumped together:

- `pimux-server/extensions/pimux-live.ts`
- `pimux-server/src/agent/live.rs`

---

## Validation checklist
After implementation, verify all of these.

### 1. Warnings are gone
Start or reload Pi and confirm these warnings no longer appear:

- `Extension command '/name' conflicts with built-in interactive command. Skipping in autocomplete.`
- `Extension command '/compact' conflicts with built-in interactive command. Skipping in autocomplete.`
- `Extension command '/reload' conflicts with built-in interactive command. Skipping in autocomplete.`

### 2. Attached live builtins still work
In a live attached session:

- `/name foo`
- `/compact`
- `/compact some instructions`
- `/reload`

through the iOS builtin path

### 3. Detached semantics remain unchanged
Without attached live runtime:

- `/name <name>` still works via headless fallback
- `/compact [instructions]` still works via headless fallback
- `/reload` still errors with exactly:
  - `reload requires an attached live pi session`

### 4. Normal extension command discovery still works
Confirm true extension commands continue to be reported through:

- `GET /sessions/{id}/commands`
- `pi.getCommands()` bridge path

And confirm that removing the builtin shadows does **not** regress normal custom command listing.

### 5. Existing mirrored UI work still passes smoke tests
- `/pimux-debug test-confirm`
- `/pimux-debug test-select`
- `/pimux-debug test-input`
- `/pimux-debug test-editor`
- `/pimux-debug test-custom-ui`

### 6. Build/test
Run:

- `cargo test --manifest-path pimux-server/Cargo.toml --quiet`
- `xcodebuild -project pimux2000.xcodeproj -scheme pimux2000 -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

---

## Non-goals for this next step
Do **not** mix these into the same pass unless the warning cleanup is already complete and stable:

- fixing pirot-specific extension loading / per-project agent-dir handling
- adding extension capability badges in the picker
- persisting command capability learning
- redesigning slash-command UX broadly
- changing mirrored UI behavior

Keep this pass focused on:

> removing the bad builtin shadow-command integration and replacing it with internal live builtin control.

---

## Current repo caveats
Do not stomp unrelated modified files already present in the tree, including:

- `pimux2000/Models/AppDatabase.swift`
- `pimux2000/Models/Message.swift`
- `pimux2000/Models/MessageInfo.swift`
- `pimux2000/Models/PiSessionSync.swift`
- `pimux2000/Views/SessionTranscriptView.swift`
- `todo.txt`
- `slash-command.md`

Also note there is already unrelated work in status across some server/app files. Be surgical.

---

## Short summary for the next agent
If resuming cold after compaction, the next concrete task is:

1. remove builtin shadow commands from `pimux-live.ts`
2. add internal live builtin IPC for `name` / `compact` / `reload`
3. switch agent builtin execution from fake slash-text injection to that IPC
4. verify the Pi builtin conflict warnings disappear
5. keep all current builtin semantics unchanged from the app’s perspective

That is the highest-value next cleanup.
