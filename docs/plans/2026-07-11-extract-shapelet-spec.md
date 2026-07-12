# Extract spec.lg into the shapelet Library

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **STATUS: COMPLETED** — see summary at the end.

**Goal:** Move rite's schema-validation module (`src/rite/spec.lg`) into the standalone `shapelet` library, release shapelet v0.1.0, and make rite consume it as a pinned git dependency.

**Tech Stack:** let-go (`lg` 1.11.1), lgx 0.1.1, cljfmt, clj-kondo, GitHub Actions.

---

## Design

### Context

rite and lgx each carry an identical 197-line copy of `spec.lg` — a minimal
schema-as-data validation engine ("malli in spirit"). The copies are
byte-identical modulo the namespace. This plan extracts rite's copy into
`shapelet`, an already-scaffolded standalone library repo at
`../shapelet` (github.com/abogoyavlensky/shapelet), and points rite at it.

Explicitly **out of scope**: touching lgx (it keeps its `lgx/spec.lg` copy),
and any sharing of the gitlibs-fetching mechanism — both postponed.

The shapelet repo is a fresh `lgx new` scaffold with a working setup:
GitHub remote, `checks.yml` CI (fmt + test), `release.yml` (publishes a
GitHub release on `v*` tags), and a `release` task in `lgx.edn` that tags
`v<version>` and pushes tags. No infra work is needed — only content.

### Key decisions

1. **Namespace `shapelet.core`, code moved verbatim.** Only the `ns` form
   changes; no renames or refactors during the move. A byte-identical body
   lets lgx later adopt shapelet with a trivially reviewable diff against
   its own copy.
2. **Public API = `validate`, `error->line`, and the error shape
   `{:path [...] :msg "..."}`.** The shapelet README documents the schema
   forms, largely lifted from the module's existing header comment.
3. **Tests move with the lib.** rite's `test/rite/spec_test.lg` becomes
   shapelet's `test/shapelet/core_test.lg` (replacing the greet scaffold)
   and is deleted from rite. rite's `config_test.lg` already exercises the
   engine through real schemas — the right coverage for a consumer.
4. **rite keeps the `spec` alias**: `[shapelet.core :as spec]` in
   `rite/config.lg`, so the rite diff is one require line, one stale
   comment, two deleted files, and one dep entry.
5. **Release v0.1.0; rite pins by tag**:
   `abogoyavlensky/shapelet {:git/url "https://github.com/abogoyavlensky/shapelet" :git/tag "v0.1.0"}`.
   During development, rite is verified against
   `:local/root "../shapelet"`; the coordinate is flipped to the git tag
   before the final e2e run and commit. `:local/root` is never committed.

### Order of work

Shapelet first, through tag-push; then rite. rite's final verification
(`bash tests/run.sh`: build + unit + e2e) must run against the real git
tag so it exercises lgx's dep fetch end-to-end. This is rite's first
non-empty `:deps` entry.

### Risks

- clj-kondo in rite may flag the `shapelet.core` require, since the dep's
  source is not on the lint path. If it does, add an exclusion to
  `.clj-kondo/config.edn` (rite already excludes let-go builtin
  namespaces there).
- rite's CI fetches the dep from GitHub at build time; it already has
  network access, so no workflow change is expected.

## File Structure

In `../shapelet` (separate git repo — commit there, not in rite):

- Modify: `src/shapelet/core.lg` — replace the greet scaffold with the
  full validation engine from rite's `src/rite/spec.lg` (ns
  `shapelet.core`).
- Modify: `test/shapelet/core_test.lg` — replace the scaffold test with
  rite's `test/rite/spec_test.lg` (ns `shapelet.core-test`).
- Modify: `README.md` — library docs: API, schema forms, error shape,
  usage as an lgx `:deps` coordinate.

In rite (this repo):

- Delete: `src/rite/spec.lg`
- Delete: `test/rite/spec_test.lg`
- Modify: `src/rite/config.lg` — require `[shapelet.core :as spec]`
  instead of `[rite.spec :as spec]`; update the comment on line 39 that
  says "see rite.spec for the schema language".
