# Plan: Reuse Pi's Built-in Interactive UI Components and Mirror Them to iOS

## Objective

Make extension-driven Pi UI appear in both:

- the local Pi TUI, using Pi's built-in components
- the iOS app, using native SwiftUI

Interactions should be reflected bidirectionally, without building a parallel Pimux-owned selector/input/editor implementation.

## Summary

The best path is:

1. wrap the shared `ctx.ui` methods used by extensions
2. for interactive dialogs, instantiate **Pi's own exported built-in dialog components** locally
3. mirror those components' semantic state over the Pimux live bridge
4. apply iOS-originated actions back into the same Pi component instance

This preserves Pi's real local behavior while avoiding a brittle reimplementation of selectors, text inputs, and editors.

## Key Findings from Pi Research

### 1. Interactive `ctx.ui` has no observable lifecycle hook

In interactive mode, Pi creates the extension UI API directly in:

- `dist/modes/interactive/interactive-mode.js`

`createExtensionUIContext()` wires methods like:

- `select`
- `confirm`
- `input`
- `editor`
- `notify`
- `setStatus`
- `setWorkingMessage`
- `setWidget`
- `setTitle`
- `setEditorText`

There is no built-in event stream for:

- dialog opened
- dialog state changed
- dialog resolved

So we cannot passively observe the internal live state of Pi's stock dialogs.

### 2. Pi exports the built-in extension dialog components

Pi's interactive extension dialogs are implemented as reusable exported classes:

- `ExtensionSelectorComponent`
- `ExtensionInputComponent`
- `ExtensionEditorComponent`

Relevant implementation files:

- `dist/modes/interactive/components/extension-selector.js`
- `dist/modes/interactive/components/extension-input.js`
- `dist/modes/interactive/components/extension-editor.js`

This is the key enabling fact: we can reuse Pi's real dialog components from an extension.

### 3. Those dialog components already use Pi's real editing/input primitives

Under the hood:

- `ExtensionInputComponent` uses `Input`
- `ExtensionEditorComponent` uses `Editor`

So Pi's own logic remains responsible for:

- key handling
- cursor movement
- paste handling
- undo
- IME support
- multiline editing behavior

### 4. `confirm` is just a selector

Pi's confirm flow is selector-based, effectively a list with:

- combined title/message text
- options `Yes` and `No`

So `confirm` can reuse the same mirrored machinery as `select`.

### 5. Pi also exports reusable built-in selectors for future work

Pi exports other interactive components too, including:

- `ModelSelectorComponent`
- `SettingsSelectorComponent`
- `SessionSelectorComponent`
- `TreeSelectorComponent`

This does not automatically give us hooks into built-in slash commands, but it means future work on `/model`, `/settings`, `/resume`, and `/tree` can likely reuse Pi's own components locally.

### 6. Two TUI globals must be synchronized when constructing Pi components from an extension

When instantiating Pi's built-in components from extension code, we should synchronize:

- keybindings via `setKeybindings(keybindings)`
- Kitty keyboard protocol state via `setKittyProtocolActive(tui.terminal.kittyProtocolActive)`

Theme handling appears safe because Pi's interactive theme is shared via a global proxy.

## Architectural Conclusion

We should **not**:

- build a parallel Pimux selector/input/editor library
- try to intercept the exact internal instances created by Pi's stock `ctx.ui.select()` implementation

We **should**:

- wrap the shared `ctx.ui` methods
- use `ctx.ui.custom()` for dialog presentation
- instantiate Pi's exported built-in components ourselves
- keep a reference to the live component instance
- mirror its semantic state to iOS
- apply iOS actions back into that same instance

This is a thin instrumentation layer around Pi's own built-in UI classes.

## Scope

### In Scope

Interactive extension UI methods:

- `select`
- `confirm`
- `input`
- `editor`

Fire-and-forget semantic UI methods:

- `notify`
- `setStatus`
- `setTitle`
- `setEditorText`
- `setWorkingMessage`
- `setHiddenThinkingLabel`
- `setWidget` for `string[]` widgets

### Out of Scope for Phase 1

- `custom()` for arbitrary component trees
- `setFooter()`
- `setHeader()`
- `setEditorComponent()`
- `onTerminalInput()`
- widget factory functions returning arbitrary components
- theme switching and other TUI-only features

### Not Solved by This Plan

This plan does not automatically mirror Pi's own internal built-in interactive commands such as:

- `/model`
- `/settings`
- `/resume`
- `/tree`

Those need separate work:

- explicit redirection into Pimux-managed flows, or
- upstream Pi changes, or
- a later reuse layer around those exported built-in components

## Live Bridge Protocol Additions

Add a UI-specific message family to the live bridge.

### Pi/extension -> server/iOS

- `uiOpen`
- `uiState`
- `uiResolved`
- `uiClosed`

### server/iOS -> Pi/extension

- `uiAction`

### Required fields

Each UI message should include at least:

- `sessionId`
- `uiSessionId`
- `kind` (`select`, `confirm`, `input`, `editor`)
- `revision`

### Intended semantics

- `uiOpen`: create or rehydrate native UI for a dialog
- `uiState`: update the current mirrored state
- `uiAction`: apply user interaction from iOS to the live Pi component
- `uiResolved`: final accepted/cancelled result
- `uiClosed`: clear stale UI on dismiss/session switch/shutdown

