Added a first-pass `README.md` at the repo root.

What it covers:
- what `pimux2000` is
- repo structure
- basic app + server quick start
- testing
- scripts/docs pointers

Assumptions I made:
- root README should be **repo-level**, not a duplicate of the server’s detailed API docs
- detailed server behavior should stay in `pimux-server/README.md`

What I validated:
- no existing top-level `README.md`
- app is SwiftUI + GRDB
- server is a Rust CLI in `pimux-server/`

If you want, next I can tighten it in one of these directions:
1. **more product-facing**
2. **more contributor/dev-setup-focused**
3. **add screenshots / usage flow**
4. **add exact Xcode target/simulator instructions**