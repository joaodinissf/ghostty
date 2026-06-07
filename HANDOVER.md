# Handover — Ghostty `split-junction-drag`: pane junction-drag, focus-gate, pop-out + crash fix

*Generated: 2026-05-31*
*Branch: `split-junction-drag` (fork `joaodinissf/ghostty`)*
*Last commit: `2f9f0a799` macos: clamp split drag so a pane can't collapse below a usable size*

> ⚠️ **Temporary checkpoint doc**, committed to the fork branch for future reference. Clean up /
> remove before this branch ever goes near a PR. It is on the fork only — **never push upstream**.

---

## What We Were Working On

Turn a single "vibe-coded prototype, NOT for upstream" commit (split T/+/double-T junction drag)
on `split-junction-drag` into a clean, atomic, signed, tested commit stack, and extend it to cover
**three pane problems** the user cares about, then fix a crash found in manual testing:

- **P1 — Junction drag (T / + / double-T):** drag the corner where 3–4 panes meet.
- **P2 — Focus-gated seam drag (top annoyance):** a divider only dragged when the seam bordered the
  *focused* pane; clicking a boundary next to an unfocused pane did nothing.
- **P3 — Pop-out pane:** tear a pane into its own window via a 3-dot handle (Chrome-tab style).

Machine is **macOS/darwin**: Zig core + macOS app build & test here; **GTK cannot be built/run
here** (only `zig fmt` / `prettier`).

---

## What Got Done

- [x] Rebased the prototype onto `upstream/main` (`2c62d182c`); resolved conflicts (overlapping
      test additions + `.blp` Overlay), Zig tests green.
- [x] Backed up the old prototype as tag `backup/split-junction-drag-proto` (`29dd71a02`), pushed
      to the fork.
- [x] Rebuilt the branch as a clean **9-commit** stack via per-lane git worktrees
      (core / macOS / GTK), then linear cherry-pick. All commits SSH-signed, Conventional Commits,
      with `Co-Authored-By: Claude Opus 4.8 (1M context)` trailer.
- [x] **P1 core:** `junctionAt` + `Junction` + `junction_plus_epsilon` (`9079794d5`); macOS junction
      handles with a11y + identity-based resize (`ad9f3c5b4`); GTK handles (`4a686b979`, untested).
- [x] **P2 (the marquee fix):** seam hit-region registry (`7420d645c`) + focus-gate pass-through
      (`111b69f06`) — divider/junction handles now drag on the first mouse-down over an unfocused pane.
- [x] **P3:** core `detach` helper (`6ff57b607`); GTK pop-out via drag-source + 3-dot handle
      (`5263f75f3`, untested). macOS pop-out already exists upstream.
- [x] **Crash fix:** `+`-drag-past-edge `integer overflow` → root-caused via lldb, fixed in
      `resizeCols` (`6a175ed03`) + deterministic Zig regression test; macOS clamp hardening
      (`2f9f0a799`) + 4 Swift tests.
- [x] Verified on macOS: Zig core tests, macOS `SplitTreeTests` / `SplitSeamRegistryTests` /
      `SplitGeometryTests`, full `ReleaseSafe` build; **user manually confirmed the `+` drag no
      longer crashes**.
- [x] Pushed everything to the fork (`origin/split-junction-drag` @ `2f9f0a799`). No PRs/issues.
- [ ] **GTK commits (`4a686b979`, `5263f75f3`) NOT built or tested** — pending a Linux/GTK machine.
- [ ] macOS pop-out *reliability* (pre-existing upstream) not investigated.

**The 9-commit stack (newest → oldest), base `upstream/main` `2c62d182c`:**
```
2f9f0a799 macos: clamp split drag so a pane can't collapse below a usable size
6a175ed03 terminal: fix resizeCols integer overflow when cursor row exceeds shrunk rows
5263f75f3 gtk: pop out a pane into a new window via 3-dot handle           [TODO(gtk-untested)]
4a686b979 gtk: add junction drag handles for T/+ splits                    [TODO(gtk-untested)]
ad9f3c5b4 macos: add junction drag handles for T/+ splits
111b69f06 macos: let seam clicks pass the focus-transfer gate
7420d645c macos: publish split seam/handle hit-regions to SurfaceView
6ff57b607 splits: add detach-leaf helper for pop-out
9079794d5 splits: add junctionAt query and +-junction alignment epsilon
```

---

## What Worked

