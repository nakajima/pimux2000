# Slash Command Review: pi TUI vs. pimux iOS

## Purpose

This document reviews how slash commands work in the pi TUI, compares that to how they are exposed and submitted from the pimux iOS app, and identifies all major discrepancies.

The goal is to answer a simple question:

> When the iOS app shows a slash command, does it behave the way a user would expect based on the pi TUI?

At the moment, the answer is largely **no**.

---

## Executive Summary

The pi TUI does **not** treat all slash commands the same way.

There are four distinct categories:

1. **Built-in interactive commands** handled directly by the TUI layer
   - Examples: `/settings`, `/model`, `/compact`, `/new`, `/resume`, `/copy`
2. **Extension commands** registered via `pi.registerCommand()`
3. **Prompt templates** expanded from Markdown files
4. **Skill commands** expanded from `/skill:name`

The iOS app currently flattens these into a single suggestion menu and then submits the selected text as a raw message body.

That causes multiple problems:

- **Built-in interactive commands are shown in iOS but are not actually executable there**
- **Extension commands are discoverable in iOS but do not execute in the live session path**
- **Prompt templates and skill commands are discoverable in iOS but do not expand in the live session path**
- **Argument completion and command provenance are lost**
- **Busy-session behavior differs from the TUI**

The core mismatch is architectural:

- In the TUI, slash commands are partly a **UI/runtime feature** and partly a **prompt expansion feature**
- In iOS, slash commands are currently treated as a **text autocomplete feature** with raw message submission

This same architectural mismatch also explains why `!` and `!!` do not behave like the TUI.

---

## Scope and Sources Reviewed

### pi runtime / docs

- `/Users/nakajima/.bun/install/global/node_modules/@mariozechner/pi-coding-agent/README.md`
- `/Users/nakajima/.bun/install/global/node_modules/@mariozechner/pi-coding-agent/docs/extensions.md`
- `/Users/nakajima/.bun/install/global/node_modules/@mariozechner/pi-coding-agent/docs/skills.md`
- `/Users/nakajima/.bun/install/global/node_modules/@mariozechner/pi-coding-agent/docs/prompt-templates.md`
- `/Users/nakajima/.bun/install/global/node_modules/@mariozechner/pi-coding-agent/docs/keybindings.md`
- `/Users/nakajima/.bun/install/global/node_modules/@mariozechner/pi-coding-agent/dist/core/slash-commands.js`
- `/Users/nakajima/.bun/install/global/node_modules/@mariozechner/pi-coding-agent/dist/core/agent-session.js`
- `/Users/nakajima/.bun/install/global/node_modules/@mariozechner/pi-coding-agent/dist/core/extensions/runner.js`
- `/Users/nakajima/.bun/install/global/node_modules/@mariozechner/pi-coding-agent/dist/modes/interactive/interactive-mode.js`
- `/Users/nakajima/.bun/install/global/node_modules/@mariozechner/pi-coding-agent/dist/core/bash-executor.js`

### pimux / iOS app / server

- `pimux2000/Views/MessageComposerView.swift`
- `pimux2000/Views/PiSessionView.swift`
- `pimux2000/Models/SlashCommand.swift`
- `pimux2000/Models/PimuxServerClient.swift`
- `pimux-server/extensions/pimux-live.ts`
- `pimux-server/src/agent/mod.rs`
- `pimux-server/src/agent/send.rs`
- `pimux-server/src/agent/live.rs`
- `pimux-server/src/server/mod.rs`

---

## How Slash Commands Work in the pi TUI

## 1. There are four different command classes

### 1.1 Built-in interactive commands

These are defined in `dist/core/slash-commands.js` and include:

- `/settings`
- `/model`
- `/scoped-models`
- `/export`
- `/import`
- `/share`
- `/copy`
- `/name`
- `/session`
- `/changelog`
- `/hotkeys`
- `/fork`
- `/tree`
- `/login`
- `/logout`
- `/new`
- `/compact`
- `/resume`
- `/reload`
- `/quit`

These are **interactive-mode commands**, not generic prompt text.

In `dist/modes/interactive/interactive-mode.js`, the editor submit handler explicitly checks these commands before normal prompt submission. For example:

