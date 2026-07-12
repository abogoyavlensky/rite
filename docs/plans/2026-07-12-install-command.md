# `rite install` Command Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a built-in `rite install` command that fetches every task's `:deps` (transitively) into the shared gitlibs cache, so later `:run` steps hit no network. Idempotent.

**Tech Stack:** let-go (lg) / lgx toolchain; reuses the existing `rite.deps` resolver and `file://` git-dep test harness.

---

## Design

Pre-fetching a project's dependencies is a standard task-runner affordance:
warm the cache for editor navigation, CI, or offline work without running a
task. The sibling tool `lgx` — whose conventions rite already mirrors (cache
layout, `RITE_HOME=~/.lgx` reuse, completion design) — has exactly this as
`lgx install`: *"Fetch deps from `:deps` into the gitlibs cache. Idempotent."*
rite differs only in where deps live: lgx has one project-root `:deps`, rite has
per-task `:deps`. So `rite install` fetches **every task's** `:deps`.

The name `install` was chosen deliberately: it mirrors lgx, it is already the
codebase's internal vocabulary (`rite.deps` prints *"installing N dep(s)…"* and
tracks `:installed?`), and it is a verb — unlike `rite tasks`, which *lists*, so
`rite deps` would read as "show deps," not "fetch them."

### Command semantics

`rite install`:

1. Finds the project (`config/find-project!` — exits 1 with the standard "no
   rite.edn" message when absent) and loads it (`config/load-config!` — exits 1
   on an invalid `rite.edn`, consistent with every other command).
2. Fetches **each task's** `:deps` into the gitlibs cache and prints a summary.
3. Exits 0 on success; on a fetch failure, prints a clean
   `rite: install: <message>` to stderr and exits 1.

### Key decisions

- **Per-task resolution, not merged.** `rite install` calls the existing
  `deps/ensure-all!` once **per task** that declares `:deps`, rather than
  merging all tasks' `:deps` into one map. Two tasks may legitimately pin
  different refs of the same lib, and at runtime each task resolves its own
  basis independently; merging would let one ref win and silently skip
  pre-fetching the other. The cache is keyed by URL+ref, so a coord shared
  across tasks is fetched once — the second task sees it cached
  (`:installed? false`, no re-clone). This reuses `ensure-all!` untouched,
  including its transitive walk and intra-task first-wins conflict warning. It
  also produces **no** spurious cross-task conflict warnings, because there is
  no shared `seen` set across tasks — which is correct, since differing pins in
  different tasks are legal.

- **Covers all tasks, not a dependency subgraph.** Every task's deps are
  installed — a superset of what any single invocation needs. `:depends`
  requires no special handling: dependency tasks are already entries in the
  tasks map.

- **Deterministic order.** Iterate tasks sorted by name (via `sort-by str` over
  the keys) so output and the accumulated result order are stable across runs.

- **Always report, even when nothing is new.** The existing
  `deps/print-installs!` is silent when all deps are already cached — wrong for
  an explicit command. `rite install` prints a summary in every case (see
  *Reporting*).

- **Clean error on fetch failure.** A git-clone failure currently surfaces as a
  raw stack trace at `:run` time (`git!` in `rite.deps` throws `ex-info`).
  `cmd-install!` wraps the fetch in `try/catch` and reports it cleanly. (An
  invalid *dependency* `lgx.edn` is already handled inside `ensure-all!` via
  `coords-at!`, which prints its report and exits 1 — that path is unchanged.)

- **`install` becomes a reserved task name** (added to
  `config/reserved-task-names`, like `tasks`). Pre-1.0 breaking edge: a project
  with a task literally named `install` will now get a config error naming the
  conflict. Acceptable at 0.1.0, and covered by the existing
  `load-rejects-reserved-task-names` test which iterates the set.

### Reporting

A **pure** helper `deps/install-report-lines` takes the raw concatenated results
and returns the summary as a vector of strings (so it is unit-testable, mirroring
how `print-installs!` is structured). It first **dedupes by `:path`**, preserving
first-occurrence order, treating a lib as newly installed if **any** occurrence
had `:installed? true` (only the first occurrence ever clones; the rest see it
cached). Then, over `total` deduped deps and `n` newly installed:

- `total == 0` → `["no dependencies to install"]`
- `n == 0` (all cached) → `["all N dep(s) already cached"]`
- otherwise →
  - `"installing N dep(s)..."` (matches the existing `print-installs!` header)
  - one `"  <lib> -> <path>"` line per newly installed dep
  - `"done: N installed, M already cached"` (where `M = total - n`)

`deps/print-install-report!` prints those lines to stdout; `cmd-install!` calls
it. Example:

```
$ rite install
installing 2 dep(s)...
  tiny-cli -> ~/.cache/rite/gitlibs/.../0.1.0
  shapelet -> ~/.cache/rite/gitlibs/.../v0.1.0
done: 2 installed, 0 already cached
```

### Discoverability surfaces

- **Help:** one aligned row in `help/command-rows`
  (`rite install   Install all task dependencies`).
- **Completion:** `"install"` added to `completion/builtin-commands`, so TAB
  offers it at the command position alongside `tasks`.
- **README:** a `## CLI` row and a one-line note in the `:deps` section.

### Error handling summary

- No project → `config/find-project!` exits 1 (standard message).
- Invalid `rite.edn` → `config/load-config!` exits 1 (standard report).
- Git fetch failure → `rite: install: <message>` to stderr, exit 1.
- No deps anywhere → `no dependencies to install`, exit 0.
- Idempotent: a second `rite install` re-reports every dep as already cached and
  clones nothing.

## File Structure

- **Modify** `src/rite/deps.lg` — add `install-all!` (I/O: `ensure-all!` per
  task, sorted, concatenated results), the pure `install-report-lines`, and
  `print-install-report!`. Reuses everything already in the module.
- **Modify** `main.lg` — require `[rite.deps :as deps]`; add `cmd-install!` and
  an `"install"` branch to `dispatch`.
- **Modify** `src/rite/config.lg` — add `"install"` to `reserved-task-names`.
- **Modify** `src/rite/help.lg` — add the `rite install` row to `command-rows`.
- **Modify** `src/rite/completion.lg` — add `"install"` to `builtin-commands`.
- **Modify** `test/rite/deps_test.lg` — tests for `install-all!` (seeded
  `file://` dep) and `install-report-lines` (all branches).
- **Modify** `test/rite/config_test.lg` — update the reserved-names set assertion.
- **Modify** `test/rite/help_test.lg` — assert the usage text includes
  `rite install`.
- **Modify** `test/rite/completion_test.lg` — update the three command-position
  candidate assertions to include `"install"`.
- **Modify** `tests/e2e.sh` — new Scenario 10 for `rite install`.
- **Modify** `README.md` — `## CLI` row + `:deps` note.

No `rite.plan`/`rite.tasks`/`rite.args` changes. rite has no `ARCHITECTURE.md`.

All commands run from the repo root (`/Users/andrew/Projects/rite`). Unit tests:
`lgx test` (baseline: **279 tests, 349 assertions, 0 failures**). Build the
binary: `lgx build` (→ `bin/rite`). Full build + unit + e2e: `bash tests/run.sh`
(also `lgx e2e`). Format/lint: `lgx fmt check`, `lgx lint`. Use the
/writing-clearly skill for all prose (docstrings, help, README).

## Implementation Steps

### Task 1: Core install logic in `rite.deps`

**Files:**
- Modify: `src/rite/deps.lg`
- Test: `test/rite/deps_test.lg`

- [ ] **Step 1: Write failing tests**
  In `test/rite/deps_test.lg`, add a section after the `ensure-all!` tests.
  - `install-report-lines` (pure — literal result vectors, no I/O):
    - `[]` → `["no dependencies to install"]`.
    - all cached, e.g. `[{:lib 'a :path "/p/a" :installed? false}
      {:lib 'b :path "/p/b" :installed? false}]` →
      `["all 2 dep(s) already cached"]`.
    - mixed, e.g. one `:installed? true`, one `false` → header
      `"installing 1 dep(s)..."`, a `"  a -> /p/a"` line for the installed one,
      and footer `"done: 1 installed, 1 already cached"`.
    - dedup: two entries with the **same `:path`** (one `:installed? true`, one
      `false`, as two tasks sharing a coord produce) collapse to one dep counted
      as installed — assert the total/among the lines it appears once.
  - `install-all!` (seeded `file://` dep, following the Scenario-6 /
    `make_bare_repo` style already used in this file's `ensure-all!` tests —
    pre-populate the cache dir so nothing clones, or seed a real bare repo; the
    existing `ensure-all!` tests pre-create `…/gitlibs/…/src` dirs and assert
    `:installed? false`, which is the simplest pattern to copy): given a
    `tasks-map` literal like
    `{'t1 {:deps {ex/a {:git/url "https://github.com/ex/a" :git/sha <sha-a>}}}
      't2 {:deps {ex/b {:git/url "https://github.com/ex/b" :git/sha <sha-b>}}}
      't3 {:do [{:sh "echo hi"}]}}`
    with the two cache dirs pre-created, `(deps/install-all! project tasks-map)`
    returns results whose `:lib` set is `#{ex/a ex/b}` (t3 contributes nothing),
    all `:installed? false`.

