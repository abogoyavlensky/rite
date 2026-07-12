# Minimize Built-in Commands Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce rite's word-commands to just `rite tasks` by moving `rite version` to `rite -v/--version` and `rite help` to `rite -h/--help` (both flags already exist), then align validation, help text, tests, and docs.

**Tech Stack:** let-go (`.lg`) source bundled via `lgx`; bash e2e harness.

---

## Design

### Background

rite's CLI is dispatched in `src/rite/main.lg` by the `dispatch` function on the
first positional token. Today it recognizes these built-ins:

```clojure
(case cmd
  nil        (print-usage!)
  "help"     (print-usage!)
  "-h"       (print-usage!)
  "--help"   (print-usage!)
  "tasks"    (cmd-tasks!)
  "version"  (cmd-version!)
  "-v"       (cmd-version!)
  "--version" (cmd-version!)
  (run-task-cmd! cmd rest-args verbose?))
```

The `-h`/`--help`/`-v`/`--version` **flags already work** — they are matched as
the leading positional token (`parse-leading-flags` only consumes `--verbose`,
never these). So the change is primarily **removing** the bare-word `"help"` and
`"version"` cases, leaving `tasks` as the only word-command.

### Approach

`dispatch` becomes:

```clojure
(case cmd
  nil         (print-usage!)
  "-h"        (print-usage!)
  "--help"    (print-usage!)
  "-v"        (cmd-version!)
  "--version" (cmd-version!)
  "tasks"     (cmd-tasks!)
  (run-task-cmd! cmd rest-args verbose?))
```

Bare `rite` still prints usage. `rite help` and `rite version` now fall through
to task lookup — they can be a user's own task, or produce the standard
unknown-task error.

### Key decisions

- **Free `help` and `version` as task names.** `config/reserved-task-names`
  shrinks from `#{"help" "version" "tasks" "completion" "__complete"}` to
  `#{"tasks" "completion" "__complete"}`. They are no longer commands, so
  reserving them would be confusing, and a user can now legitimately define a
  `version` or `help` task. This changes validation: a `rite.edn` with such a
  task, previously rejected, now loads. (`completion`/`__complete` stay reserved
  for a future shell-completion command.)
- **`-v` stays version, not verbose** — unchanged from today; `--verbose` is the
  verbose flag and is untouched.
- **Flags move to the Options section of the help text**, keeping Commands to
  just `rite <task>` and `rite tasks`.
- **Unknown-task message** updates: `See 'rite help'.` → `See 'rite --help'.`

### Help layout (target)

```
Commands:
  rite <task> [args...]        Run a task
  rite tasks                   List available tasks

Options:
  -h, --help                   Show this help
  -v, --version                Print version
  --verbose                    Print resolved :run invocations and env before running
```

### Testing strategy

- Unit tests (`lgx test`) cover `config/reserved-task-names` (config_test) and
  the usage/help rendering (help_test).
- `main.lg`'s `dispatch` cannot be unit-tested (requiring `rite.main` runs
  `main`); it is covered by the bash e2e suite (`tests/e2e.sh`).
- Each task keeps the full suite green at its commit boundary. The two changes
  that alter e2e-observable behavior — freeing `version` and dropping the
  `help`/`version` word-commands — carry their e2e edits in the same task.

## File Structure

- `src/rite/main.lg` — `dispatch` (drop two cases), `unknown-task!` message.
- `src/rite/config.lg` — `reserved-task-names` set + its comment (lines ~34-36).
- `src/rite/help.lg` — `command-rows` / `option-rows` (lines ~15-22).
- `test/rite/config_test.lg` — `reserved-task-names` equality assertion (~line 221).
- `test/rite/help_test.lg` — `usage-has-synopsis-and-sections` assertions (~lines 85-86).
- `tests/e2e.sh` — `rite help`→`rite --help` (~lines 88, 102); reserved-name
  scenario `version`→`tasks` (~line 296); new version/help flag smoke.
- `README.md` — CLI block (~lines 255-262); reserved-names sentence (~lines 120-122).

---

### Task 1: Free `help` / `version` as task names

**Files:**
- Modify: `src/rite/config.lg`
- Modify: `tests/e2e.sh`
- Test: `test/rite/config_test.lg`

- [ ] **Step 1: Update the reserved-names unit assertion**
  In `test/rite/config_test.lg`, in `load-rejects-reserved-task-names` (~line 221),
  change the equality check from `#{"help" "version" "tasks" "completion" "__complete"}`
  to `#{"tasks" "completion" "__complete"}`. Leave the `doseq` loop as-is — it
  iterates `config/reserved-task-names`, so it adapts automatically.

- [ ] **Step 2: Run unit tests to verify the assertion fails**
  Run: `lgx test`
  Expected: FAIL in `load-rejects-reserved-task-names` (set mismatch).

- [ ] **Step 3: Shrink the reserved set**
  In `src/rite/config.lg` (~lines 34-36), change `reserved-task-names` to
  `#{"tasks" "completion" "__complete"}`. Update the preceding comment so it no
  longer implies `help`/`version` are commands (keep the note that
  `completion`/`__complete` are reserved for a future shell-completion command).