- `/settings` opens settings UI
- `/model` opens model selector UI
- `/new` starts a new session
- `/compact` triggers compaction
- `/copy` copies the last assistant message
- `/quit` shuts down pi

These are handled by the TUI itself and are **not sent as user messages**.

### 1.2 Extension commands

Extensions can register commands with `pi.registerCommand()`.

These are handled in `AgentSession.prompt()` by `_tryExecuteExtensionCommand()` **before** normal prompt processing.

Important properties:

- They execute immediately
- They can execute even while the agent is streaming
- If multiple extensions register the same command name, invocation names are suffixed like `/review:1`, `/review:2`
- They can expose argument completions via `getArgumentCompletions()`

### 1.3 Prompt templates

Prompt templates are file-backed commands like `/review`.

In `AgentSession.prompt()`, prompt templates are expanded before the user message is sent to the model.

So `/review foo` is not treated as literal user text; it becomes expanded prompt content.

### 1.4 Skill commands

Skills are invoked as `/skill:name`.

In `AgentSession.prompt()`, these are expanded into a `<skill ...>` block plus arguments.

Again, the literal `/skill:name` text is not what reaches the model.

---

## 2. TUI command processing order

When the user presses Enter in the TUI editor, the flow is roughly:

1. Check built-in interactive commands in `InteractiveMode`
2. Check `!` / `!!` bash handling in `InteractiveMode`
3. If no TUI-local action matched, call `session.prompt(...)`
4. Inside `AgentSession.prompt()`:
   1. try extension commands
   2. emit `input` event to extensions
   3. expand skill commands
   4. expand prompt templates
   5. submit or queue the resulting user message

This matters because “slash command support” in pi is split across two layers:

- **interactive UI/runtime layer**
- **prompt pipeline layer**

The TUI feels coherent because both layers are present.

---

## 3. TUI autocomplete behavior

The TUI autocomplete is not just a flat command name list.

In `InteractiveMode.setupAutocomplete()` it builds suggestions from:

- built-in interactive commands
- prompt templates
- extension commands
- skill commands, if skill commands are enabled

It also adds extra behavior:

- `/model` provides argument completion from available models
- extension commands may provide argument completions
- autocomplete descriptions are annotated with source/scope information
- skill command visibility depends on settings (`enableSkillCommands`)
- built-in conflicts are diagnosed separately

The docs for `pi.getCommands()` are explicit about an important detail:

> Built-in interactive commands are not included there, because they are handled only in interactive mode and would not execute if sent via prompt.

That is the canonical distinction.

---

## How Slash Commands Are Implemented in pimux iOS

## 4. iOS composer behavior

In `pimux2000/Views/MessageComposerView.swift` and `pimux2000/Models/SlashCommand.swift`, the app:

- defines a local hardcoded list of built-in commands
- fetches extra commands from `/sessions/{id}/commands`
- merges those two lists for the slash menu

Matching behavior is intentionally limited:

- slash suggestions only appear if the entire trimmed editor contents are a slash-prefix
- if the text contains a space after the slash command, matching stops

So iOS currently supports:

- **name completion only**

It does **not** support:

- argument completion
- source-specific display details beyond a simple `source` string
- post-command completions like `/model cla...`

---

## 5. iOS message submission behavior

In `pimux2000/Views/PiSessionView.swift`, sending a message simply POSTs the raw body through `PimuxServerClient.sendMessage()`.

There is no client-side slash command execution path.

There is no client-side built-in command router.

There is no client-side `!` / `!!` router.

So once the user presses send, the iOS app is relying entirely on the server and remote pi runtime to interpret the raw text.

---

## 6. How pimux command discovery works

The iOS app fetches commands from:

- `GET /sessions/{id}/commands`

On the server side, that route eventually asks the live pi runtime for commands.

In `pimux-server/extensions/pimux-live.ts`, the live extension answers `getCommands` by calling:

- `pi.getCommands()`

That list includes:

- extension commands
- prompt templates
- skill commands

It does **not** include built-in interactive commands.

The iOS app compensates for that by maintaining its own hardcoded built-in command list and merging it locally.

---

## 7. How pimux submits input in the live path

