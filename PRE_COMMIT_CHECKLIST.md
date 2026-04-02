# Pre-Commit Verification Checklist

**Purpose**: Final sanity check before committing the builtin command refactoring

Run through this checklist to verify everything is ready:

---

## Code Changes ✅

- [x] Shadow commands removed from `pimux-live.ts`
  ```bash
  grep -r 'registerCommand.*"name"\|registerCommand.*"compact"\|registerCommand.*"reload"' pimux-server/extensions/
  # Should return: (no output)
  ```

- [x] Protocol version synchronized at 7
  ```bash
  grep LIVE_PROTOCOL_VERSION pimux-server/extensions/pimux-live.ts pimux-server/src/agent/live.rs
  # Should show: both = 7
  ```

- [x] Builtin command handler exists
  ```bash
  grep -c "handleBuiltinCommand" pimux-server/extensions/pimux-live.ts
  # Should return: 1 (one definition)
  ```

- [x] IPC messages properly typed
  ```bash
  grep "builtinCommand" pimux-server/extensions/pimux-live.ts | wc -l
  # Should return: 5+ matches (types + handler calls)
  ```

---

## Compilation ✅

Run before committing:
```bash
cd pimux-server && cargo check
```

Expected result:
- ✅ No compilation errors
- ⚠️ 2 pre-existing warnings (acceptable)

---

## Tests ✅

Run to ensure no regressions:
```bash
cd pimux-server && cargo test --quiet
```

Expected result:
- ✅ `test result: ok. 71 passed; 0 failed`
- ✅ All tests pass
- ✅ No new failures

---

## Git Status ✅

Check what will be committed:
```bash
git status -s
```

Should show these 3 modified files:
- [x] `pimux-server/extensions/pimux-live.ts`
- [x] `pimux-server/src/agent/live.rs`
- [x] `pimux-server/src/agent/mod.rs`

Other files in working directory (not to be committed with this):
- `compact-handoff.md` - documentation (optional)
- `todo.txt` - notes (optional)

---

## Final Verification Commands

```bash
# 1. No shadow commands anywhere
grep -r 'registerCommand.*"name"' . --include="*.ts" --include="*.rs" 2>/dev/null
# Expected: (no output)

# 2. Protocol versions match
grep "LIVE_PROTOCOL_VERSION = 7" pimux-server/extensions/pimux-live.ts
grep "LIVE_PROTOCOL_VERSION: u32 = 7" pimux-server/src/agent/live.rs
# Expected: both found

# 3. Builtin handler exists
grep "async fn handleBuiltinCommand" pimux-server/extensions/pimux-live.ts
# Expected: found

# 4. Error enum exists
grep "pub enum BuiltinCommandError" pimux-server/src/agent/live.rs
# Expected: found

# 5. Builds clean
cargo check --manifest-path pimux-server/Cargo.toml
# Expected: Finished with no errors

# 6. Tests pass
cargo test --manifest-path pimux-server/Cargo.toml --quiet
# Expected: test result: ok. 71 passed; 0 failed
```

---

## Ready to Commit

Once all checks pass, commit with:

```bash
git add pimux-server/extensions/pimux-live.ts \
        pimux-server/src/agent/live.rs \
        pimux-server/src/agent/mod.rs

git commit -F BUILTIN_REFACTOR_COMMIT_MSG.md

# Optional: Review before pushing
git log --oneline -1
git show --stat HEAD
```

---

## Rollback Plan (if needed)

If anything goes wrong:
```bash
git reset HEAD~1              # Undo last commit
git checkout -- .             # Discard changes
```

Or just revert the specific files:
```bash
git checkout HEAD -- <filename>
```

---

## Sign-Off

- [ ] All compilation checks pass
- [ ] All tests pass (71/71)
- [ ] No shadow command registrations found
- [ ] Protocol versions synchronized
- [ ] Ready to commit

Once all boxes are checked, you're good to commit! 🚀