- **Live `lldb` debugging with panic breakpoints** to symbolicate the crash. Ghostty's
  Sentry/breakpad handler swallows the panic and exits *cleanly*, so a plain `lldb run` saw a normal
  exit. Setting `breakpoint set -r [Pp]anic -C 'bt' -C 'quit'` stopped *at* the panic and gave a
  symbolicated backtrace pinpointing `PageList.zig`.
- **Disambiguating Debug vs real bugs by rebuilding `ReleaseSafe`**: the first crash was a
  Debug-only `slow_runtime_safety` assert; rebuilding ReleaseSafe proved the `integer overflow` was
  a *real* bug (normal safety, on in Release).
- **Per-lane git worktrees** (core/macOS/GTK with disjoint file sets) → parallel implementation with
  zero cross-lane merge conflicts at coalesce.
- **A regression test proven by temporarily un-fixing**: removed the guard, confirmed the test
  panics with `integer overflow`, restored the guard, confirmed it passes — guaranteeing the test
  actually catches the regression.
- **Reading the actual code before delegating** caught design landmines (own Swift tree, dead
  `junctionResize`, `Binding.Action` exhaustive-switch ripple) that would have broken a blind
  parallel run.

## What Didn't Work

- **First HANDOVER/git output was visually corrupted** mid-session (duplicated lines) — facts were
  re-derived from earlier reliable points (e.g. push log `5263f75f3..2f9f0a799`).
- **Launching the app from the sandboxed Bash tool got it reaped** when the command finished — looked
  like a crash but wasn't. Fix: launch detached (`nohup … & disown`) with the sandbox disabled.
- **First regression-test attempt didn't reproduce** the crash (no cursor `pin` → preservation block
  short-circuited). Fixed by passing a *tracked* cursor pin, matching how `Screen.resize` calls it.
- **The early `cy = @min(...)` clamp fix was insufficient** — with a cursor pin set it fixed the
  overflow but not the Debug order-assert. Replaced with skip-when-`c.y >= self.rows`.

## Key Decisions & Rationale

- **Dropped the core `junctionResize` helper** (dead code): GTK keeps pixel-space `GtkPaned`
  live-drag (rebuilding the tree per motion event would tear down the active gesture); macOS uses
  its **own Swift `SplitTree`**. Kept `junctionAt`, `junction_plus_epsilon`, `detach` (GTK consumes).
- **No new `Binding.Action`** for pop-out — it would ripple into exhaustive switches across the
  untestable GTK apprt + the C ABI. Pop-out is driven by drag/handle, not a keybind.
- **Crash fix = skip cursor preservation when `c.y >= self.rows`** rather than clamp — cleaner, and
  handles both the overflow (ReleaseSafe) and the stale-pin order assert (Debug) in one guard.
- **GTK authored blind but clearly flagged** (`TODO(gtk-untested)` trailers) per user's choice — they
  validate GTK on a separate Linux box.
- **Clean history via reset-to-base + cherry-pick + force-push-with-lease**, with a `backup/...` tag
  for safety (user chose this over stacking fixups).