The live extension receives `sendUserMessage` requests and does this:

- if idle: `pi.sendUserMessage(content)`
- if busy: `pi.sendUserMessage(content, { deliverAs: "followUp" })`

This is the most important implementation detail in the whole review.

In pi, `sendUserMessage()` calls `AgentSession.prompt()` with:

- `expandPromptTemplates: false`
- `source: "extension"`

That means the live path **intentionally bypasses**:

- extension command execution
- skill expansion
- prompt-template expansion

So in the live path, slash-prefixed input is mostly treated as literal user text.

The `input` extension event still runs, but it runs with `source: "extension"`, and the built-in slash-command machinery described above is skipped.

---

## 8. How pimux submits input in the headless fallback path

If no live extension is attached, the server falls back to launching a headless pi RPC process.

That process is started with:

- `pi --mode rpc --session ... --no-extensions`

Then pimux sends an RPC `prompt` command with the raw text.

Effects of this path:

- **built-in interactive commands still do not work**
  - because those only exist in the TUI interactive layer
- **extension commands do not work**
  - because extensions are disabled with `--no-extensions`
- **prompt templates likely do work**
  - because `session.prompt()` is used normally
- **skill commands likely do work**
  - because `session.prompt()` expands `/skill:name`

So the fallback path supports a different subset of slash semantics than the live path.

---

## Discrepancies

## 9. Built-in interactive commands are shown in iOS but are not actually executable

### What the TUI does

Built-ins like `/settings`, `/model`, `/compact`, `/new`, `/resume`, and `/copy` are handled directly by `InteractiveMode`.

### What iOS does

The iOS app hardcodes these into `SlashCommand.builtinCommands` and shows them in the menu.

But sending `/settings` or `/model` from iOS only submits a raw message body. There is no equivalent iOS command handler, and neither the live nor headless server path maps that raw text back to TUI-only behavior.

### Result

These commands are **advertised but non-functional** in iOS.

This is the most visible mismatch.

---

## 10. Extension commands are discoverable in iOS but do not execute in the live path

### What the TUI does

Extension commands run through `_tryExecuteExtensionCommand()` inside `AgentSession.prompt()`.

### What iOS does

The iOS app fetches extension commands via `/sessions/{id}/commands` and shows them in its slash menu.

But live submission goes through `pi.sendUserMessage(...)`, which uses `expandPromptTemplates: false` and therefore skips extension command execution.

### Result

A custom command can appear in the iOS menu and still be treated as plain user text when submitted.

---

## 11. Prompt templates are discoverable in iOS but do not expand in the live path

### What the TUI does

Prompt templates are expanded in `AgentSession.prompt()` before the message reaches the model.

### What iOS does

The live bridge exposes prompt-template commands through `pi.getCommands()`, so they can appear in the iOS menu.

But live submission uses `pi.sendUserMessage(...)`, which disables prompt-template expansion.

### Result

A prompt template can appear selectable in iOS and still fail to expand when sent through the live path.

---

## 12. Skill commands are discoverable in iOS but do not expand in the live path

### What the TUI does

`/skill:name` expands to full skill content in `AgentSession.prompt()`.

### What iOS does

The live bridge exposes skills through `pi.getCommands()`.

But live submission uses `pi.sendUserMessage(...)`, which disables skill expansion.

### Result

A skill can appear selectable in iOS and still be sent as literal text rather than expanded skill content.

---

## 13. Live mode and fallback mode support different slash-command subsets

### Live mode

- built-ins: no
- extension commands: no
- prompt templates: no
- skills: no
- command discovery: yes, via live bridge

### Headless fallback mode

- built-ins: no
- extension commands: no, because `--no-extensions`
- prompt templates: yes, likely
- skills: yes, likely
- command discovery: weak or unavailable, because `/commands` depends on the live connection path

### Result

The set of commands that are *discoverable* is not the same as the set that is *executable*, and the executable subset changes depending on whether the live bridge is attached.

---

## 14. iOS does not support argument completion

### What the TUI does

The TUI supports richer completion behavior, including:

- `/model` model completions
- extension-provided argument completions
- slash command autocomplete after command name entry begins

### What iOS does

