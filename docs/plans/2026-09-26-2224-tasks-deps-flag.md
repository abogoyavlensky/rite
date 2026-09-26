# `rite tasks --deps` Implementation Plan

**Status: complete** (2026-09-26)

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `rite install` built-in with `rite tasks --deps`, so `tasks` is the only word command and `install` is free as a user task name.

**Tech Stack:** let-go (`.lg`) bundled via lgx; `lgx test` unit tests; bash e2e harness (`tests/e2e.sh`, run by `tests/run.sh`).

---

## Design

### Background

`main.lg` (repo root) dispatches on the first positional token. The word commands are `tasks` (list tasks), `install` (fetch every task's `:deps` into the gitlibs cache), plus the hidden `completion` and `__complete`. Each word command is reserved in `config/reserved-task-names`, so a project can't define a task with that name. The aim is for users to name their tasks freely, so `install` should not be a built-in.

### Approach

`install` becomes a flag on `tasks`:

- `rite tasks` lists the visible tasks, as it does today.
- `rite tasks --deps` does what `rite install` did, with the same output and exit codes.
- Anything else after `tasks` (`rite tasks foo`, `rite tasks --bogus`, `rite tasks --deps extra`) prints `rite: tasks: unknown argument '<first bad token>'. See 'rite --help'.` to stderr and exits 1. Today `rite tasks` silently ignores trailing args.

The `"install"` case is removed from `dispatch`, so `rite install` falls through to task lookup like any other name. It runs a user's `install` task if one exists, and otherwise prints the standard unknown-task error. There is no migration hint.

### Key decisions

- **Pure arg parser in `rite.cli`.** `main.lg` can't be required from tests because loading it runs `(main)`, so the parsing lives next to `parse-leading-flags`:

  ```clojure
  (defn parse-tasks-args [args] ...)
  ;; []           -> {:mode :list}
  ;; ["--deps"]   -> {:mode :deps}
  ;; anything else -> {:error "unknown argument '<first token that isn't a lone leading --deps>'"}
  ```

  Only these three exact inputs matter. For `["--deps" "x"]` the bad token is `"x"`, and for `["foo"]` it is `"foo"`.
- **Parse before loading the project.** `cmd-tasks!` in `main.lg` takes `rest-args`, parses them first, and on `:error` writes `rite: tasks: <error>. See 'rite --help'.` and exits 1. It does this before `find-project!`, so a typo gets the right message even outside a project. `:list` runs the current listing body. `:deps` runs the current `cmd-install!` body, which becomes a private fn such as `cmd-fetch-deps!`. Its git-failure error prefix changes from `rite: install: ` to `rite: tasks --deps: `.
- **Reserved names shrink** to `#{"tasks" "completion" "__complete"}`. `completion` and `__complete` stay as they are, by choice.
- **Completion builtins** become `["tasks"]`. rite never completes flags (a `cur` starting with `-` yields `[]`), so `--deps` is not offered. That matches how the other flags behave.
- **Internal names stay.** `deps/install-all!`, `install-report-lines`, `print-install-report!` and the `installing N dep(s)...` output keep their names. Only the user-facing command changes. The `deps.lg` section comment is updated to name `rite tasks --deps`.

### Help (target Commands section)

```
Commands:
  rite <task> [args...]        Run a task
  rite tasks                   List available tasks
  rite tasks --deps            Fetch every task's :deps into the cache
```

The rows are hand-aligned to `doc-col` 31 in `src/rite/help.lg`. `"  rite tasks --deps"` is 19 characters, so it gets 12 spaces of padding.

### Testing

- Unit tests (`lgx test`): `parse-tasks-args` cases in `test/rite/cli_test.lg`; the reserved-name set in `config_test.lg`, plus a test that a task named `install` now loads; the help row in `help_test.lg`; builtin candidates in `completion_test.lg`.
- E2E (`tests/e2e.sh`): Scenario 10 switches from `install` to `tasks --deps`, and the no-deps and fetch-failure checks do the same. New checks:
  - a user task named `install` runs via `rite install`;
  - `rite install` without such a task gives the unknown-task error with exit 1;
  - `rite tasks bogus` exits 1 with the unknown-argument message, both inside and outside a project.

  The completion expectations drop `install`.
- Full suite: `bash tests/run.sh`, which builds the bundle and runs the unit and e2e tests.

## File Structure

| File | Change |
| --- | --- |
| `src/rite/cli.lg` | Add `parse-tasks-args` |
| `test/rite/cli_test.lg` | Tests for `parse-tasks-args` |
| `main.lg` | `tasks` handles `--deps` through the parser; drop the `install` case and `cmd-install!` |
| `src/rite/config.lg` | Drop `install` from `reserved-task-names` and its comment |
| `test/rite/config_test.lg` | Update the reserved set assertion; add a test that an `install` task loads |
| `src/rite/help.lg` | Replace the `rite install` row with the `rite tasks --deps` row |
| `test/rite/help_test.lg` | Assert on `rite tasks --deps`, and assert `rite install` is absent |
| `src/rite/completion.lg` | `builtin-commands` becomes `["tasks"]`; fix comments that mention install |
| `test/rite/completion_test.lg` | Drop `install` from the expected candidates |
| `src/rite/deps.lg` | Section comment names `rite tasks --deps` |
| `tests/e2e.sh` | Scenario 10, the no-deps check, the completion scenario, and the new checks |
| `README.md` | CLI table, `:deps` paragraph, reserved-names paragraph |

## Tasks

### Task 1: `parse-tasks-args` in `rite.cli`

**Files:**
- Modify: `src/rite/cli.lg`
- Test: `test/rite/cli_test.lg`

- [x] **Step 1: Write failing tests** in `test/rite/cli_test.lg`, under a new section header matching the existing style:
  - `[]` → `{:mode :list}`
  - `["--deps"]` → `{:mode :deps}`
  - `["foo"]` → `{:error "unknown argument 'foo'"}`
  - `["--bogus"]` → `{:error "unknown argument '--bogus'"}`
  - `["--deps" "x"]` → `{:error "unknown argument 'x'"}`
- [x] **Step 2: Run** `lgx test` and confirm the new tests fail because `parse-tasks-args` is unresolved.
- [x] **Step 3: Implement** `parse-tasks-args` in `src/rite/cli.lg` with a docstring in the same style as `parse-leading-flags`. Accept `args` as any seqable (callers pass a vector).
- [x] **Step 4: Run** `lgx test`. Expected: all pass.
- [x] **Step 5: Commit** `git commit -am "feat: parse rite tasks arguments"`

### Task 2: Wire `rite tasks --deps` and remove the `install` command

**Files:**
- Modify: `main.lg`, `src/rite/config.lg`, `src/rite/completion.lg`, `src/rite/help.lg`, `src/rite/deps.lg`
- Test: `test/rite/config_test.lg`, `test/rite/help_test.lg`, `test/rite/completion_test.lg`

- [x] **Step 1: Update unit tests first.**
  - `config_test.lg`: the reserved set becomes `#{"tasks" "completion" "__complete"}`. Add `load-accepts-install-task-name`, which checks that `(load-cfg {:tasks {'install {:do [{:sh "echo hi"}]}}})` has no `:errors`. Follow how nearby tests assert a successful load.
  - `help_test.lg`: in `usage-has-synopsis-and-sections`, replace `"rite install"` with `"rite tasks --deps"`, and add `(is (not (str/includes? u "rite install")))`.
  - `completion_test.lg`: remove `"install"` from the expected vectors on lines 27, 31 and 48, and update the comments on lines 25 and 46.
- [x] **Step 2: Run** `lgx test` and confirm these tests fail.
- [x] **Step 3: Implement.**
  - `src/rite/config.lg`: remove `"install"` from `reserved-task-names` and from the comment above it.
  - `src/rite/completion.lg`: `(def builtin-commands ["tasks"])`, and fix the comments that name install.
  - `src/rite/help.lg`: replace the install row with `"  rite tasks --deps            Fetch every task's :deps into the cache\n"`. Check the description starts at column 31, like the rows above it.
  - `src/rite/deps.lg`: change the section comment `install command: fetch every task's :deps up front` to name `rite tasks --deps`.
  - `main.lg`: rename `cmd-install!` to `cmd-fetch-deps!` and change its error prefix to `rite: tasks --deps: `. `cmd-tasks!` takes `rest-args` and calls `cli/parse-tasks-args` first. On `:error` it writes `rite: tasks: <error>. See 'rite --help'.\n` to `*err*` and runs `(os/exit 1)`. On `:deps` it calls `cmd-fetch-deps!`. On `:list` it runs the existing listing body. In `dispatch`, change the tasks case to `"tasks" (cmd-tasks! rest-args)` and delete the `"install"` case.
- [x] **Step 4: Run** `lgx test`. Expected: all pass.
- [x] **Step 5: Commit** `git commit -am "feat: replace rite install with rite tasks --deps"`

### Task 3: E2E coverage

**Files:**
- Modify: `tests/e2e.sh`

- [x] **Step 1: Update Scenario 10.**
  - Retitle it `rite tasks --deps fetches every task's :deps`.
  - Replace both `"$RITE" install` calls with `"$RITE" tasks --deps`.
  - Change the assertion labels from `install:` to `tasks --deps:`.
  - Replace the check that completion offers `install` with a check that `__complete ""` does **not** contain `install`. The project has no `install` task, so this holds.
  - Do the same rename in the no-deps block after it.
  - Do the same in the fetch-failure block (around line 511): invoke `"$RITE" tasks --deps`, expect the prefix `rite: tasks --deps:` in place of `rite: install:`, and relabel the assertions and the `skip` message.
- [x] **Step 2: Update the completion scenario (Scenario 9).** The invalid-config expectation `$'install\ntasks'` becomes `tasks`. Fix the comment above it if needed.
- [x] **Step 3: Add checks**, either at the end of Scenario 10 or as a small new block in the same style, using `mktemp -d` dirs:
  - A `rite.edn` with `{:tasks {install {:do [{:sh "echo user-install"}]}}}`: `rite install` exits 0, and its output contains `user-install`.
  - A project without an `install` task: `rite install` exits 1, and its output contains `is not a task`.
  - `rite tasks bogus` exits 1, and its output contains `unknown argument 'bogus'`.
  - Run `rite tasks bogus` again in an empty `mktemp -d` dir that has no `rite.edn`. It should still exit 1 with `unknown argument 'bogus'`, and not the no-project error. This shows the arguments are checked before project lookup.
- [x] **Step 4: Run** `bash tests/run.sh`. Expected: `All tests passed.`
- [x] **Step 5: Commit** `git commit -am "test: cover rite tasks --deps and a user install task"`

### Task 4: README

**Files:**
- Modify: `README.md`

- [x] **Step 1: Update the docs.**
  - CLI table (around line 293): replace the `rite install` line with `rite tasks --deps        # fetch every task's :deps into the cache`, and keep the `#` comments aligned.
  - `:deps` paragraph (around line 244): change `run \`rite install\`` to `run \`rite tasks --deps\``.
  - Reserved-names paragraph (around line 113): it already omits `install`, so leave it alone unless it now reads wrong. Grep the README for `install` and check that no other command reference is left. The `brew install`/`mise install` lines stay.
- [x] **Step 2: Grep for leftovers** with `grep -rn "rite install" src test tests README.md main.lg`. Expected: only the new e2e checks and the help test's absence assertion.
- [x] **Step 3: Commit** `git commit -am "docs: document rite tasks --deps"`

### Task 5: Mark the plan complete

- [x] **Step 1:** Add `**Status: complete** (<date>)` under this plan's title, then `git commit -am "docs: mark tasks --deps plan complete"`.

## Summary

`rite install` is gone. `rite tasks --deps` fetches every task's `:deps` with the same output. `rite tasks` rejects any other argument, and it does so before looking for `rite.edn`. `install` is now a free task name. The argument parsing is the pure `cli/parse-tasks-args`. In `main.lg`, `cmd-tasks!` dispatches to `cmd-list-tasks!` or `cmd-fetch-deps!`. The help text, completion builtins, reserved names, README and e2e tests are all updated. Unit tests: 328 tests, 0 failures. `bash tests/run.sh`: all passed.

Issues: none. The codex review of Task 2 flagged the stale e2e tests, which Task 3 already covered. The other reviews were clean.

Deviations: none. The listing body moved into its own `cmd-list-tasks!`, which is within what the plan described.

What the plan could have specified better: nothing significant. The fetch-failure e2e block was missed at first and caught by the pre-execution plan review.