- **Fork-only workflow:** push to save, **never** open PRs/issues without explicit instruction (also
  enforced by the repo's `CLAUDE.md`).

## Lessons Learned & Gotchas

- **Pinned compiler:** use `/opt/homebrew/opt/zig@0.15/bin/zig` (0.15.2). Default `zig` is 0.16 and
  the project **rejects** it. `export PATH=/opt/homebrew/opt/zig@0.15/bin:$PATH`.
- **macOS app uses its own Swift `SplitTree`**, not the Zig datastruct — a "shared core helper"
  only ever helps GTK.
- **Crash mechanics:** `GridSize.update` floors grid at `@max(1, …)` → a collapsed pane becomes
  `rows = 1` (legal). `resizeCols` (column reflow) overflowed at `rows = 1` because `resize` shrinks
  rows *before* reflowing cols, leaving a stale `cursor.y` from the taller layout; `Screen.resize`
  always passes `.pin = self.cursor.page_pin`, so the preservation block can't be skipped by a null
  pin. The `+` junction is the only gesture that changes a pane's **columns while rows ≈ 1**
  (out-of-bounds drag → old flat `minSize = 10pt` < one ~34px row).
- **`slow_runtime_safety` is Debug-only** (`src/build/Config.zig:583`) — Debug asserts won't fire in
  Release; don't conflate them with real bugs.
- **Ghostty's crash handler hides panics from lldb** unless you breakpoint the panic path.
- **GUI apps launched from sandboxed Bash get reaped** — launch detached, sandbox disabled.
- **Xcode project uses file-system-synchronized groups** — new files under `macos/Tests/...` are
  auto-included; no `project.pbxproj` edits needed.
- **Commit "signature: N" / `allowedSignersFile` errors are verification-side only** — commits ARE
  signed (`git cat-file commit <h>` shows the `gpgsig` header).
- **Branch base drift:** branch is on `2c62d182c`; `upstream/main` has since advanced (e.g.
  `16f2fdc90`). A future rebase may be wanted before any upstreaming.

## Next Steps

1. **Build & test the two GTK commits on a Linux/GTK machine** (the only real blocker). Watch list:
   `gdk.ContentProvider.newForValue` binding name; GestureClick/DragSource `callconv(.c)` handler
   shapes; `f16 → f64` epsilon coercion; the `surface.zig ↔ split_tree.zig` import cycle; blueprint
   compile of both `.blp` files; `prettier -w` (blueprint) producing no diff. Then manually verify
   GTK junction-drag (T/+/lockstep) and pop-out (3-dot handle + drag-out, single-pane no-op,
   no leaks/double-dispose).
2. **Reset the test environment:** quit the running dev build (`zig-out/Ghostty.app`) and
   `defaults delete com.mitchellh.ghostty GhosttyDebugSplitSeams` (the seam debug overlay was left on).
3. **(Optional) Investigate macOS pop-out reliability** — the 3-dot handle is pre-existing upstream;
   the user finds it flaky. Separate latent bug.
4. **(Optional) Consider upstreaming the `resizeCols` overflow fix (`6a175ed03`)** — a genuine,
   isolated core bug fix. **Do NOT open a PR/issue without explicit instruction.**
5. **Before any PR:** remove this `HANDOVER.md`, re-evaluate GTK adoption of core helpers, and
   consider rebasing onto current `upstream/main`.

## Key Files & Locations

| File | Purpose |
|------|---------|
| `src/datastruct/split_tree.zig` | Core `junctionAt` + `Junction` + `junction_plus_epsilon`; `detach`/`Detached`; tests |
| `src/terminal/PageList.zig` | **Crash fix** in `resizeCols` cursor-preservation (skip when `c.y >= self.rows`) + regression test |
| `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` | P2: `localEventLeftMouseDown` lets seam clicks through the focus gate (does NOT touch `acceptsFirstMouse`, Issue 2595) |
| `macos/Sources/Features/Splits/SplitView.swift` | Divider + `JunctionHandleView`; `SplitGeometry.clampedRatio`; `minSize` 10→24; seam publishing |
| `macos/Sources/Features/Splits/SplitSeamRegistry.swift` | Per-window divider/junction hit-region registry (window coords) |
| `macos/Sources/Features/Splits/TerminalSplitTreeView.swift` | Emits `.junctionResize` (single combined edit) |
| `macos/Sources/Features/Terminal/BaseTerminalController.swift` | `junctionDidResize`; owns `splitSeamRegistry`; pre-existing pop-out path |
| `macos/Tests/Splits/SplitGeometryTests.swift` | New clamp regression tests (out-of-bounds, midpoint, degenerate) |
| `src/apprt/gtk/class/{split_tree,surface,tab,window,application}.zig`, `ui/1.5/split-tree-split.blp`, `ui/1.2/surface.blp` | **GTK (untested)** junction drag + pop-out |
| `/Users/joao/.claude/plans/reactive-wondering-forest.md` | Approved plans (feature stack + crash fix) |

## Additional Notes

- **Build/test commands** (pinned zig on PATH first):
  - Core: `zig build -Demit-macos-app=false` ; `zig build test -Demit-macos-app=false -Dtest-filter="<name>"`
  - macOS app: `zig build` or `zig build -Doptimize=ReleaseSafe` (SwiftLint runs as a build phase)
  - Swift tests: `xcodebuild test -project macos/Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -only-testing:GhosttyTests/<Suite>`
- Backup of the old prototype: tag `backup/split-junction-drag-proto` (`29dd71a02`), on the fork.
- Memory note tracks the pending GTK test: `project_ghostty_split_junction_gtk_untested.md`.
- An untracked `zig-pkg/` build-artifact dir exists in the repo (not ours; ignore).