`MessageComposerView` only matches commands when the text is a slash-prefix with no spaces.

### Result

The iOS menu only supports command-name completion, not command-argument completion.

Examples:

- `/model cla...` can be guided in the TUI
- `/model cla...` gets no help in iOS

---

## 15. Command provenance is lost in iOS

### What the TUI does

The TUI annotates commands with source/scope information in autocomplete, including:

- user vs project scope
- package/git provenance
- source path metadata

### What iOS does

The pimux bridge reduces command metadata to:

- `name`
- `description`
- `source`

The app stores that in `PimuxSessionCommand` and then in `SlashCommand`.

### Result

The iOS app loses important context about where a command came from and how trustworthy or local it is.

---

## 16. Busy-session semantics differ from the TUI

### What the TUI does

Built-in interactive commands are handled immediately in the TUI. Extension commands can also execute immediately during streaming. Prompt/template expansion happens before queueing.

### What iOS does

When the live bridge sees the agent is busy, it queues user input as a follow-up via:

- `pi.sendUserMessage(content, { deliverAs: "followUp" })`

So slash-prefixed input is treated as ordinary queued user text.

### Result

Even if slash commands were conceptually valid, they currently lose their immediate control-surface semantics in the iOS live path.

---

## 17. Built-in command definitions are duplicated and can drift

The iOS app hardcodes a built-in command list in `pimux2000/Models/SlashCommand.swift`.

pi defines its built-ins in `dist/core/slash-commands.js`.

These lists are already only approximately aligned. Descriptions differ, and future command additions/removals may drift further.

### Result

The iOS app can show commands or descriptions that no longer match current pi behavior.

---

## 18. Skill visibility rules differ

### What the TUI does

Skill commands are only added to autocomplete if `enableSkillCommands` is enabled.

### What the bridge does

`pi.getCommands()` includes skills directly.

### What iOS does

The iOS app shows whatever the bridge returns.

### Result

The iOS app may show skill commands in situations where the TUI would currently hide them.

---

## 19. Built-in name conflicts are handled differently

In the TUI, extension commands that conflict with built-in interactive commands are diagnosed specially in autocomplete.

The iOS app locally merges built-ins and fetched commands, but it filters custom commands using the locally hardcoded built-in names.

### Result

Conflict handling is not faithfully modeled in iOS. The app does not replicate the TUI’s full conflict-resolution and diagnostics behavior.

---

## Root Cause

The root cause is not one bug. It is a modeling error.

The current iOS implementation assumes slash commands are:

- a single list of names
- that can be shown in a menu
- and then sent as raw text to the server

But in pi, slash commands are actually split across two different systems:

### A. Interactive UI/runtime commands

Handled only by the TUI layer:

- `/settings`
- `/model`
- `/compact`
- `/new`
- `/resume`
- etc.

### B. Prompt-pipeline commands

Handled inside `AgentSession.prompt()`:

- extension commands
- prompt templates
- skill commands

The iOS app currently models all of them as if they belonged to category B, while the live server path actually bypasses category B behavior for slash-prefixed input.

So the system is mismatched in both directions:

- it advertises commands that depend on the TUI layer
- and it fails to execute prompt-pipeline commands in the live path

---

## Consequences for Users

From a user’s perspective, the current slash-command experience in iOS is misleading.

### What users are likely to expect

If a command appears in the slash menu, they will expect one of two things:

1. it executes like the TUI version
2. or it is hidden if unsupported

### What actually happens

Many commands are visible but not honest:

- visible but not executable
- visible but only executable in one transport mode
- visible but missing completion/help behavior
- visible but missing expansion semantics

That creates a poor trust model for the composer.

---

## Comparison Matrix

| Command type | TUI discoverable | TUI executable | iOS discoverable | iOS live executable | iOS headless executable |
|---|---:|---:|---:|---:|---:|
| Built-in interactive commands | Yes | Yes | Yes | No | No |
| Extension commands | Yes | Yes | Yes | No | No |
| Prompt templates | Yes | Yes | Yes | No | Likely yes |
| Skill commands | Yes* | Yes | Yes | No | Likely yes |

\* In TUI autocomplete, skill commands depend on the skill-command setting.

---