## Implementation Plan

### Step 1: Patch the shared extension UI context in `pimux-live.ts`

Early in session startup:

- capture original `ctx.ui` methods
- replace selected methods with wrapped versions
- leave unsupported methods alone

Behavior split:

- dialog methods (`select`, `confirm`, `input`, `editor`) go through mirrored wrappers
- fire-and-forget methods tee to both local Pi behavior and the live bridge

### Step 2: Implement mirrored `select` using `ExtensionSelectorComponent`

Wrapper behavior:

- call `ctx.ui.custom(...)`
- synchronize keybindings + Kitty protocol state
- construct `ExtensionSelectorComponent`
- keep a reference to the component instance
- send `uiOpen`
- emit `uiState` after local or remote changes
- resolve when selection/cancel occurs

Remote iOS actions should be semantic, for example:

- move up
- move down
- confirm current selection
- cancel

### Step 3: Implement mirrored `confirm` as a specialization of `select`

Reuse the selector machinery with:

- title + message composed into the visible selector title
- options `Yes` and `No`

### Step 4: Implement mirrored `input` using `ExtensionInputComponent`

Wrapper behavior:

- construct `ExtensionInputComponent`
- mirror at least:
  - current text
  - cursor position
  - title / placeholder / timeout metadata
- resolve on submit/cancel

Remote action candidates:

- insert text
- backspace
- move cursor left/right
- submit
- cancel

### Step 5: Implement mirrored `editor` using `ExtensionEditorComponent`

Wrapper behavior:

- construct `ExtensionEditorComponent`
- mirror at least:
  - current full text
  - cursor location
  - title / timeout metadata
  - external-editor availability metadata if useful
- use the underlying `Editor` accessors and callbacks such as:
  - `getText()`
  - `getCursor()`
  - `onChange`
  - `onSubmit`

### Step 6: Tee the fire-and-forget `ctx.ui` methods

Keep Pi's local behavior and also bridge updates to iOS for:

- `notify`
- `setStatus`
- `setTitle`
- `setEditorText`
- `setWorkingMessage`
- `setHiddenThinkingLabel`
- `setWidget(string[])`

Phase 1 should bridge only string-array widgets.

### Step 7: Implement iOS-side mirrored dialog handling

On iOS:

- render native SwiftUI equivalents for `select`, `confirm`, `input`, and `editor`
- key state by `sessionId + uiSessionId`
- send semantic `uiAction` messages back to the live bridge
- update native UI from incoming `uiState`
- dismiss on `uiResolved` or `uiClosed`

### Step 8: Handle reconnect and resolution policy

Phase 1 assumptions:

- at most one active mirrored modal dialog per Pi session
- first submit/cancel wins
- later actions on a resolved dialog are ignored
- reconnect should trigger resend of the active dialog state so iOS can rehydrate it

## Important Constraint

We should not try to intercept the exact internal instances created by Pi's stock `ctx.ui.select()` / `input()` / `editor()` implementations.

Why:

- interactive mode constructs them internally
- there is no callback exposing them
- there is no built-in live-state event stream

So the robust approach is:

- wrap the methods
- instantiate Pi's exported built-in dialog classes ourselves
- present them through `ctx.ui.custom()`
- instrument those instances for mirroring

## Why This Approach Is Less Brittle

This avoids reimplementing:

- selector navigation behavior
- text input behavior
- multiline editing behavior
- IME handling
- paste/undo/cursor logic
- terminal keybinding interpretation

Pimux only adds:

- method wrapping
- bridge protocol messages
- state snapshots
- remote action application

That is a much smaller maintenance surface than building a second component library.

## Open Questions

### 1. Remote action granularity for `input` / `editor`

We need to validate whether the cleanest remote control model is:

- semantic editing operations, or
- feeding Pi-compatible key/input sequences into the same component instance

### 2. Built-in slash command parity

Later, if we want parity for `/model`, `/settings`, `/resume`, and `/tree`, we need a separate plan for how Pimux becomes involved in those core flows.

### 3. Multi-client conflict policy

For phase 1, keep this simple:

- one dialog per session
- latest state update wins while open
- first terminal resolution wins when submitting/cancelling

## Recommended Order of Work

1. Add live bridge protocol support for mirrored extension UI dialogs
2. Wrap `select` and `confirm` using `ExtensionSelectorComponent`
3. Wrap `input` using `ExtensionInputComponent`
4. Wrap `editor` using `ExtensionEditorComponent`
5. Tee `notify`, `setStatus`, `setTitle`, and `setEditorText`
6. Add `setWorkingMessage`, `setHiddenThinkingLabel`, and string-array `setWidget`
7. Reevaluate built-in slash-command flows separately

## Success Criteria

This plan is successful when:

- an extension calling `ctx.ui.select()` shows Pi's built-in selector in the TUI and a native mirrored selector in iOS
- changes in either TUI or iOS are reflected in the other while the dialog is open
- submit/cancel from either side resolves the same pending Pi promise
- `ctx.ui.input()` and `ctx.ui.editor()` reuse Pi's built-in `Input`/`Editor` behavior locally while reflecting live text state to iOS
- fire-and-forget `ctx.ui` methods visibly affect both TUI and iOS
- no parallel Pimux-owned selector/input/editor implementation is required
