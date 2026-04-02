# Commit Message

## Replace builtin shadow commands with internal live IPC (Protocol v7)

### Summary
Remove Pi's "Extension command conflicts with built-in" warnings by replacing the bad pattern of registering `/name`, `/compact`, and `/reload` as shadow extension commands with a proper semantic IPC layer.

### Changes

**pimux-live.ts**
- Remove `pi.registerCommand("name")`, `pi.registerCommand("compact")`, `pi.registerCommand("reload")`
- Add `PimuxBuiltinCommandAction` type for semantic builtin operations
- Add `builtinCommand` and `builtinCommandResult` IPC message types
- Implement `handleBuiltinCommand()` to execute actions directly in extension context
- Capture reload action via `ExtensionRunner` monkeypatch for internal execution
- Track active `ExtensionContext` for session state access during builtin execution
- Bump protocol version: 6 → 7

**live.rs**
- Add `BuiltinCommandError` enum and timeout handling
- Add `send_builtin_command()` method to dispatch semantic actions
- Add inflight builtin command tracking with proper lifecycle management
- Add `BuiltinCommand` and `BuiltinCommandResult` IPC message types
- Route inbound builtin command results to fulfillment handlers
- Bump protocol version: 6 → 7

**agent/mod.rs**
- Change `try_run_live_builtin_command()` to accept `SessionBuiltinCommandRequest` instead of string bodies
- Replace `send_user_message()` slash-text injection with `send_builtin_command()` semantic dispatch
- Update error handling for builtin command execution

### Benefits
- ✅ Eliminates Pi builtin conflict warnings (cleaner extension loading)
- ✅ Semantic IPC instead of string-based injection (more maintainable)
- ✅ Proper error semantics and timeout handling
- ✅ Consistent with existing dialog action pattern
- ✅ All existing functionality preserved (live and headless paths unchanged)
- ✅ Tests: 71/71 pass
- ✅ Protocol versions synchronized: both at 7

### Note
The backwards-compatibility reload attempt in live.rs (send_user_message for version mismatch) is retained as a last-resort fallback for detecting ancient protocol incompatibility—it does not interfere with normal operation.