- [ ] **Step 4: Keep the e2e reserved-name scenario valid**
  In `tests/e2e.sh` (~line 296), the reserved-name scenario defines a task named
  `version` and expects `"conflicts with built-in command"`. Change that task
  name to `tasks` (still reserved) so the scenario still asserts rejection:
  `echo '{:tasks {tasks {:do [{:sh "echo hi"}]}}}' > "$proj/rite.edn"`.
  Update the assertion label if it names `version`.

- [ ] **Step 5: Run the full suite**
  Run: `bash tests/run.sh`
  Expected: PASS (`All tests passed.`).

- [ ] **Step 6: Commit**
  `git commit -am "feat: free help and version as task names"`

### Task 2: Reshape usage / help text

**Files:**
- Modify: `src/rite/help.lg`
- Test: `test/rite/help_test.lg`

- [ ] **Step 1: Update the usage-rendering assertions**
  In `test/rite/help_test.lg`, in `usage-has-synopsis-and-sections` (~lines 85-86),
  replace the `"rite version"` and `"rite help"` substring checks with checks for
  the new Options entries, e.g. `(is (str/includes? u "--help"))` and
  `(is (str/includes? u "--version"))`. Keep the existing `"Commands:"`,
  `"rite <task> [args...]"`, `"rite tasks"`, `"Options:"`, and `"--verbose"` checks.

- [ ] **Step 2: Run unit tests to verify failure**
  Run: `lgx test`
  Expected: FAIL in `usage-has-synopsis-and-sections` (missing `--help`/`--version`).

- [ ] **Step 3: Rework the help rows**
  In `src/rite/help.lg`, keep only the two command rows in `command-rows` and move
  the flags into `option-rows`, aligned to the existing `doc-col` (31). Exact
  strings (match the alignment precisely):

  ```clojure
  (def ^:private command-rows
    (str "  rite <task> [args...]        Run a task\n"
         "  rite tasks                   List available tasks\n"))

  (def ^:private option-rows
    (str "  -h, --help                   Show this help\n"
         "  -v, --version                Print version\n"
         "  --verbose                    Print resolved :run invocations and env before running\n"))
  ```

- [ ] **Step 4: Run unit tests to verify they pass**
  Run: `lgx test`
  Expected: PASS.

- [ ] **Step 5: Commit**
  `git commit -am "refactor: present -h/-v as options in help text"`

### Task 3: Slim dispatch, fix message, extend e2e

**Files:**
- Modify: `src/rite/main.lg`
- Modify: `tests/e2e.sh`

- [ ] **Step 1: Remove the word-command cases**
  In `src/rite/main.lg` `dispatch` (~lines 66-76), delete the `"help"` and
  `"version"` cases, leaving `nil`, `"-h"`, `"--help"`, `"-v"`, `"--version"`,
  `"tasks"`, and the default `run-task-cmd!`.

- [ ] **Step 2: Update the unknown-task message**
  In `unknown-task!` (~line 34), change `See 'rite help'.` to `See 'rite --help'.`

- [ ] **Step 3: Point the help e2e calls at the flag**
  In `tests/e2e.sh`, change the two `"$RITE" help` invocations (~lines 88 and 102)
  to `"$RITE" --help`. The surrounding assertions (synopsis, `Usage:`,
  `rite tasks`, `Tasks:`, task rows) stay the same.

- [ ] **Step 4: Add flag + fall-through smoke assertions**
  In `tests/e2e.sh` (near the existing usage scenario), add assertions that:
  - `rite --version` prints `rite <version>` — compare against
    `rite $(cat "$ROOT/resources/VERSION")` or assert the output starts with
    `rite ` and contains the VERSION contents (mirror how `$RITE`/`$ROOT` are
    already referenced in the file).
  - `rite -v` produces the same output as `rite --version`.
  - bare-word `rite version` now errors: exit code 1 and output contains
    `is not a task` (fall-through to unknown-task). Use the `set +e; ...; rc=$?;
    set -e` pattern already used elsewhere in the file.

- [ ] **Step 5: Run the full suite**
  Run: `bash tests/run.sh`
  Expected: PASS (`All tests passed.`).

- [ ] **Step 6: Commit**
  `git commit -am "feat: drop help/version word-commands, keep only flags"`

### Task 4: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the CLI block**
  In `README.md` (~lines 255-262), drop the `rite help` and `rite version`
  word-command lines and present the flags instead, e.g.:
  ```
  rite                     # usage and task list
  rite -h | --help         # show this help
  rite -v | --version      # print the version
  rite tasks               # just the task list
  rite <task> [args...]    # run a task
  rite --verbose <task>    # also print the resolved :run invocation and env
  ```

- [ ] **Step 2: Update the reserved-names sentence**
  In `README.md` (~lines 120-122), change the reserved list from
  `` `help`, `version`, `tasks`, `completion`, `__complete` `` to
  `` `tasks`, `completion`, `__complete` `` and reword so it no longer calls
  `help`/`version` built-in commands.

- [ ] **Step 3: Confirm nothing regressed**
  Run: `bash tests/run.sh`
  Expected: PASS (`All tests passed.`).

- [ ] **Step 4: Commit**
  `git commit -am "docs: minimize built-in commands to rite tasks"`