- Modify: `lgx.edn` — add the shapelet coordinate to `:deps`.
- Modify (only if lint requires): `.clj-kondo/config.edn`

### Task 1: Move the code and tests into shapelet

**Files:**
- Modify: `../shapelet/src/shapelet/core.lg`
- Modify: `../shapelet/test/shapelet/core_test.lg`

- [x] **Step 1: Confirm shapelet is clean**
  Run: `git -C ../shapelet status --short`
  Expected: no output. If there are stray changes, stop and ask.

- [x] **Step 2: Copy the module**
  Overwrite `../shapelet/src/shapelet/core.lg` with the full contents of
  rite's `src/rite/spec.lg`, changing only the ns form to
  `(ns shapelet.core (:require [string :as str]))`. Keep the header
  comment and everything else byte-identical.

- [x] **Step 3: Copy the tests**
  Overwrite `../shapelet/test/shapelet/core_test.lg` with the contents of
  rite's `test/rite/spec_test.lg`, changing the ns to
  `shapelet.core-test` and the require to `[shapelet.core :as spec]`
  (keep the `spec` alias so test bodies are untouched; update the file's
  header comment to say shapelet.core).

- [x] **Step 4: Run shapelet checks**
  Run: `cd ../shapelet && lgx fmt check && lgx lint && lgx test`
  Expected: fmt clean, lint clean, all tests pass (the suite is the ~40
  spec tests; the greet test is gone). If fmt fails, run `lgx fmt` and
  re-check.

- [x] **Step 5: Commit in shapelet**
  `git -C ../shapelet add -A && git -C ../shapelet commit -m "feat: add schema validation engine from rite"`

> Deviation: none. Codex review (P2, deferred): malformed composite schemas
> (`[:vector]`, `[:and]`, 2-element `[:map-of]`) throw only when a value
> exercises the missing child, not eagerly — pre-existing behavior kept to
> preserve the verbatim move; noted as a shapelet follow-up.

### Task 2: Write the shapelet README

**Files:**
- Modify: `../shapelet/README.md`

- [x] **Step 1: Write library documentation**
  Replace the scaffold README. Use /writing-clearly. Cover:
  - One-paragraph pitch: minimal schema-as-data validation for let-go,
    malli in spirit; returns error data, never throws on invalid values.
  - Installation: an lgx.edn `:deps` snippet with the
    `:git/url`/`:git/tag` coordinate (tag `v0.1.0`).
  - API: `validate` (schema + value → vector of `{:path [...] :msg "..."}`
    errors, empty when valid; throws only on malformed schemas) and
    `error->line` (one error → display line).
  - Schema forms, adapted from the header comment in `core.lg`:
    leaf keywords (`:string :keyword :symbol :map :vector :any`) and
    composites (`[:map ...]` with `{:closed true}` / entry
    `{:optional true}`, `[:map-of k v]`, `[:vector opts? item]`,
    `[:or opts? ...]`, `[:and ...]`, `[:enum ...]`, `[:fn f]` including
    the `:fn` result contract: nil / string / `{:path :msg}` / vector).
  - A short usage example with a realistic schema and a rendered error.
  - Keep the existing Development section (mise, lgx commands).

- [x] **Step 2: Commit in shapelet**
  `git -C ../shapelet add README.md && git -C ../shapelet commit -m "docs: document schema forms and API"`

### Task 3: Release shapelet v0.1.0

- [x] **Step 1: Push and watch checks**
  Run: `git -C ../shapelet push`
  Then: `gh run watch --repo abogoyavlensky/shapelet --exit-status`
  (or poll `gh run list --repo abogoyavlensky/shapelet --limit 1`)
  Expected: checks workflow green. Fix and re-push if not.

- [x] **Step 2: Tag the release**
  Run: `cd ../shapelet && lgx release 0.1.0`
  (the `release` task runs `git tag v0.1.0` and `git push --tags`)
  Expected: tag pushed; the release workflow publishes GitHub release
  v0.1.0. Verify with `gh release view v0.1.0 --repo abogoyavlensky/shapelet`.

> Deviation: no SSH keys in this environment, so instead of `lgx release`
> (which pushes over SSH) the tag was created and pushed manually over
> HTTPS (`git tag v0.1.0 && git push https://github.com/... v0.1.0`), as
> was the branch push in Step 1. Same effect: checks green, release
> workflow published v0.1.0.