## Why This Also Explains `!` and `!!`

The same structural issue exists for user bash commands.

In the TUI:

- `!command` and `!!command` are intercepted by `InteractiveMode`
- bash runs through the user-bash execution path
- results are recorded as `bashExecution` session messages

In iOS:

- no local interception exists
- the input is just sent as text through the message path

So the slash-command review and the `!` / `!!` issue are two manifestations of the same underlying mismatch:

> The iOS app currently mirrors the TUI’s **editor menu surface**, but not the TUI’s **input execution model**.

---

## High-Level Remediation Directions

This document is primarily descriptive, but the discrepancies suggest a few clear directions.

### Option 1: Make the iOS UI honest

Only show commands that are actually executable over the current transport.

That would mean:

- do **not** show built-in interactive commands unless the app can execute them
- do **not** show templates/skills/extension commands if the current send path cannot invoke them correctly

This is the lowest-risk short-term fix.

### Option 2: Add real slash-command parity

Create a submission path that preserves pi’s prompt pipeline semantics for raw editor input.

That would require a way for the live path to submit input through something equivalent to `session.prompt(...)` with normal expansion/command handling, instead of `pi.sendUserMessage(...)` with `expandPromptTemplates: false`.

Without that, live mode will continue to bypass:

- extension commands
- prompt templates
- skill expansion

### Option 3: Implement built-in commands explicitly for iOS

Built-in interactive commands are TUI-specific today. To make them work from iOS, they would need explicit equivalents, for example via:

- dedicated server endpoints
- explicit RPC commands
- or dedicated app/server command handlers

Examples:

- `/model` could map to a server-side model selector API or app-side model UI
- `/settings` could map to app settings UI
- `/compact` could map to a compaction endpoint
- `/copy` could map to app-local clipboard behavior

### Option 4: Stop duplicating built-ins locally

The current hardcoded built-in list in `SlashCommand.swift` is a maintenance hazard.

Either:

- remove unsupported built-ins from the iOS surface entirely
- or replace the duplication with an explicit compatibility layer whose behavior is actually implemented

---

## UI Primitives Review: Can pi’s UI Be Reused in iOS?

This is the natural next question.

If pi already has selectors, dialogs, editors, and other UI primitives, can the iOS app adapt those instead of re-implementing them?

### Short answer

**Not directly.**

pi does have reusable UI abstractions, but most of them are reusable only **within terminal-based JavaScript runtimes**, not across to SwiftUI on iOS.

However, there is an important distinction:

- pi’s **terminal rendering components** are not directly portable to iOS
- pi’s **semantic UI protocol** is portable enough to be a good integration target

That means the likely direction is:

> **reuse pi’s UI semantics and protocol, not pi’s terminal widgets themselves**

---

## 20. pi has three different UI layers

### 20.1 Terminal component layer (`@mariozechner/pi-tui`)

This is the lowest-level UI system used by the TUI.

Per `docs/tui.md`, components implement an interface like:

- `render(width): string[]`
- `handleInput(data)`
- `invalidate()`
- optional focus handling

This is a terminal-native rendering model:

- output is arrays of strings
- strings contain ANSI styling
- input is raw terminal key data
- cursor positioning uses terminal-specific mechanisms
- IME support uses cursor markers embedded in rendered terminal output

This is not a generic cross-platform widget system.

It is a terminal UI toolkit.

### 20.2 Higher-level pi interactive components

pi exports higher-level components such as:

- `ModelSelectorComponent`
- `SettingsSelectorComponent`
- `SessionSelectorComponent`
- `TreeSelectorComponent`
- `CustomEditor`
- `ExtensionInputComponent`
- `ExtensionSelectorComponent`
- `FooterComponent`
- `ToolExecutionComponent`
- `AssistantMessageComponent`

These sound promising at first, but they are still built on top of `@mariozechner/pi-tui` primitives like:

- `Container`
- `Text`
- `Input`
- `SelectList`
- `SettingsList`
- terminal theme helpers
- raw keybinding matching

So these are not platform-neutral view models. They are terminal view implementations.

### 20.3 Semantic UI API / RPC UI protocol

Separately, pi exposes semantic UI operations through `ctx.ui`, such as:

