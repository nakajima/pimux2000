# Compact Handoff

## What this handoff is for
This handoff is for the **next step after compaction**: a cleanup/refactor pass on the mirrored Pi interactive UI work, with a new explicit requirement:

- extract the iOS dialog UI pieces from `PiSessionView.swift`
- put the extracted SwiftUI views in their own files under:
  - `pimux2000/Views/TUI/`

This pass should be a **cleanup and structure pass**, not a behavior redesign.

---

## Current working state
The mirrored extension-driven dialog flows are now implemented end-to-end for:

- `confirm`
- `select`
- `input`
- `editor`

### Cleanup progress completed in this pass
The cleanup/refactor pass has now started and these items are already done:

- extracted the iOS mirrored dialog views into:
  - `pimux2000/Views/TUI/SessionUIDialogOverlay.swift`
  - `pimux2000/Views/TUI/SessionUISelectorDialogContent.swift`
  - `pimux2000/Views/TUI/SessionUITextValueDialogContent.swift`
- removed the inline dialog overlay view/previews from `pimux2000/Views/PiSessionView.swift`
- kept session/network/dialog state orchestration in `PiSessionView.swift`
- added small shared helpers on `PimuxSessionUIDialogState` in `pimux2000/Models/PimuxServerClient.swift`:
  - `isSelectorDialog`
  - `isTextValueDialog`
  - `usesMultilineTextEditor`
  - `resolvedTextValue`
  - `settingSelectedIndex(...)`
  - `settingTextValue(...)`
- updated `PiSessionView.swift` to use the extracted overlay plus a safer `uiDialogTextBinding(...)` helper
- added a follow-up dialog state application fix in `PiSessionView.swift`:
  - incoming mirrored `uiDialogState` updates now preserve optimistic local text for the same active text dialog while a debounced sync or submit/cancel action is still in flight
  - this should reduce text snap-back / last-keystroke races for mirrored `input` and `editor`
- cleaned up `pimux-server/extensions/pimux-live.ts` with more shared dialog helpers for:
  - mirrored dialog activation/cleanup
  - TUI runtime configuration
  - shared submit/cancel behavior
  - shared dialog option typing
- reran validation successfully:
  - `cargo test --manifest-path pimux-server/Cargo.toml --quiet`
  - `xcodebuild -project pimux2000.xcodeproj -scheme pimux2000 -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

### Still worth doing next
- manually re-test all four debug dialog flows after the cleanup pass:
  - `/pimux-debug test-confirm`
  - `/pimux-debug test-select`
  - `/pimux-debug test-input`
  - `/pimux-debug test-editor`
- if needed, do one more small readability pass in `pimux-live.ts`
- optionally update this handoff again after manual verification

### Current debug commands
In Pi, after `/reload`, these should exist:

- `/pimux-debug test-confirm [prompt]`
- `/pimux-debug test-select [title]`
- `/pimux-debug test-input [placeholder]`
- `/pimux-debug test-editor [prefill]`

### Important runtime note
The live protocol version was bumped multiple times during this work and is now:

- `5`

So for real testing you usually need both:

1. restart `pimux-server`
2. run `/reload` in Pi

If that does not happen, the extension and server can be out of sync.

---

## What is implemented right now

### Extension / Pi side
In `pimux-server/extensions/pimux-live.ts`:

- `ctx.ui.confirm(...)` is wrapped and mirrored using Pi’s built-in `ExtensionSelectorComponent`
- `ctx.ui.select(...)` is wrapped and mirrored using Pi’s built-in `ExtensionSelectorComponent`
- `ctx.ui.input(...)` is wrapped and mirrored using Pi’s built-in `ExtensionInputComponent`
- `ctx.ui.editor(...)` is wrapped and mirrored using Pi’s built-in `ExtensionEditorComponent`
- semantic dialog state is mirrored to iOS
- remote iOS actions are sent back into the active Pi dialog

Important implementation detail preserved throughout:

- when instantiating Pi TUI components from the extension, call:
  - `setKeybindings(keybindings)`
  - `setKittyProtocolActive(tui.terminal.kittyProtocolActive)`

### Backend / protocol side
The server and agent path already support durable dialog state transport, reconnect, caching, and action dispatch.

The dialog state model now supports:

- kinds:
  - `confirm`
  - `select`
  - `input`
  - `editor`
- actions:
  - `move`
  - `selectIndex`
  - `setValue`
  - `submit`
  - `cancel`

### iOS side
In `pimux2000/Views/PiSessionView.swift`:

- a mirrored dialog overlay is rendered for all current dialog kinds
- selector-style dialogs render tappable options
- input dialogs render a `TextField`
- editor dialogs render a `TextEditor`
- input/editor text changes are locally reflected and debounced back to the server via `setValue`
- submit sends final `setValue` then `submit`
- cancel sends `cancel`

In `pimux2000/Models/PimuxServerClient.swift`:

- dialog decoding supports:
  - `placeholder`
  - `value`
- action encoding supports:
  - `.setValue(value:)`

---

## Validation status
These were run successfully after the current implementation:

- `cargo test --manifest-path pimux-server/Cargo.toml --quiet`
- `xcodebuild -project pimux2000.xcodeproj -scheme pimux2000 -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