- [ ] **Step 2: Run tests to verify they fail**
  Run: `lgx test test/rite/deps_test.lg`
  Expected: FAIL (`install-all!`, `install-report-lines` undefined).

- [ ] **Step 3: Implement in `rite.deps`**
  Add to `src/rite/deps.lg` (in the public API section):
  - `install-all! [project tasks-map]` — over the tasks **sorted by name**
    (`sort-by str (keys tasks-map)`), for each task with a non-empty `:deps` call
    `(ensure-all! project (vec (:deps task)))`; concat the result vectors.
    Tasks without `:deps` contribute `[]`. Return a vector. Docstring: explains
    the per-task (non-merged) fetch and cache-level dedup (see Design).
  - `install-report-lines [results]` (pure) — dedup by `:path` preserving order
    (`:installed?` = true if any occurrence was), then branch per the Design's
    Reporting contract (three cases; exact strings above). No I/O.
  - `print-install-report! [results]` — `(doseq [l (install-report-lines
    results)] (println l))`.
  Keep the existing `print-installs!` (still used by `resolve-basis!`) unchanged.

- [ ] **Step 4: Run the deps suite, then the full unit suite**
  Run: `lgx test test/rite/deps_test.lg` then `lgx test`
  Expected: PASS (279 + new assertions, 0 failures).

- [ ] **Step 5: Commit**
  `git commit -m "feat: add install-all! and report helpers to rite.deps"`

### Task 2: `install` command — dispatch, handler, reserved name, help row

**Files:**
- Modify: `main.lg`, `src/rite/config.lg`, `src/rite/help.lg`
- Test: `test/rite/config_test.lg`, `test/rite/help_test.lg`

- [ ] **Step 1: Update the failing unit tests first**
  - `test/rite/config_test.lg` → `load-rejects-reserved-task-names`: change the
    set assertion to
    `(is (= #{"tasks" "completion" "__complete" "install"}
            config/reserved-task-names))`.
    (The `doseq` over the set auto-covers rejecting a task named `install`.)
  - `test/rite/help_test.lg` → `usage-has-synopsis-and-sections`: add
    `(is (str/includes? u "rite install"))`.

- [ ] **Step 2: Run tests to verify they fail**
  Run: `lgx test test/rite/config_test.lg test/rite/help_test.lg`
  Expected: FAIL (`install` not yet reserved / not in help).

- [ ] **Step 3: Implement the command**
  - `src/rite/config.lg`: add `"install"` to `reserved-task-names` (update its
    doc comment to mention the install command).
  - `src/rite/help.lg`: add a row to `command-rows`, aligned to `doc-col` (31),
    e.g. `"  rite install                 Install all task dependencies\n"`.
    Verify alignment against the existing rows (the description column must line
    up — count spaces to match `rite tasks`).
  - `main.lg`: require `[rite.deps :as deps]`; add a private `cmd-install!`:
    `find-project!` → `load-config!` → `(config/tasks cfg)` → wrap
    `(deps/install-all! project t)` in `try`, then
    `(deps/print-install-report! results)`; `catch e` → `(write! *err* (str
    "rite: install: " (ex-message e) "\n"))` and `(os/exit 1)`. Add the branch
    `"install" (cmd-install!)` to `dispatch`, before the task fall-through.

- [ ] **Step 4: Run the full unit suite**
  Run: `lgx test`
  Expected: PASS.

- [ ] **Step 5: Smoke-check the built binary**
  Run: `lgx build >/dev/null` then, from the repo root (rite is itself a rite
  project — `rite.edn` declares `fmt`/`lint`/`check`, none with `:deps`):
  - `./bin/rite install` → `no dependencies to install`, exit 0.
  - `./bin/rite --help | grep -c "rite install"` → `1`.
  - In a fresh temp dir with no `rite.edn`: `./bin/rite install; echo exit=$?` →
    the "no rite.edn" error and `exit=1`.

- [ ] **Step 6: Commit**
  `git commit -m "feat: add rite install command"`

### Task 3: Completion offers `install`

**Files:**
- Modify: `src/rite/completion.lg`
- Test: `test/rite/completion_test.lg`

- [ ] **Step 1: Update the failing tests**
  In `test/rite/completion_test.lg`, update the command-position expectations to
  include `"install"` (sorts between `foo/bar` and `lint`, before `tasks`):
  - `command-position-lists-builtins-and-tasks-sorted` →
    `["fmt" "foo/bar" "install" "lint" "tasks"]`.
  - `command-position-no-tasks-lists-builtin-only` → `["install" "tasks"]`.
  - `command-position-drops-shell-unsafe-task-name` → `["install" "safe" "tasks"]`.
  (`command-position-prefix-filters` "ta" stays `["tasks"]` — no change.)