- `select()`
- `confirm()`
- `input()`
- `editor()`
- `notify()`
- `setStatus()`
- `setWidget()`
- `setTitle()`
- `setEditorText()`

In RPC mode, these are translated into an **extension UI sub-protocol** documented in `docs/rpc.md`.

That protocol is much closer to something an iOS app can consume.

---

## 21. Why the terminal components are not directly portable

The concrete component implementations confirm that the exported UI primitives are deeply terminal-specific.

### 21.1 `CustomEditor`

`CustomEditor` extends `Editor` from `@mariozechner/pi-tui`.

It handles:

- raw keybinding matching
- terminal editor actions
- autocomplete visibility rules
- terminal paste-image bindings
- escape / ctrl+d behavior

This is editor behavior in a terminal, not a reusable text-editing abstraction for SwiftUI.

### 21.2 `ModelSelectorComponent`

`ModelSelectorComponent` is built from:

- `Container`
- `Input`
- `Text`
- `Spacer`
- `DynamicBorder`
- ANSI-colored theme text
- keyboard-driven selection behavior

Its rendering logic literally builds terminal strings and list rows.

That is useful as a reference for interaction design, but not as a drop-in UI primitive for iOS.

### 21.3 `SettingsSelectorComponent`

`SettingsSelectorComponent` is a TUI composition of:

- `SettingsList`
- `SelectList`
- bordered containers
- terminal capabilities checks
- text-based submenu rendering

Again, it is not a platform-neutral settings schema plus renderer. It is already-rendered terminal UI composition.

### 21.4 `ExtensionInputComponent`

Even a simple extension input dialog is implemented in terms of:

- terminal input widgets
- terminal keybindings
- terminal focus propagation
- terminal countdown display
- bordered text rendering

So even the simplest dialog components are tightly coupled to the TUI stack.

---

## 22. Evidence from pi’s own RPC example

The strongest evidence is pi’s own example:

- `examples/rpc-extension-ui.ts`

That example does **not** try to reuse pi’s built-in interactive components over RPC.
Instead, it builds a separate client UI and reacts to semantic requests like:

- `select`
- `confirm`
- `input`
- `editor`
- `notify`
- `setStatus`
- `setWidget`
- `set_editor_text`

That is an important design signal from pi itself:

> When pi is used outside the TUI, the intended portability boundary is the **RPC/UI protocol**, not the terminal components.

---

## 23. What *is* portable enough to target from iOS

Even though the terminal widgets are not directly reusable, several pieces are reusable at the semantic level.

### 23.1 Dialog semantics

The following extension UI requests map cleanly to native iOS concepts:

- `select` → sheet / picker / list selection view
- `confirm` → alert / confirmation dialog
- `input` → text-entry dialog
- `editor` → multi-line editor flow
- `notify` → banner / toast / inline status
- `setStatus` → footer / toolbar / session status row
- `setWidget` → pinned panels above/below composer
- `setEditorText` → prefill composer text

This is much more promising than trying to run terminal components in SwiftUI.

### 23.2 Behavioral contracts

The docs around these primitives give useful behavioral contracts the iOS app could mirror:

- which UI is blocking vs fire-and-forget
- how cancellation works
- how timeouts should resolve
- which data a client must send back
- how selection / confirmation / editing fit into agent control flow

### 23.3 Data/config shapes

Some higher-level components also expose useful data shapes that could inspire native implementations.

For example:

- settings are represented as labeled items with current values and allowed values
- selectors are represented as options plus callbacks
- model selectors distinguish filtered items, current selection, current model, and scope

The SwiftUI app could mirror those structures without trying to reuse the actual terminal rendering classes.

---

## 24. What is *not* portable today

### 24.1 Arbitrary custom TUI components

The RPC docs explicitly state that in RPC mode:

- `custom()` returns `undefined`

That means fully arbitrary TUI component trees are **not transported** over RPC.

So even if an extension uses rich custom terminal UI in the TUI, that does not currently become a cross-platform UI description the iOS app could render.

### 24.2 Full editor replacement

TUI-specific methods like custom editor component replacement are not meaningfully portable to RPC clients today.

### 24.3 ANSI/theming/rendering logic

