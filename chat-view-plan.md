# Chat View Plan

## Goal

Move the iOS chat transcript to something that feels as stable as a normal chat app:

- opens at the bottom
- stays pinned to the bottom while new content streams in
- stops auto-following as soon as the user scrolls up
- does not bounce when rows re-enter the viewport
- does not overlap or relayout visibly while scrolling

The preference for now is:

- **keep row rendering in SwiftUI if possible**
- let **UIKit own scrolling/list behavior** if needed

## Current status

The active transcript implementation is back to the original SwiftUI stack in `pimux2000/Views/PiSessionView.swift`:

- `ScrollViewReader`
- `ScrollView`
- `LazyVStack`
- bottom anchoring via `.defaultScrollAnchor(.bottom)` and a change-driven `scrollTo`

The attempted `UITableView` transcript file has been removed.

## What has been tried

### 1. Original SwiftUI transcript

Implementation:

- `ScrollViewReader`
- `ScrollView`
- `LazyVStack`
- transcript rebuilt from full snapshot updates
- bottom following based on message-content changes

Observed issues:

- feels janky while streaming
- frequent layout churn
- bottom following is unstable
- expensive rows like markdown/tool output make relayout more visible

### 2. `UITableView` with SwiftUI rows using `UIHostingConfiguration`

Implementation:

- iOS-only `UITableView`, use swiftui `List` on macos.
- SwiftUI row views hosted with `UIHostingConfiguration`
- diffable data source
- estimated row heights
- attempt to keep the view pinned to bottom when near bottom

Observed issues:

- row heights changed as cells entered and left the viewport
- content bounced because the table kept correcting self-sized heights late
- bottom anchor behavior was unreliable
- table mechanics were better than `ScrollView`, but sizing was still unstable

### 3. `UITableView` with custom hosting cell + embedded `UIHostingController`

Implementation:

- custom `UITableViewCell`
- embedded `UIHostingController`
- classic table updates instead of diffable data source
- more explicit bottom-follow logic
- measured-height caching attempt

Observed issues:

- this version broke badly
- rows overlapped each other
- cell heights no longer matched rendered content
- once sizing was wrong, bottom anchoring was impossible

Conclusion:

- the problem is **not** “UITableView can’t do chat”
- the problem is **row measurement and update strategy**
- the broken custom-hosting attempt should not be revived as-is

## Key findings

### A. This is mostly a sizing problem first, scrolling problem second

Once rows have unstable heights, bottom-follow logic becomes guesswork.

### B. Full transcript replacement is a poor fit for a chat list

The server sends full snapshots, but the UI should not behave as if the whole list changed every time.

### C. SwiftUI rows can still work, but only if UIKit gets deterministic sizes

The successful hybrid approach likely requires:

- UIKit table/list container
- SwiftUI rows
- explicit offscreen measurement and caching
- incremental UI updates derived from snapshots

## Constraints and realities

### Product constraints

- The transcript should feel like Messages/Slack/ChatGPT-level stable scrolling on iOS.
- We want to avoid rewriting row rendering in UIKit unless necessary.

### Technical constraints

- The server stream is snapshot-based, not delta-based.
- Some rows are expensive and dynamic:
  - markdown
  - tool output
  - images
  - long assistant responses while streaming

## Acceptance criteria

A replacement is only good enough if all of these work:

1. Opening a long conversation lands at the bottom.
2. While pinned, streaming assistant text does not visibly bounce the transcript.
3. If the user scrolls up, auto-follow stops immediately.
4. If the user scrolls back to bottom, auto-follow resumes.
5. Rows do not visibly resize when they re-enter the viewport.
6. No row overlap or clipped content.

## Options moving forward

## Option 1: Stay with SwiftUI `ScrollView` and reduce churn

### Description

Keep the existing `ScrollView`/`LazyVStack` transcript and try to reduce how often it relayouts and auto-scrolls.

### Possible changes

- stop using last-message text changes as the main auto-scroll trigger
- only auto-scroll on append / send / explicit pinned state
- throttle or coalesce streaming updates to the last row
- split heavy message rendering from the main transcript view if needed

### Pros

- smallest code change
- preserves the current architecture
- no UIKit bridge needed

### Cons

- probably still fighting SwiftUI scroll behavior
- may improve things, but may not reach “normal chat app” quality
- historically this approach already feels janky here

### Recommendation

- **Low confidence** for a full fix
- reasonable only if we want a very small incremental improvement

---

## Option 2: `UITableView` / `UICollectionView` container with SwiftUI rows, measured offscreen