### Task 4: Switch rite to the shapelet dep

**Files:**
- Modify: `lgx.edn`
- Modify: `src/rite/config.lg`
- Delete: `src/rite/spec.lg`
- Delete: `test/rite/spec_test.lg`

- [x] **Step 1: Add the dep (local, for the dev loop)**
  In `lgx.edn`, set:
  `:deps {abogoyavlensky/shapelet {:local/root "../shapelet"}}`

- [x] **Step 2: Rewire the require**
  In `src/rite/config.lg`: change `[rite.spec :as spec]` to
  `[shapelet.core :as spec]`; update the line-39 comment to point at
  shapelet instead of rite.spec.

- [x] **Step 3: Delete the moved files**
  Run: `git rm src/rite/spec.lg test/rite/spec_test.lg`

- [x] **Step 4: Verify against the local dep**
  Run: `lgx test`
  Expected: all remaining unit tests pass (spec tests are gone;
  config tests still pass via the dep).

- [x] **Step 5: Flip the coordinate to the released tag**
  In `lgx.edn`, replace the coord with:
  `{:git/url "https://github.com/abogoyavlensky/shapelet" :git/tag "v0.1.0"}`

- [x] **Step 6: Full check against the git dep**
  Run: `lgx fmt check && lgx lint && bash tests/run.sh`
  Expected: fmt clean; lint clean (if clj-kondo flags `shapelet.core`,
  add the minimal exclusion to `.clj-kondo/config.edn` and note it in
  the commit); build + unit + e2e all pass, with the dep fetched into
  the gitlibs cache by lgx.

- [x] **Step 7: Commit in rite**
  Check `git status --short` for unrelated changes first, then stage only
  this task's files:
  `git add lgx.edn src/rite/config.lg .clj-kondo/config.edn && git commit -m "refactor: replace rite.spec with shapelet dep"`
  (the two deletions were already staged by `git rm`; include
  `.clj-kondo/config.edn` only if Step 6 touched it)

### Task 5: Wrap up

- [x] **Step 1: Mark this plan complete**
  Tick all checkboxes in `docs/plans/2026-07-11-extract-shapelet-spec.md`,
  then:
  `git add docs/plans/2026-07-11-extract-shapelet-spec.md && git commit -m "docs: mark shapelet-extraction plan complete"`

---

## Completion Summary

**Implemented.** shapelet is now a real library: `shapelet.core` carries the
validation engine verbatim from rite (diff-verified, ns-only change) with its
49 tests and a README documenting the API, error shape, and all schema
forms. Released as v0.1.0 (shapelet CI green, GitHub release published by
the release workflow). rite consumes it via
`abogoyavlensky/shapelet {:git/url ... :git/tag "v0.1.0"}` — its first
non-empty `:deps` — with `rite.spec` and its tests deleted (−495 lines) and
`rite.config` requiring `[shapelet.core :as spec]`. Verified end-to-end:
lgx fetched the tag from GitHub into the gitlibs cache; fmt, lint, 260 unit
tests, and all e2e scenarios pass; the built binary renders shapelet
validation errors for a bad rite.edn and runs valid tasks.

**Issues encountered.** None blocking. The anticipated clj-kondo exclusion
for `shapelet.core` was not needed. Codex's per-task reviews surfaced one
deferred finding (below) and confirmed the rest clean.

**Deviations (gathered).**
- Task 1: none in the change itself. Codex P2 deferred: malformed composite
  schemas (`[:vector]`, `[:and]`, 2-element `[:map-of]`) throw only when a
  value exercises the missing child, not eagerly — pre-existing engine
  behavior kept to preserve the verbatim move; follow-up belongs in
  shapelet.
- Task 3: no SSH keys in the environment, so the branch and tag were pushed
  over HTTPS manually instead of via `lgx release` (same effect; release
  workflow published v0.1.0).

**What the plan could have specified better.** The push/release steps
assumed SSH access; specifying an HTTPS fallback (or checking auth up
front) would have avoided the mid-task improvisation. Otherwise it held up.