pi themes are terminal themes. They color strings and affect line-oriented rendering.

They are not directly reusable as SwiftUI view styling primitives.

### 24.4 Focus/cursor mechanics

The TUI focus model depends on terminal cursor placement and keyboard event routing. That does not map cleanly onto UIKit/SwiftUI text and focus APIs.

---

## 25. Practical implication for pimux

If the goal is to accelerate iOS feature parity, the right reuse boundary is probably:

### Reuse these

- command semantics
- RPC UI request/response protocol
- selector/dialog behavior contracts
- shared command metadata and data models where possible

### Do not try to directly reuse these

- `@mariozechner/pi-tui` components
- exported terminal components like `ModelSelectorComponent` or `SettingsSelectorComponent`
- ANSI renderers
- raw keybinding-driven view logic

In other words:

> The iOS app should probably build **native SwiftUI counterparts** to pi’s dialogs and selectors, not try to embed pi’s terminal widgets.

---

## 26. Relevance to slash commands specifically

This matters for slash-command parity in two ways.

### 26.1 Built-in slash commands often want UI, not just message submission

Commands like:

- `/model`
- `/settings`
- `/resume`
- `/tree`

are really invitations to open UI flows.

That means native iOS implementations are likely appropriate anyway.

Trying to “reuse” the TUI components directly is probably the wrong target.

### 26.2 Extension UI protocol is a better long-term integration surface

If the iOS app eventually wants to support more of pi’s interactive behaviors, the extension UI protocol suggests a path where the app can act as a general-purpose UI client for semantic requests.

That could be valuable beyond slash commands.

For example, it could eventually support:

- extension confirmations
- extension input prompts
- editor-prefill requests
- pinned widgets/status displays

without needing to port the terminal renderer.

---

## 27. Updated conclusion on UI primitive reuse

The answer to:

> “Can we adapt pi’s UI primitives to our iOS app and then just use them?”

is:

### Not literally

The exported pi UI primitives are mostly terminal rendering classes, not portable cross-platform widgets.

### But partially, at the semantic layer

The extension UI API and RPC UI sub-protocol are promising portability points.

So the better framing is probably:

> **Can we adapt pi’s UI protocol and interaction contracts to iOS, then implement native SwiftUI views for them?**

That feels realistic.

> **Can we directly reuse pi’s terminal components in iOS?**

That does not feel realistic without an awkward and high-maintenance compatibility layer.

---

## 28. Semantic UI as the actual integration boundary

If we care about bringing more real pi behavior to iOS, the semantic UI layer is the most promising shared boundary.

Concretely, the RPC UI protocol gives us a portable vocabulary of user interactions:

### 28.1 Dialog requests

These are blocking interactions that expect a response from the client:

- `select`
- `confirm`
- `input`
- `editor`

These map well to native SwiftUI concepts and are already defined with stable request/response shapes.

### 28.2 Fire-and-forget UI signals

These do not expect a response:

- `notify`
- `setStatus`
- `setWidget`
- `setTitle`
- `set_editor_text`

These are useful because they let pi or extensions influence the surrounding app UI without requiring the app to understand terminal rendering.

### 28.3 Explicitly unsupported in RPC

RPC mode also clearly tells us what is **not** currently portable:

- `custom()`
- custom editor components
- custom footer/header factories
- arbitrary TUI component trees
- theme switching and other TUI-only affordances

That is helpful. It means the protocol already draws a realistic portability boundary for us.

---

## 29. What this means for pimux specifically

The semantic UI direction is attractive, but it also exposes a major architectural fact:

> pi’s semantic UI is currently designed around the runtime’s active UI context.

That context differs by mode:

- in **interactive mode**, the active UI is the local TUI
- in **RPC mode**, the active UI is the external client via `extension_ui_request` / `extension_ui_response`

Current pimux live mode is neither of those things.

### 29.1 Current live mode is transcript-oriented, not UI-oriented

The current live bridge supports a narrow set of operations:

- session attach/detach
- transcript snapshots and appends
- assistant partial updates
- send user message
- get commands

It does **not** carry generic semantic UI requests.

So even though semantic UI exists in pi, the current pimux live socket is not yet exposing that layer.