- [ ] **Step 2: Run tests to verify they fail**
  Run: `lgx test test/rite/completion_test.lg`
  Expected: FAIL (candidates omit `install`).

- [ ] **Step 3: Implement**
  In `src/rite/completion.lg`, change `builtin-commands` to
  `["install" "tasks"]` (keep the comment naming `dispatch` in `main.lg` as the
  source of truth).

- [ ] **Step 4: Run the full unit suite + smoke-check `__complete`**
  Run: `lgx test` (PASS), then `lgx build >/dev/null` and, from the repo root:
  - `./bin/rite __complete ""` → includes `install`, `fmt`, `lint`, `check`,
    `tasks`.
  - `./bin/rite __complete inst` → `install`.

- [ ] **Step 5: Commit**
  `git commit -m "feat: complete the install built-in command"`

### Task 4: E2E Scenario 10

**Files:**
- Modify: `tests/e2e.sh`

- [ ] **Step 1: Add Scenario 10 after Scenario 9**
  Guard on `command -v git` like Scenario 6 (`skip` otherwise). Reuse
  `make_bare_repo` to seed a `file://` git dep, and the per-scenario
  `mktemp -d` project + `RITE_HOME` pattern. In a fixture `rite.edn` with a task
  carrying `:deps` pointing at the seeded bare repo (mirror Scenario 6's
  `{:git/url "file://$bare" :git/sha "$sha"}`) plus a plain `:sh`-only task:
  - `rite install` (first run) → contains `installing 1 dep(s)...` and
    `done: 1 installed`; assert the dep dir exists at
    `$home/gitlibs/_local/_/greet/$sha` (as Scenario 6 does).
  - `rite install` (second run) → contains `already cached` and
    `assert_not_contains … "installing"` (idempotent).
  - A project with **no** `:deps` anywhere → `rite install` contains
    `no dependencies to install` and exits 0 (use the `set +e`/`rc=$?`/`set -e`
    pattern for the exit code).
  - **Fetch failure is clean** (Codex advisory): a fixture whose task `:deps`
    points at a nonexistent bare repo (e.g. `file://$home/_fixtures/nope.git`
    that was never seeded — `git clone` fails, no network) → `rite install`
    contains `rite: install:` and exits 1 (capture with the
    `set +e`/`rc=$?`/`set -e` pattern; `assert_eq "$rc" 1`). This verifies the
    `cmd-install!` `try/catch` path.
  - `__complete ""` in the project lists `install` (`assert_contains`).
  Increment happens automatically via `pass`/`PASS_COUNT`.

- [ ] **Step 2: Run the full suite (build + unit + e2e)**
  Run: `bash tests/run.sh`
  Expected: all pass (unit + every e2e scenario including the new one).

- [ ] **Step 3: Commit**
  `git commit -m "test: e2e coverage for rite install (Scenario 10)"`

### Task 5: Documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a CLI row**
  In the `## CLI` code block, add a line (aligned with the block's other rows):
  `rite install             # fetch every task's :deps into the cache`.

- [ ] **Step 2: Note it in the `:deps` section**
  In the `#### :deps and :paths` section, add one sentence: deps are fetched
  lazily on the first `:run` step that needs them, and `rite install` pre-fetches
  every task's `:deps` into the cache up front (idempotent; useful for editor
  navigation, CI, and offline work). Use the /writing-clearly skill.

- [ ] **Step 3: Format check and final run**
  Run: `lgx fmt check` then `lgx test`
  Expected: both pass.

- [ ] **Step 4: Commit**
  `git commit -m "docs: document rite install"`

---

## Notes for the executor

- **Do not merge tasks' `:deps` into one `ensure-all!` call.** Per-task
  resolution is deliberate (see Design → Key decisions); merging would drop
  differing pins of the same lib across tasks.
- **Keep `print-installs!`** — it is still used by `script/resolve-basis!` for
  lazy `:run`-time fetches. The new `print-install-report!` is separate.
- `reserved-task-names`, `builtin-commands`, and the `dispatch` `case` in
  `main.lg` must stay in sync — `install` goes in all three.
- The three existing completion candidate assertions and the two config/help
  assertions **will** fail until updated; that's expected and handled in Tasks 2
  and 3 (update the test first, watch it fail, then implement).
- `install-report-lines` is the shared contract between Task 1's implementation
  and its test — match the exact strings in the Design's Reporting section.
