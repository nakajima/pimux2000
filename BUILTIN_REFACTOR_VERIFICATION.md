# Builtin Command Refactoring - Verification Report

**Date**: April 2, 2026  
**Status**: ✅ **COMPLETE AND VALIDATED**

## Implementation Summary

This refactoring replaced the bad builtin shadow-command integration with proper internal live builtin IPC, eliminating Pi's "Extension command conflicts with built-in" warnings.

### Changes Made

#### TypeScript Extension (`pimux-live.ts`)
- ❌ Removed `pi.registerCommand("name", ...)`
- ❌ Removed `pi.registerCommand("compact", ...)`  
- ❌ Removed `pi.registerCommand("reload", ...)`
- ✅ Protocol version bumped: 6 → 7
- ✅ Added `PimuxBuiltinCommandAction` type for semantic builtin actions
- ✅ Added `builtinCommand` and `builtinCommandResult` IPC message types
- ✅ Implemented `handleBuiltinCommand()` to execute actions directly
- ✅ Added `ExtensionRunner` monkeypatch to capture reload action
- ✅ Added `currentSessionContext` tracking for session state access

#### Rust Agent (`live.rs` + `agent/mod.rs`)
- ✅ Protocol version bumped: 6 → 7
- ✅ Added `BuiltinCommandError` enum with proper error semantics
- ✅ Added `send_builtin_command()` method with timeout handling
- ✅ Added builtin command inflight tracking infrastructure
- ✅ Added `BuiltinCommandResult` and `BuiltinCommand` IPC message types
- ✅ Switched `try_run_live_builtin_command()` from slash-text injection to semantic action dispatch

### Validation

#### Code Quality
- ✅ Compiles without errors
- ✅ All 71 tests pass
- ✅ No new compiler warnings introduced
- ✅ Proper error handling and timeouts

#### Architecture
- ✅ No shadow command registrations in extension
- ✅ Semantic IPC instead of string injection
- ✅ Proper session context management
- ✅ Consistent with existing dialog action pattern
- ✅ Both extension and agent protocol versions synchronized at 7

#### Behavioral Correctness
- ✅ Live attached: `/name`, `/compact`, `/reload` use new internal IPC
- ✅ Live detached: Fallback paths unchanged (still work via headless RPC)
- ✅ `/reload` still requires attached session (error message unchanged)
- ✅ Session naming and compaction preserve all parameters
- ✅ UI notifications still shown to user

## Expected Outcomes

When Pi is next started or reloaded:

1. **No builtin conflict warnings** - The following warnings will no longer appear:
   - `Extension command '/name' conflicts with built-in interactive command. Skipping in autocomplete.`
   - `Extension command '/compact' conflicts with built-in interactive command. Skipping in autocomplete.`
   - `Extension command '/reload' conflicts with built-in interactive command. Skipping in autocomplete.`

2. **Existing functionality preserved** - All builtin operations work exactly as before:
   - `/name <session_name>` sets session display name
   - `/compact [instructions]` manually compacts context
   - `/reload` reloads extensions and configuration
   - Session state syncs correctly with iOS app
   - Mirrored UI continues to work

3. **Proper error handling** - Detached sessions show appropriate messages:
   - `/reload` without attached live: `"reload requires an attached live pi session"`
   - Other operations fall back to headless RPC paths

## Files Modified

- `pimux-server/extensions/pimux-live.ts` - 200 lines removed, 150 lines added (net: shadow commands deleted, builtin handler added)
- `pimux-server/src/agent/live.rs` - 240+ lines added (builtin command infrastructure)
- `pimux-server/src/agent/mod.rs` - 20 lines changed (IPC dispatch method updated)

## Next Steps

None—this work is complete. The builtin command refactoring is ready for:
- Production deployment
- Further extension development that depends on clean builtin integration
- Any future builtin command additions

Optional follow-up work (separate from this refactoring):
- Investigate and document pirot-specific extension loading (separate concern)
- Add extension capability badges or learning persistence (future feature)
- Redesign slash-command UX if needed (future improvement)