If doing only cleanup/refactor, these should be rerun again before finishing.

---

## Files that matter most now

### TypeScript / extension
- `pimux-server/extensions/pimux-live.ts`

### Rust / backend protocol
- `pimux-server/src/transcript.rs`
- `pimux-server/src/agent/live.rs`
- `pimux-server/src/agent/mod.rs`
- `pimux-server/src/channel.rs`
- `pimux-server/src/server/mod.rs`

### Swift / iOS
- `pimux2000/Models/PimuxServerClient.swift`
- `pimux2000/Views/PiSessionView.swift`

---

## Main cleanup goal
Do a cleanup pass that improves structure and maintainability without changing the overall behavior.

There are two main cleanup buckets:

1. clean up `pimux-live.ts`
2. extract iOS dialog views into `pimux2000/Views/TUI/`

---

## Cleanup goal 1: refactor `pimux-live.ts`

### Why
`pimux-live.ts` now contains all four mirrored dialog flavors and a lot of shared logic. It works, but the code is starting to accumulate duplication and branching.

### What to improve
Refactor toward two conceptual dialog families:

#### A. Selector dialogs
- `confirm`
- `select`

Shared behavior:
- options array
- selected index
- `move`
- `selectIndex`
- `submit`
- `cancel`
- `ExtensionSelectorComponent`

#### B. Text-value dialogs
- `input`
- `editor`

Shared behavior:
- text value
- `setValue`
- `submit`
- `cancel`
- sync from TUI to iOS
- sync from iOS to TUI

### Suggested refactor shape
You do **not** need to invent a framework here. Just make the code easier to read.

Good possible structure:

- dialog kind/type guards near the top
- common helpers for:
  - send state
  - clear state
  - finish dialog
  - cancel dialog
- selector-only helpers:
  - selected-index mutation
  - selector attachment
  - selector submit resolution
- text-value-only helpers:
  - text mutation
  - input/editor attachment
  - text submit resolution
- separate wrapper installation blocks for:
  - `ui.select`
  - `ui.confirm`
  - `ui.input`
  - `ui.editor`

### Keep these behaviors unchanged
- one active mirrored dialog per session/runtime for now
- if a mirrored dialog is already active, fall back to the original Pi behavior
- reuse Pi’s real built-in components, not custom replacements
- continue to resync active dialog state on reconnect
- continue to clear state on session detach/switch/shutdown

### Important editor-specific note
For mirrored editor state reads from Pi’s editor component, the current code intentionally uses:

- `editor.getExpandedText?.() ?? editor.getText?.()`

That should be preserved unless there is a very good reason to change it.

---

## Cleanup goal 2: extract iOS dialog views into `pimux2000/Views/TUI/`

### New requirement from user
All extracted iOS views for this mirrored TUI/dialog work should go into their own files in:

- `pimux2000/Views/TUI/`

That directory does **not** currently exist, so create it.

### What should stay in `PiSessionView.swift`
Keep session state and transport logic in `PiSessionView.swift`, including:

- `currentUIDialog`
- `isUIDialogActionInFlight`
- `uiDialogActionError`
- debounced text syncing task
- stream handling
- functions that send actions to the server

### What should move out of `PiSessionView.swift`
Move view-only pieces into `pimux2000/Views/TUI/`.

Minimum extraction target:

1. `SessionUIDialogOverlay`

Recommended further split:

2. selector dialog content view
3. text-value dialog content view

### Suggested file layout
A reasonable target layout would be something like:

- `pimux2000/Views/TUI/SessionUIDialogOverlay.swift`
- `pimux2000/Views/TUI/SessionUISelectorDialogContent.swift`
- `pimux2000/Views/TUI/SessionUITextValueDialogContent.swift`

This is only a suggestion; naming can be adjusted if the local style suggests something cleaner.

### Recommended responsibilities

