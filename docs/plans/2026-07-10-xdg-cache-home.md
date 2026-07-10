# XDG Cache Home Implementation Plan ✅ COMPLETED

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move rite's default dependency cache from the lgx-shared `~/.lgx` to the XDG cache location `~/.cache/rite`.

**Tech Stack:** let-go (lg), lgx build/test, bash e2e harness.

---

## Design

### Current behavior

`rite.home/root` resolves the state root as `RITE_HOME` → `LGX_HOME` → `~/.lgx`,
so rite shares lgx's gitlibs cache by default. Fetched deps land under
`<root>/gitlibs/<host>/<owner>/<repo>/<ref>/`.

### New behavior

`rite.home/root` resolves as:

1. `RITE_HOME` if non-blank (explicit override, unchanged)
2. `$XDG_CACHE_HOME/rite` if `XDG_CACHE_HOME` is non-blank
3. `~/.cache/rite`

### Key decisions

- **Drop `LGX_HOME` from the chain.** With the default no longer `~/.lgx`,
  honoring `LGX_HOME` would mean setting it for lgx purposes silently
  relocates rite's cache. One tool, one home.
- **Keep the cache layout identical** (`<root>/gitlibs/<host>/<owner>/<repo>/<ref>/`).
  Sharing with lgx becomes a documented opt-in: `RITE_HOME=~/.lgx` interoperates
  byte-for-byte.
- **Plain `~/.cache` on macOS too** — no `~/Library/Caches` branching; standard
  for cross-platform CLI tools (go, uv, pnpm).
- **Blank means unset.** let-go's `os/getenv` returns `""` for unset vars, so
  the chain tests each var with `str/blank?`, matching the existing style.
- **No migration logic.** The cache is disposable; worst case a dep re-fetches
  once into the new location.

## File Structure

- Modify: `src/rite/home.lg` — new resolution chain and docstring.
- Modify: `src/rite/deps.lg` — top comment says "shared with lgx by default";
  now describes the XDG default.
- Modify: `test/rite/home_test.lg` — replace the `LGX_HOME` fallback test with
  `XDG_CACHE_HOME` tests.
- Modify: `README.md` — `RITE_HOME` env-var table row and the `:deps` section
  wording about the shared cache.
- Modify: `tests/e2e.sh` — clear `XDG_CACHE_HOME` in the hermeticity preamble.

### Task 1: Home resolution chain

**Files:**
- Modify: `src/rite/home.lg`
- Test: `test/rite/home_test.lg`

- [x] **Step 1: Update the unit tests**
  In `test/rite/home_test.lg`, keep the save-as-`""`-and-restore pattern the
  file already uses and cover the new chain:
  - `root-prefers-rite-home`: with both `RITE_HOME` and `XDG_CACHE_HOME` set,
    `home/root` returns `RITE_HOME` verbatim.
  - `root-falls-back-to-xdg-cache-home`: with `RITE_HOME` blank and
    `XDG_CACHE_HOME` set to `/tmp/xdg-cache-test`, `home/root` returns
    `/tmp/xdg-cache-test/rite`.
  - `root-defaults-to-home-dot-cache-rite`: with both blank, `home/root`
    returns `(path/join (os/getenv "HOME") ".cache" "rite")`.
  Each test must set `XDG_CACHE_HOME` to a known value or `""` itself —
  never rely on the ambient environment — and restore both vars to `""`
  afterward. Delete the `LGX_HOME` test.

- [x] **Step 2: Run tests to verify they fail**
  Run: `lgx test`
  Expected: FAIL — the XDG fallback and new default assertions fail against
  the current `~/.lgx` chain.

- [x] **Step 3: Implement the new chain**
  In `src/rite/home.lg`, replace the `LGX_HOME` cond branch:

  ```clojure
  (cond
    (not (str/blank? rite-home)) rite-home
    (not (str/blank? xdg-cache)) (path/join xdg-cache "rite")
    :else (path/join (os/getenv "HOME") ".cache" "rite"))
  ```

  Update the docstring: RITE_HOME wins; else `$XDG_CACHE_HOME/rite`; else
  `~/.cache/rite`. Confirm `path/join` accepts three args (it is used
  variadically in `deps.lg`); if not, nest two calls.