### Description

Use UIKit for list behavior, but keep every row implemented in SwiftUI. The important change is that row height is determined by an **offscreen measurement path**, not by letting visible cells discover their size late.

### Core design

- UIKit owns scrolling, pinning, and updates
- SwiftUI owns row rendering
- use one offscreen hosting view/controller purely for measurement
- cache measured heights by:
  - item id
  - available width
  - content version/hash
- visible cells use the cached size
- derive incremental table updates from full transcript snapshots

### Update model

Even if the server sends full snapshots, the iOS view layer should compute:

- appended rows
- changed rows (usually the last assistant row while streaming)
- fallback full reset only when structure truly changes

### Bottom-follow model

Track explicit state:

- `isPinnedToBottom`

Rules:

- initial load => pinned
- after send => pinned
- user scrolls up => unpinned
- user returns near bottom => pinned again

When pinned:

- preserve bottom distance across inserts/reloads/layout updates

When unpinned:

- never force-scroll

### Pros

- best chance of keeping SwiftUI rows
- much closer to the standard iOS chat architecture
- gives deterministic list mechanics

### Cons

- more engineering work than Option 1
- requires careful measurement/cache invalidation logic
- still some complexity because row rendering remains dynamic SwiftUI

### Recommendation

- **Best option if we want to keep SwiftUI cells**
- this is the recommended next implementation path

---

## Option 3: `UICollectionView` list layout with SwiftUI rows, measured offscreen

### Description

Similar to Option 2, but use `UICollectionView` instead of `UITableView`.

### Why consider it

- modern list API
- potentially nicer update control
- often preferred for highly custom chat UIs

### Pros

- flexible
- modern list/update model

### Cons

- more moving parts than `UITableView`
- likely more work for no immediate product benefit
- doesn’t solve sizing by itself; measurement problem still exists

### Recommendation

- viable, but not the shortest path
- only worth choosing if we expect substantial custom chat behaviors later

---

## Option 4: UIKit rows for transcript

### Description

Keep UIKit for both container and rows.

### Pros

- most conventional and proven path
- easiest to make truly boring and stable
- closest to how many polished chat apps are built

### Cons

- rewrites row rendering logic
- duplicates existing SwiftUI message UI
- larger maintenance burden right now

### Recommendation

- strongest fallback if the hybrid approach still fights us
- not first choice because we want to keep SwiftUI rows for now

## Recommended path

### Recommendation: Option 2

Try one disciplined pass with:

1. UIKit transcript container
2. SwiftUI rows
3. offscreen measurement
4. height cache
5. incremental updates derived from snapshots
6. explicit pinned/unpinned state
7. bottom-distance preservation instead of `scrollToBottom`

If that still cannot be made boring and stable, move to Option 4.

## Proposed implementation order for Option 2

### Phase 1: measurement prototype

Build a small transcript container prototype that proves these two things first:

- rows can be measured offscreen at a fixed width
- visible cells reuse cached heights and do not visibly resize when re-entering the viewport

Do **not** mix in live streaming logic yet.

### Phase 2: incremental update planner

Given old/new transcript snapshots, compute:

- appended rows
- reloaded rows
- fallback full reset

The planner should be isolated and testable.

### Phase 3: bottom pin controller

Implement explicit state:

- pinned
- unpinned

Then preserve bottom distance only when pinned.

### Phase 4: dynamic-content hardening

Stabilize known late-layout sources:

- markdown blocks
- images
- tool output

Likely tactics:

- reserve image placeholder heights
- avoid rows changing intrinsic height after first display when possible
- invalidate height cache only when content version actually changes

### Phase 5: hook up live stream behavior

Only after measurement and pinning are stable.

## Suggested guardrails

- Do not apply full-list UI replacement on every snapshot unless required.
- Do not rely on `scrollToRow` / `scrollToBottom` as the primary pinning mechanism.
- Do not let visible cells be the first place row size is discovered.
- Do not keep layering new heuristics onto `UIHostingConfiguration` if measurement remains unstable.

## Practical next step

Before coding a new transcript again, the next concrete step should be:

1. design the offscreen measurement approach
2. decide whether to use `UITableView` or `UICollectionView` for that implementation
3. define the transcript diff planner API

### My recommendation

- use **`UITableView`** for the next pass
- keep **SwiftUI rows**
- add **offscreen measurement + height caching** before touching bottom-pin behavior again

## Notes

- There are unrelated local changes in this repo outside the chat transcript work.
- The current project tree also has other in-progress model-layer modifications, so transcript work should stay isolated where possible.