#### `SessionUIDialogOverlay.swift`
Own:
- outer card/container
- common title/message/error/loading UI
- branching between selector-style and text-value-style content

#### `SessionUISelectorDialogContent.swift`
Own:
- option list rendering
- selected styling
- cancel button row for selector dialogs

#### `SessionUITextValueDialogContent.swift`
Own:
- `TextField` for `input`
- `TextEditor` for `editor`
- submit/cancel buttons for text-value dialogs

### What not to move yet
Do **not** move network logic or session orchestration into separate view models.

The current Swift code can keep using local state in `PiSessionView`. This cleanup is about extracting UI structure, not adding abstraction layers.

---

## SwiftUI conventions to preserve
Per the Swift app conventions skill:

- do not introduce a new view model just to support these extracted views
- keep previews for all created/substantially modified SwiftUI views

So if you split views into `pimux2000/Views/TUI/`, add previews in those files.

Good previews to keep/add:

- confirm preview
- select preview
- input preview
- editor preview

---

## Specific iOS naming cleanup to consider
The current helper names in `PiSessionView.swift` are now slightly broader than their names suggest.

Current names:
- `updateUIDialogTextValue(_:)`
- `submitUIDialogTextValue()`

Those are already better than the older input-only names, so they may be fine as-is.

If you rename anything, prefer names that reflect shared text dialog behavior, not input-only behavior.

---

## Testing checklist after cleanup
After refactoring, verify all four flows manually.

### Confirm
- `/reload`
- `/pimux-debug test-confirm`
- verify TUI and iOS both show confirm
- act from either side
- ensure both resolve cleanly

### Select
- `/pimux-debug test-select`
- verify mirrored selector behavior
- pick option from iOS
- confirm Pi resolves with selected option

### Input
- `/pimux-debug test-input`
- verify typing in TUI updates iOS
- verify typing in iOS updates TUI
- submit from iOS and from TUI in separate runs

### Editor
- `/pimux-debug test-editor`
- verify multiline editing on both sides
- verify typing in TUI updates iOS
- verify typing in iOS updates TUI
- submit from iOS and from TUI in separate runs

### Reconnect sanity
At least once, verify dialog state still survives reconnect as expected:
- open a dialog
- reconnect/reload the stream path if practical
- confirm the active dialog snapshot is still delivered

### Build/test commands
Re-run:

- `cargo test --manifest-path pimux-server/Cargo.toml --quiet`
- `xcodebuild -project pimux2000.xcodeproj -scheme pimux2000 -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

---

## Important pitfalls / gotchas

### 1. Server restart + Pi reload
Because live protocol version is now `5`, stale runtime state is easy to confuse with code bugs.

If something appears to “do nothing”, first verify:
- server restarted
- Pi `/reload` run

### 2. Only one active mirrored dialog at a time
This is still the current design.

If a mirrored dialog is already active, wrappers intentionally fall back to original Pi behavior.

Do not accidentally remove that safeguard during cleanup.

### 3. Built-in Pi slash-command flows are still out of scope
This work is for extension-driven UI via `ctx.ui.*` wrappers.

Still not covered automatically:
- `/model`
- `/settings`
- `/resume`
- `/tree`
- other built-in core dialogs not exposed via extension wrapping

### 4. Do not reimplement Pi widgets
Keep reusing:
- `ExtensionSelectorComponent`
- `ExtensionInputComponent`
- `ExtensionEditorComponent`

The point of the architecture is to use Pi’s actual built-in TUI behavior and only mirror semantic state/actions to iOS.

### 5. Keep `slash-command.md` alone unless explicitly asked
That file is the standalone implementation plan from earlier work and should not be reused for temporary handoff notes.

This handoff is intentionally separate.

---

## Good next execution order after compaction
1. Read this file completely.
2. Inspect current `pimux-live.ts` and `PiSessionView.swift`.
3. Create `pimux2000/Views/TUI/`.
4. Extract SwiftUI dialog views into that directory first.
5. Ensure previews still exist and compile.
6. Then clean up `pimux-live.ts` structure.
7. Re-run Rust and Xcode validation.
8. Manually test all four debug commands.

---

## Desired outcome of the cleanup pass
By the end of the next pass:

- behavior should remain the same
- `pimux-live.ts` should be easier to follow and safer to extend
- `PiSessionView.swift` should be thinner
- extracted SwiftUI dialog views should live under:
  - `pimux2000/Views/TUI/`
- previews should exist for the extracted SwiftUI views
- all four mirrored dialog flows should still work:
  - confirm
  - select
  - input
  - editor