- [x] **Step 4: Run tests to verify they pass**
  Run: `lgx test`
  Expected: PASS, all suites.

- [x] **Step 5: Commit**
  `git commit -m "feat: default dep cache to XDG ~/.cache/rite"`

> Deviation: codex review (P2) — the XDG spec requires `XDG_CACHE_HOME` to be
> absolute and says relative values must be ignored. Added a `path/absolute?`
> guard to the XDG branch plus a regression test; fixup commit `6c339d7`.

### Task 2: Comments, docs, and e2e hermeticity

**Files:**
- Modify: `src/rite/deps.lg`
- Modify: `README.md`
- Modify: `tests/e2e.sh`

- [x] **Step 1: Update the deps.lg cache-layout comment**
  The header comment block in `src/rite/deps.lg` (lines ~7–17) says the home
  is "shared with lgx by default". Reword: home = `rite.home/root`, defaulting
  to `$XDG_CACHE_HOME/rite` or `~/.cache/rite`; layout is lgx-compatible, so
  `RITE_HOME=~/.lgx` shares lgx's cache.

- [x] **Step 2: Update README**
  Use /writing-clearly. Two spots:
  - Env-var table (line ~264): `RITE_HOME` default becomes
    `$XDG_CACHE_HOME/rite`, else `~/.cache/rite`. Note that pointing it at
    `~/.lgx` reuses lgx's cache (same layout).
  - `:deps` section (line ~204): "fetches let-go libraries into a shared
    cache" — keep "shared" meaning across projects, and drop any implication
    that lgx sharing is the default.

- [x] **Step 3: Harden e2e preamble**
  In `tests/e2e.sh`, alongside the existing hermeticity setup (the harness
  already exports throwaway `RITE_HOME` dirs), unset or blank
  `XDG_CACHE_HOME` so a caller's value can never leak into any scenario.
  Update the header comment if it mentions the `~/.lgx` default.

- [x] **Step 4: Run the full suite**
  Run: `lgx test && bash tests/run.sh`
  Expected: unit tests PASS; all e2e scenarios PASS (39 assertions at last
  count).

- [x] **Step 5: Commit**
  `git commit -m "docs: describe XDG cache default; keep e2e hermetic to XDG_CACHE_HOME"`

---

## Completion Summary

**Implemented.** `rite.home/root` now resolves `RITE_HOME` →
`$XDG_CACHE_HOME/rite` (absolute values only) → `~/.cache/rite`; `LGX_HOME`
is dropped from the chain. Cache layout is unchanged, so `RITE_HOME=~/.lgx`
still shares lgx's cache as a documented opt-in. Docs, the `deps.lg` layout
comment, and the e2e preamble updated accordingly.

**Commits:** `17b190b` (chain + tests), `6c339d7` (relative-XDG fixup),
`18eeaad` (docs + e2e hermeticity).

**Verification:** 293 unit tests and all 39 e2e assertions pass. Exercised
end-to-end with the built binary: a `:run` task fetched a `file://` git dep
into `$XDG_CACHE_HOME/rite/gitlibs/...` with only `XDG_CACHE_HOME` set, into
`~/.cache/rite/gitlibs/...` with neither var set, and a relative
`XDG_CACHE_HOME` was ignored (fell back to the HOME default, nothing written
into the project).

**Deviations:** one — codex review (P2) flagged that the XDG spec requires
`XDG_CACHE_HOME` to be absolute; added a `path/absolute?` guard plus a
regression test (`6c339d7`). Codex approved the docs commit with no findings.

**What the plan could have specified better:** the XDG spec's
relative-path rule — the plan said "non-blank" where it should have said
"non-blank and absolute". Otherwise it held up.