### 29.2 Current headless fallback is too shallow for semantic UI

The headless fallback spins up a temporary RPC process to deliver a prompt and harvest transcript events.

That is enough for message delivery, but it is not currently treated as a persistent UI session with:

- long-lived dialog handling
- extension UI request routing
- user responses flowing back into the runtime

So the fallback path also does not currently give the iOS app access to semantic UI in any meaningful way.

### 29.3 The present architecture mirrors messages, not interaction state

Today pimux is effectively a transcript mirror plus message sender.

Semantic UI would require something stronger:

- a persistent bidirectional control channel
- request/response correlation for dialogs
- app-owned presentation of dialogs/selectors/editors
- a clear decision about which client is the authoritative UI for a session

That is a different integration level than the current one.

---

## 30. One especially important question: who owns the UI?

The semantic UI idea only really works if there is a clear answer to:

> When pi needs UI, where should that UI appear?

There are at least three possibilities:

### 30.1 Host TUI owns the UI

This is the current interactive pi model.

If the session is really a local TUI session that the iOS app is just watching, then semantic UI requests naturally belong to the host machine’s terminal UI.

That is coherent, but it means the iOS app is fundamentally a secondary client.

### 30.2 iOS owns the UI

This is the model implied by interest in semantic UI for pimux.

If iOS owns the UI, then semantic requests should surface in the app, not in the host TUI.

That suggests a more RPC-like or SDK-like hosting model where the app is the front-end client for the runtime’s UI context.

### 30.3 Dual UI / mirrored UI

In theory both UIs could exist, but that creates hard problems:

- which one gets the dialog?
- what happens if both respond?
- how do we keep editor state coherent?
- how do extension prompts behave when one client is backgrounded?

This seems much more complex and probably not worth targeting first.

### Working conclusion

If semantic UI is the direction, pimux likely needs to move toward:

> **one authoritative UI client per active session interaction flow**

That UI client could be the iOS app.

---

## 31. Recommended framing for future work

The most useful reframing seems to be:

### Not this

- “Can we reuse pi’s terminal components?”

### But this

- “Can pimux become a semantic UI client for pi?”

That would mean thinking in terms of:

- request/response protocol support
- native rendering of semantic dialogs and selectors
- explicit mapping of built-in slash commands to app/server actions
- transport changes so prompt submission and UI requests both use the same authoritative runtime path

---

## 32. Near-term implications for slash commands

If we adopt the semantic UI framing, slash commands break into two different implementation strategies.

### 32.1 Built-in interactive commands

These should likely become explicit app/server actions with native UI.

Examples:

- `/model` → native model selector UI
- `/settings` → native settings UI
- `/resume` → native session picker
- `/tree` → native tree navigation UI

These do not need terminal-component reuse. They need semantic parity.

### 32.2 Extension-driven interactions

These are where the RPC semantic UI protocol is most valuable.

If an extension asks for:

- `select`
- `confirm`
- `input`
- `editor`

then a future pimux client could handle those natively, even though it cannot render arbitrary TUI widgets.

That gives us a realistic incremental target.

---

## 33. Suggested priority order

If this document turns into implementation planning later, the most sensible order appears to be:

1. **Make slash command discovery honest**
   - stop advertising commands that the current transport cannot execute
2. **Decide whether iOS is ever intended to be an authoritative UI client**
   - if not, semantic UI is mostly a reference model
   - if yes, the transport architecture likely needs to change
3. **Target the RPC semantic UI subset, not TUI component reuse**
   - dialogs, status, widgets, editor prefill
4. **Implement native SwiftUI counterparts for that subset**
5. **Only then expand toward broader slash-command and extension parity**

---

## Final Assessment

The current iOS slash-command implementation is best described as:

> **a UI approximation of pi’s slash-command surface, not a faithful implementation of pi’s slash-command behavior**

The most important mismatches are:

1. **Built-in commands are shown but not executable**
2. **Live-mode submission bypasses the prompt pipeline that executes extension commands and expands templates/skills**
3. **Discovery, execution, and transport behavior are out of sync**

Until those are reconciled, the slash menu in iOS should be treated as incomplete and potentially misleading.
