# Private Tasks (`:private? true`) Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `:private? true` task flag to `rite.edn` that hides a task from all discovery surfaces (`--help` Tasks block, `rite tasks`, and TAB-completion) while leaving it fully runnable directly and as a `:depends` target.

**Tech Stack:** let-go (`.lg`) source bundled via `lgx`; shapelet config schema; bash e2e harness.

---

## Design

### Goal

A task marked `:private? true` is hidden from discovery but stays fully functional — runnable directly (`rite <name>`) and usable as a dependency (`:depends [helper]`). This is the standard "hidden helper task" pattern (like `just`'s `[private]`).

### Approach

The three places that *list* tasks all pull from `config/tasks`:

- `help/tasks-block` — the `--help` Tasks block
- `main/cmd-tasks!` — `rite tasks`
- `completion/project-tasks` — TAB-completion candidates

Rather than teach each renderer about `:private?`, add one config helper, `config/visible-tasks`, that returns the tasks map minus private ones, and route all three listing sites through it. The definition of "private" then lives next to the schema, and the change is DRY across call sites.

Execution and `:depends` resolution keep using the full `config/tasks` map (`main/run-task-cmd!` → `run-task!` → `plan/build-plan`), so private tasks stay runnable and remain valid dependency targets with **zero changes to `plan.lg` / `tasks.lg`**. `:private?` is a pure passthrough key for execution.

### Key decisions

1. **One `config/visible-tasks` helper, not per-renderer filtering.** Keeps the "what counts as private" definition next to the schema and DRY across the three listing sites.

2. **Completion hides private tasks too** (approved). The completion command-position list is effectively a live `rite tasks`, so private tasks are not suggested there; because `project-tasks` drops them from the map entirely, their enum args also stop completing. Fully invisible to completion.

3. **Validated as a real boolean.** rite's config is strict/closed, so `:private?` gets a small `[:fn]` predicate requiring `true`/`false` — shapelet has no `:boolean` leaf schema (only `:string :keyword :symbol :map :vector :any`). `:private? false` behaves exactly like omitting the key. Added as the **last** task key so the closed-map "allowed keys" error message just gains `:private?` at the end.

4. **`rite tasks` with only private tasks** keeps the existing `"no tasks defined in rite.edn"` message (the visible set is empty). Minor imprecision for an unusual config; not worth a special-case message.

### What does not change

`plan.lg` and `tasks.lg`. Direct runs and `:depends` resolve against the full task map, untouched.

### Testing strategy

- **Unit** (`lgx test`): config accepts `:private? true`/`false`, rejects a non-boolean, and the closed-map allowed-keys message includes `:private?`; `config/visible-tasks` drops private tasks; `help/tasks-block` omits private tasks (exercises the `visible-tasks` routing).
- **e2e** (`bash tests/e2e.sh`, after `lgx build`): Scenario 1 gains a private task in the fixture — absent from `--help` and `rite tasks`, still runs directly and as a dependency; Scenario 9 asserts a private task is not offered by `__complete` at the command position.

Completion's pure `candidates` fn takes an already-filtered `tasks` map, so the "hide from completion" behavior lives in the I/O `project-tasks` reader and is covered by e2e rather than a unit test.

---

## File Structure

- **`src/rite/config.lg`** (modify) — add a `private-errors` predicate, add `[:private? {:optional true} [:fn private-errors]]` to `task-schema` (last key), and add a `visible-tasks` helper next to `tasks`.
- **`src/rite/help.lg`** (modify) — `tasks-block` reads `config/visible-tasks` instead of `config/tasks`.
- **`main.lg`** (modify) — `cmd-tasks!` reads `config/visible-tasks` instead of `config/tasks`.
- **`src/rite/completion.lg`** (modify) — `project-tasks` reads `config/visible-tasks` instead of `config/tasks`; refresh the ns comment that says candidates come from all tasks.
- **`test/rite/config_test.lg`** (modify) — new schema tests, updated allowed-keys message, `visible-tasks` tests.
- **`test/rite/help_test.lg`** (modify) — `tasks-block` omits private.
- **`tests/e2e.sh`** (modify) — Scenario 1 + Scenario 9 assertions.
- **`README.md`** (modify) — task-keys list + a `#### :private?` subsection.

### Shared shapes (tasks must agree exactly)

The schema predicate and entry:

```clojure
(defn- private-errors
  "A task's :private? — a boolean. true hides the task from listings and
   completion; false (or absent) is visible."
  [v]
  (when-not (boolean? v)
    (str "must be true or false, got " (pr-str v))))
```

Added as the final entry of the `[:map {:closed true} ...]` inside `task-schema`:

```clojure
[:private? {:optional true} [:fn private-errors]]
```

The helper (placed beside `tasks` / `vars` at the bottom of `config.lg`):

```clojure
(defn visible-tasks
  "The :tasks map minus tasks flagged :private? true — the discovery-visible
   subset shown in help, `rite tasks`, and completion. Private tasks stay
   runnable and remain valid :depends targets; only listing is affected."
  [cfg]
  (into {} (remove (fn [[_ t]] (:private? t)) (tasks cfg))))
```

Resulting closed-map error message (task keys in schema order, `:private?` last):

```
unknown key :extra-deps (allowed: :doc, :args, :do, :depends, :deps, :paths, :private?)
```

---

## Task 1: Config schema + `visible-tasks` helper

**Files:**
- Modify: `src/rite/config.lg`
- Test: `test/rite/config_test.lg`

- [x] **Step 1: Write failing tests**
  In `config_test.lg` add:
  - accepts `:private? true` and `:private? false` (load succeeds, `:cfg` present) on an otherwise valid task.
  - rejects a non-boolean: `{'fmt {:private? "yes" :do [{:sh "echo hi"}]}}` → `{:errors [{:path [:tasks 'fmt :private?] :msg "must be true or false, got \"yes\""}]}`.
  - `config/visible-tasks` drops private tasks: given a cfg with a visible `fmt` and a private `secret {:private? true ...}`, returns only `fmt`; a cfg of only private tasks returns `{}`; passthrough of a cfg with no `:tasks` returns `{}`.
  Also update `load-rejects-task-with-unknown-key` (currently around line 209) so its expected message ends with `:paths, :private?)` — see the shared "Resulting closed-map error message" above.

- [x] **Step 2: Run tests to verify they fail**
  Run: `lgx test`
  Expected: FAIL — the new `:private?` cases error on the closed-map (unknown key `:private?`), `visible-tasks` is unresolved, and the updated allowed-keys assertion mismatches.

- [x] **Step 3: Implement**
  In `config.lg`: add the `private-errors` predicate (see shared shape) near the other task-level `[:fn]` predicates; add `[:private? {:optional true} [:fn private-errors]]` as the **last** entry of `task-schema`'s closed map; add the `visible-tasks` helper (see shared shape) beside `tasks`/`vars`.

- [x] **Step 4: Run tests to verify they pass**
  Run: `lgx test`
  Expected: PASS

- [x] **Step 5: Commit**
  `git commit -am "feat: add :private? task flag to config schema"`

## Task 2: Route listing surfaces through `visible-tasks`

**Files:**
- Modify: `src/rite/help.lg`, `main.lg`, `src/rite/completion.lg`
- Test: `test/rite/help_test.lg`

- [x] **Step 1: Write failing test**
  In `help_test.lg` add a `tasks-block` test: given `{:cfg {:tasks {'fmt {:doc "Format" :do [{:sh "f"}]} 'secret {:private? true :do [{:sh "s"}]}}}}`, the rendered block includes `rite fmt` but not `secret`.

- [x] **Step 2: Run test to verify it fails**
  Run: `lgx test`
  Expected: FAIL — `tasks-block` still lists `secret` because it reads `config/tasks`.

- [x] **Step 3: Implement**
  - `help.lg` `tasks-block`: change `(config/tasks (:cfg loaded))` → `(config/visible-tasks (:cfg loaded))`.
  - `main.lg` `cmd-tasks!`: change `(config/tasks cfg)` → `(config/visible-tasks cfg)`.
  - `completion.lg` `project-tasks`: change `(config/tasks cfg)` → `(config/visible-tasks cfg)`; update the ns doc comment (top of file, "Candidates are offered at the command position (task names + ...)") to note private tasks are excluded.

- [x] **Step 4: Run tests to verify they pass**
  Run: `lgx test`
  Expected: PASS

- [x] **Step 5: Commit**
  `git commit -am "feat: hide :private? tasks from help, rite tasks, and completion"`

## Task 3: e2e coverage

**Files:**
- Modify: `tests/e2e.sh`

- [x] **Step 1: Extend Scenario 1 fixture and assertions**
  In the Scenario 1 project fixture (the `cat > "$proj/rite.edn"` block, ~line 129), add a private task, e.g.:
  ```edn
  {:tasks {fmt {:doc "Format sources" :do [{:sh "echo fmt"}]}
           deploy {:doc "Deploy" :args [{:name :env}] :do [{:sh "echo d"}]}
           secret {:doc "Hidden" :private? true :do [{:sh "echo secret-ran"}]}}}
  ```
  Then assert with the existing helpers:
  - `--help` output: `assert_not_contains "$out" "rite secret" "help: hides private task"`.
  - `rite tasks` output: `assert_not_contains "$out" "secret" "tasks: hides private task"`.
  - Private task still runs directly: `rite secret` exits 0 and prints `secret-ran` (`assert_contains`).
  Keep the existing `fmt`/`deploy` assertions intact.

- [x] **Step 2: Assert a private task still works as a dependency**
  Simplest placement is Scenario 5 (`:depends`). Give one dependent task a private dependency and assert the private dep's output appears when the parent runs. If wiring this into Scenario 5's fixture is awkward, instead extend the Scenario 1 fixture's `check`-style aggregate to depend on `secret` and assert `secret-ran` appears. Choose whichever keeps the fixture readable; a direct-run assertion (Step 1) plus one depends assertion is enough.
  > Deviation: kept both the direct-run and the depends assertion inside the Scenario 1 fixture (added a `top {:depends [secret]}` aggregate) rather than touching Scenario 5 — keeps all private-task behavior in one readable fixture.

- [x] **Step 3: Extend Scenario 9 (completion) assertions**
  Scenario 9 builds a completion fixture and calls `__complete`. Add a private task to that fixture and assert it is **not** among command-position candidates (empty `cur`): `assert_not_contains "$out" "secret" "completion: private task not offered"`. Mirror the existing `__complete` invocation style in that scenario.
  > Deviation: named the completion-fixture private task `hidden` (not `secret`) to avoid substring overlap with other candidates; asserted `assert_not_contains "$out" "hidden"`.

- [x] **Step 4: Build and run e2e**
  Run: `lgx build && bash tests/e2e.sh`
  Expected: all scenarios pass, including the new private-task assertions.

- [x] **Step 5: Commit**
  `git commit -am "test: e2e coverage for :private? tasks"`

## Task 4: Documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the task-keys sentence**
  In the "Tasks" section (~line 116), add `:private?` to the key list: "The keys are `:doc`, `:args`, `:do`, `:depends`, `:deps`, `:paths`, and `:private?`; any other key is an error."

- [ ] **Step 2: Add a `#### :private?` subsection**
  Place it after the `:deps` and `:paths` subsection. Cover: `:private? true` hides the task from `--help`, `rite tasks`, and TAB-completion; the task still runs directly (`rite <name>`) and stays a valid `:depends` target; `false` (or omitting the key) is the default. Use the /writing-clearly skill for the prose.

- [ ] **Step 3: Commit**
  `git commit -am "docs: document :private? task flag"`

## Task 5: Full-suite verification

- [ ] **Step 1: Run the whole suite**
  Run: `bash tests/run.sh`
  Expected: build succeeds, unit tests pass, e2e passes — "All tests passed."

- [ ] **Step 2: Lint/format check**
  Run: `cljfmt check src test main.lg && clj-kondo --lint src test main.lg`
  Expected: clean (fix and re-run if not). Only commit if this step changed files.
