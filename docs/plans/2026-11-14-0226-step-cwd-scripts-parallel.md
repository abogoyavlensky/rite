# Step `:cwd`, Readable Script Steps and `:parallel` Implementation Plan

**Status: completed (2026-11-14), except Task 9 Step 2: the macOS job has not run yet.**

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Three step-level features found while writing the kopi `rite.edn`: a per-step `:cwd`, readable multi-line `:sh` steps with a compact echo and a `:fail-on-output` check, and a `:parallel` step that runs long-lived processes together with prefixed output and a shared stop.

> Execution notes (2026-11-14): every `lgx` command ran as `mise exec -- lgx ...`, because the `lgx` 0.5.4 first on PATH cannot load this repo's test harness; the pinned 0.1.2 can. Before each commit `lgx fmt check` and `lgx lint` also ran, as CI's `lgx check` does. No session task-list tool was available, so this document is the only progress tracker.

**Tech Stack:** let-go (`.lg`), shapelet schemas (`rite.config`), POSIX `sh` (the `:parallel` supervisor), `lgx test` for unit tests, `tests/e2e.sh` against the built `bin/rite`, GitHub Actions.

---

## Design

### Where this came from

The kopi project (a Go server plus a Vite frontend in `web/`) needed this `rite.edn`, and three things hurt:

1. Task-level `:cwd` forced every task that touches both the root and `web/` into a public task plus private helpers: `deps` plus `deps-web`, `fmt` plus `fmt-web`, `lint` as an aggregate of `lint-go` and `lint-web`.
2. "Fail if this command prints anything" needed a one-line shell `if` full of escaped quotes. The step echo then printed that whole line.
3. `dev-api` and `dev-web` need two terminals, because rite cannot run two long-lived processes together.

With this plan, kopi's tasks can read:

```edn
deps {:do [{:sh "go mod download"}
           {:sh "npm ci" :cwd "web"}]}

gen-check {:depends [gen]
           :do [{:sh "git diff --exit-code -- {{var/genpaths}}"}
                {:sh "git ls-files --others --exclude-standard -- {{var/genpaths}}"
                 :fail-on-output true}]}

dev {:doc "Run the API and the Vite dev server together"
     :do {:parallel [{:task dev-api} {:task dev-web}]}}
```

### Part A: per-step `:cwd`

- `:cwd` is an optional key on `:sh` and `:run` steps. It is a directory relative to the project root, validated with the existing `rel-path-schema`, exactly like task-level `:cwd`.
- A step's `:cwd` replaces the task's effective cwd (its own `:cwd` or the inherited one) for that step only. The next step goes back to the task's cwd.
- It is rejected on a `:task` step: "`:cwd` is not allowed on a :task step; set :cwd on the called task". A called task's cwd is already defined (its own `:cwd`, otherwise the caller's), and a second override path would make that rule harder to state.
- Execution reuses the current mechanism: `with-cwd` for `:sh`, `cwd-argv` for `:run`. rite's own directory never changes.

### Part B: readable script steps

**Multi-line `:sh` strings already work.** EDN strings may contain newlines, and `sh -c` runs the whole script. The feature here is documentation plus a better echo:

- **Compact echo.** For a command with more than one non-blank line, the `$` line shows the first non-blank line followed by ` … (+N lines)`, where N counts the remaining non-blank lines. A single-line command is echoed unchanged; long single lines are not truncated, because hiding part of a real command would hurt more than the noise. `--verbose` still prints the full `+ sh -c ...` line.
- **`:fail-on-output true`** is an optional boolean on `:sh` steps only. It is rejected on `:run` and `:task` steps, and rejected when not a boolean. The step:
  1. runs through `os/sh` with the same env and cwd wrapper, so its output is **buffered**, not streamed;
  2. writes the captured stdout to `*out*` and stderr to `*err*` once it finishes;
  3. if the command exited non-zero, returns that code;
  4. otherwise, if stdout is non-blank, prints `=> step printed output; expected none` (purple, like other `=>` lines) and returns 1;
  5. otherwise returns 0.

  Only stdout counts, so a tool can still warn on stderr. The usual `=> Task <name> failed: step <n> exited with 1` line follows a failure. Buffering is acceptable because these are quick checks; streaming would need a let-go tee primitive, which is backlogged (`docs/backlog/fail-on-output-buffers.md`).

### Part C: `:parallel` steps

**Shape.** `{:parallel [child ...]}` is a new step action. Children run at the same time; each child is one of:

- `{:sh "<command>"}`, with optional `:cwd` (as in Part A) and `:label`;
- `{:task <entry>}`, with optional `:label`. The entry has the same shape and validation as a `:task` step: a symbol or `[task arg...]`.

A child cannot be `:run` or another `:parallel`; both are rejected at load time with a clear message. The vector needs at least one child. `:parallel` takes no `:cwd` or `:fail-on-output` itself.

**Labels.** Each output line is prefixed with `[label] `, padded so all labels line up. The default label is the task name for a `:task` child, and the first word of the expanded command, taken before any `cd` wrapper is added, for an `:sh` child (`go run ./cmd/kopi` gives `go`). An explicit `:label` (a non-blank string) is checked for duplicates at load time. Explicit labels are reserved first. Generated labels then take the first free name in `go`, `go-2`, `go-3`... order, so two default `go` labels next to an explicit `go-2` become `go` and `go-3`. When colour is enabled (`style/color-enabled?`), the label is purple; otherwise it is plain.

**Semantics.**

- Start every child, then wait for all of them.
- The first child to exit non-zero stops the rest. rite sends TERM to each remaining child's process tree, then prints `=> <label> exited with <code>; stopping the others`. The step returns that code, and the normal task failure line follows.
- A child that exits 0 does not stop the others. That covers both "build A and B at once" (finishes when both finish) and "run two dev servers" (runs until stopped).
- Ctrl-C (SIGINT) or SIGTERM stops every child. The step exits 130 for SIGINT and 143 for SIGTERM.
- Children get no stdin: background jobs in a non-interactive `sh` read `/dev/null`. Documented: a `:parallel` child cannot prompt.
- `:env`: the task's effective env is set around the supervisor process, as for any step, so every child inherits it.
- cwd: an `:sh` child uses its own `:cwd`, otherwise the task's effective cwd. A `:task` child runs as a subprocess from the project root, and its own `:cwd` applies inside that run.

**Why a subprocess for `:task` children.** In-process sub-plans run one after another; let-go has no portable way to run two of them concurrently and keep their streams apart. So a `:task` child becomes the shell command `cd <project> && exec <rite-exe> <task> <args...>`, every part shell-quoted. `<rite-exe>` comes from `script/resolve-exe`, the lookup `:run` already uses. Args are resolved against the caller's bindings exactly as for a `:task` step, and passed as positional CLI args. This means `rite` must run as the built bundle; in `lg main.lg` development mode a `:task` child is not supported (documented in the README's Development section).

**Mechanism: a POSIX `sh` supervisor.** let-go's process-group, kill and signal APIs (`syscall/spawn`, `syscall/kill`, `syscall/signal-notify`) exist only on Linux and are stubs elsewhere, and rite ships to macOS. So rite does not supervise the children itself. It builds one fixed supervisor script and runs it with `os/exec*` (streaming, like any step) as `sh -c <script> sh <label1> <cmd1> <label2> <cmd2> ...`. Labels and commands travel as positional parameters, never spliced into the script text, so no quoting is needed inside it. A spike on dash and bash (2026-11-14) confirmed every piece below, headless with no tty:

- `mkfifo` an events FIFO in a `mktemp -d` dir, and open it read-write on fd 3 so reads never see EOF.
- Per child, a background job: `{ sh -c "$cmd" & c=$!; echo "$c" > "$dir/<i>.pid"; echo "start <i>" > "$fifo"; wait "$c"; echo "exit <i> $?" > "$fifo"; } 2>&1 | awk -v p="<prefix>" '{print p $0; fflush()}' &`. The PID file records the real command, not the pipeline's last process (awk). `awk` with `fflush()` is the portable line-buffered prefixer; `sed -u` is GNU-only.
- **Startup barrier.** The supervisor first reads events until it has seen N distinct `start` events, one per child, before it handles any `exit` event. An `exit` event that arrives during the barrier (an early child failed before a later child started) is buffered, not dropped and not counted, and the buffered exits are processed in arrival order right after the barrier. Dropping one would make the supervisor wait forever; counting it would bring back the race. A child's `start` is written after its PID file and before its `exit`, so once the barrier passes every PID file exists. Without the barrier, a child that fails instantly could trigger the stop before a sibling records its PID, and that sibling would keep running. Signals that arrive during the barrier set a flag, and the stop runs as soon as the barrier completes.
- **Stop** first snapshots every recorded PID's full descendant set with a `pgrep -P` walk (present on Linux procps and macOS) into a list, then sends TERM to every PID in that list, bottom-up. If `pgrep` is missing, the list is just the direct PIDs. The stop is bounded: the supervisor waits up to 5 seconds, polling `kill -0` over the snapshot list once a second, then sends KILL to every PID in the list that is still alive. The snapshot is what makes the bound hold. A descendant that ignores TERM while its parent dies is re-parented to init, so a fresh tree walk after TERM could not find it, but the snapshot still holds its PID. `set -m` is not used: without a tty, dash cannot enable job control, the children then share rite's process group, and a group kill silently misses them.
- **Wait loop.** Read one event at a time, but read it in a background subshell and `wait` on that, because a trapped signal interrupts `wait` immediately while a blocked `read` defers the trap (measured: about 60 ms against a hang until the next child exits).
- **Phase-aware traps.** The INT and TERM traps call one handler with the exit code (130 or 143). During the startup barrier the handler only records that code in a variable; the barrier loop checks it after each event and, once all N `start` events are in, runs `stop; cleanup; exit <code>`. After the barrier the handler runs `stop; cleanup; exit <code>` immediately. That keeps the barrier's guarantee: no stop runs before every PID file exists. In a terminal, Ctrl-C reaches the whole foreground group (rite, supervisor, children), so this also works there.
- **Watchdog.** A background loop `while kill -0 "$PPID"; do sleep 1; done; kill -TERM $$`. If rite itself is killed alone (say `kill <rite pid>` from a script), the supervisor notices its parent is gone within a second and stops the children instead of orphaning them.
- On normal exit the supervisor stops its own helpers (reader, watchdog), removes the temp dir, and exits with the first failing code or 0.
- The killed children print sh's `Terminated` notice. The supervisor suppresses it with `2>/dev/null` on its `wait` calls.

The script lives as one string constant in `src/rite/parallel.lg`. It is the only non-trivial shell in rite, so it gets a comment block that explains each part.

**Echo and verbose.** The step prints `$ parallel: <label1>, <label2>, ...`, then one line per child: `  [<label>] $ <command>` (the compact form from Part B). `--verbose` adds `+ cd <dir>` for each child with a cwd, and the resolved `:task` subprocess command.

**Validation and cycles.** A `:task` child is checked by `depends-entry-ref-errors`, like a `:task` step: the callee exists, placeholders resolve, literal args fit. Cycle detection must count it as an edge. Without that, a `:parallel` child that calls its own task would fork rite processes until the machine runs out. `task-steps` (`config.lg`) is extended to walk into `:parallel` children, and plan building leaves them alone (no `:calls` entry).

**Platform reach.** The supervisor needs POSIX `sh`, `mkfifo`, `mktemp -d`, `awk` and `kill`, with `pgrep` optional. These are all standard on Linux and macOS; Windows was already out of reach, since every step runs through `sh`. CI today runs only on Ubuntu, so this plan adds a macOS job (Task 9). macOS `sh` is bash 3.2, which the spike did not cover.

### What this plan does not do

- No per-step `:env`; it was not asked for, and the backlog entry that introduced task-level `:env` already notes it can come later.
- No `:run` children in `:parallel`.
- No "stop all when any child exits 0" option; add it if a real config needs it.
- Escaping that escapes the process tree is backlogged: a child that daemonizes or `setsid`s itself out of its parent's tree cannot be stopped by a `pgrep -P` walk. Doing it properly needs a portable process-group primitive in let-go (`docs/backlog/parallel-process-groups.md`).

### Testing

- **Unit** (`lgx test`):
  - schema acceptance and rejection for step `:cwd`, `:fail-on-output` and `:parallel` (bad child types, duplicate labels, cycles through a `:parallel` child);
  - the pure helpers `display-command`, `parallel/labels`, `parallel/prefixes` and `parallel/task-child-command`.
- **E2E** (`tests/e2e.sh` against `bin/rite`):
  - a step `:cwd` prints the right `$PWD`, and the next step is back in the task's cwd;
  - `:fail-on-output` passes on silence, fails with code 1 on stdout, keeps a non-zero exit code, and ignores stderr;
  - a multi-line step echoes `… (+N lines)`;
  - `:parallel`:
    - two children's lines carry their prefixes;
    - a failing child stops a `sleep 30` sibling within a few seconds (time bound plus no leftover process);
    - a child that fails instantly (`exit 2`) still stops a slow sibling (the startup barrier);
    - a child that traps and ignores TERM is KILLed after the 5-second bound;
    - a TERM-ignoring grandchild whose parent dies on TERM (`sh -c '(trap "" TERM; exec sleep 34) & sleep 35'`) is still KILLed, from the snapshot;
    - the barrier with an instantly failing child listed first and several slower siblings;
    - `:task` children run;
    - SIGINT to the process group exits 130 with no leftovers;
    - SIGTERM to rite alone triggers the watchdog and leaves no leftovers.
  - **Process-group harness.** The SIGINT test needs rite in its own process group, which `setsid` would give, but macOS lacks it. The test instead starts rite as a background job under `set -m` in the bash test script. bash, unlike dash, enables job control without a tty, so the job gets its own group, and the test sends `kill -INT -- -<pgid>` to imitate Ctrl-C. Verify this works headless on Linux before relying on it.
- Every e2e leak check uses a duration unique to its scenario (`sleep 31`, `sleep 32` and so on), so it cannot match an unrelated process. It also uses a pattern that cannot match its own command line, such as `pgrep -f 'sleep 3[1]'`; a plain `pkill -f 'sleep 31'` matches the shell running it.

---

## File Structure

| File | Change |
|---|---|
| `src/rite/config.lg` | Step schema: `:cwd`, `:fail-on-output`, `:parallel` and child schema, label checks, `:task`-child refs, `task-steps` walks `:parallel` |
| `src/rite/plan.lg` | Make the `:task` arg resolver public so `:parallel` `:task` children reuse it |
| `src/rite/tasks.lg` | Step cwd resolution; `display-command`; `:fail-on-output` runner; dispatch to `parallel/run-parallel-step!` |
| `src/rite/parallel.lg` | New: supervisor script constant, labels, prefixes, child commands, `run-parallel-step!` |
| `src/rite/style.lg` | `output-failure-line`, `parallel-stop-line`, `label` colouring |
| `test/rite/config_test.lg` | Schema tests |
| `test/rite/tasks_test.lg` | `display-command` tests |
| `test/rite/parallel_test.lg` | New: labels, prefixes, task child command |
| `tests/e2e.sh` | Scenarios listed under Testing |
| `README.md` | Step `:cwd`, multi-line steps, `:fail-on-output`, `:parallel`, dev-mode note |
| `.github/workflows/checks.yml` | macOS job |

---

## Tasks

### Task 1: Step-level `:cwd` in the schema

**Files:**
- Modify: `src/rite/config.lg` (`step-schema`, about line 182)
- Test: `test/rite/config_test.lg`

- [x] **Step 1: Write the failing tests**
  Accepted: `{:sh "npm ci" :cwd "web"}`, `{:run "x.lg" :cwd "scripts"}`. Rejected, with the error path at the step's `:cwd`: an absolute path, a `..`-escaping path (whatever `rel-path-schema` already rejects), and `{:task fmt :cwd "web"}` with the message from the Design section.
- [x] **Step 2: Run them to see them fail**
  Run: `lgx test`
  Expected: the new cases FAIL.
- [x] **Step 3: Implement**
  Add `[:cwd {:optional true} rel-path-schema]` to the step map. Add a step-level `:fn` check that rejects `:cwd` together with `:task`.
- [x] **Step 4: Run the tests**
  Run: `lgx test`
  Expected: PASS.
- [x] **Step 5: Commit**
  `git commit -m "feat: accept :cwd on :sh and :run steps"`

> Deviation: the existing "unknown key ... (allowed: ...)" assertions in `config_test.lg` were updated to list `:cwd`; Tasks 4 and 5 did the same for `:fail-on-output` and `:parallel`.

### Task 2: Step-level `:cwd` at run time

**Files:**
- Modify: `src/rite/tasks.lg` (`run-steps!`)
- Test: `tests/e2e.sh`

- [x] **Step 1: Write the e2e scenario**
  A project with `sub/` and a task `{:cwd "." :do [{:sh "pwd"} {:sh "pwd" :cwd "sub"} {:sh "pwd"}]}`. Assert the three lines are root, `root/sub`, root. Run it from a nested directory too, to prove the path resolves against the project root, not the invocation dir. Add the same check for a `:run` step with `:cwd`.
- [x] **Step 2: Implement**
  In `run-steps!`, compute `step-cwd` as `(path/join project (:cwd step))` when the step has `:cwd`, else the task's `cwd`, and pass it to `run-step!`. Update the namespace comment that says `:cwd` is task-level.
- [x] **Step 3: Run the suite**
  Run: `bash tests/run.sh`
  Expected: PASS.
- [x] **Step 4: Commit**
  `git commit -m "feat: run a step from its own :cwd"`

> Deviation: the e2e expects the `:run` step's next step (no task `:cwd`) to run from the invocation directory, not the root. That is existing behaviour for a task without `:cwd`.

### Task 3: Compact echo for multi-line commands

**Files:**
- Modify: `src/rite/tasks.lg`
- Test: `test/rite/tasks_test.lg`, `tests/e2e.sh`

- [x] **Step 1: Write the failing unit tests**
  `(display-command cmd)`:
  - `"echo hi"` stays `"echo hi"`;
  - `"\n  echo one\n\nif x; then y; fi\necho three\n"` becomes `"echo one … (+2 lines)"`, with the first line trimmed and blank lines ignored;
  - a two-line command gives `(+1 lines)`.
- [x] **Step 2: Implement `display-command`**
  Use it in `run-sh-step!` for the `$` line only. The `--verbose` `+ sh -c` line keeps the full command.
- [x] **Step 3: Add an e2e assertion**
  A multi-line step echoes the compact form, and `--verbose` still shows every line.
- [x] **Step 4: Run the suite and commit**
  Run: `bash tests/run.sh`
  Expected: PASS.
  `git commit -m "feat: echo multi-line steps as their first line"`

> Deviation: `display-command` also trims a lone line padded with newlines (`"\n  echo hi\n"` echoes `echo hi`), so a one-line script written on its own lines does not echo blank lines.

### Task 4: `:fail-on-output`

**Files:**
- Modify: `src/rite/config.lg`, `src/rite/tasks.lg`, `src/rite/style.lg`
- Test: `test/rite/config_test.lg`, `tests/e2e.sh`

- [x] **Step 1: Schema tests, then the schema**
  - Accepted: `{:sh "x" :fail-on-output true}` and `false`.
  - Rejected: a non-boolean value; `:fail-on-output` on a `:run` or `:task` step.

  Run `lgx test` to see the cases fail, implement, then run it again to see them pass.
- [x] **Step 2: Implement the runner**
  Add `run-checked-sh-step!` in `tasks.lg`, following the five numbered behaviours in Design, Part B. Build the command exactly as `run-sh-step!` does (`with-cwd` included) and run it with `(os/sh "sh" "-c" full)` inside the same `with-env!`. Add `style/output-failure-line` for the `=> step printed output; expected none` line.
- [x] **Step 3: E2E scenarios**
  - `printf ''` passes;
  - `echo stale` fails with exit 1, and the output contains `stale`, the output-failure line and the task failure line;
  - `exit 4` fails with exit 4;
  - `echo warn >&2` passes.
- [x] **Step 4: Run the suite and commit**
  Run: `bash tests/run.sh`
  Expected: PASS.
  `git commit -m "feat: add :fail-on-output for check steps"`

### Task 5: `:parallel` schema and validation

**Files:**
- Modify: `src/rite/config.lg` (`step-schema`, `exactly-one-action-errors`, `step-ref-errors`, `task-steps`, `depends-refs-errors`)
- Test: `test/rite/config_test.lg`

- [x] **Step 1: Write the failing tests**
  - Accepted: `{:parallel [{:sh "a"} {:task fmt} {:sh "b" :cwd "web" :label "web"}]}`.
  - Rejected, each with a precise path:
    - an empty vector;
    - a non-vector;
    - a `:run` child;
    - a nested `:parallel` child;
    - a child with neither `:sh` nor `:task`;
    - a blank `:label`;
    - two children with the same explicit `:label`;
    - `:parallel` together with `:sh` in one step;
    - `:cwd` on the `:parallel` step itself;
    - a `:task` child naming an unknown task;
    - a `:task` child with an undeclared `:arg/x`;
    - an `:sh` child with an undeclared `{{arg/x}}`.
  - Cycles: `a {:do {:parallel [{:task a}]}}` reports `dependency cycle: a -> a`, and a two-task cycle through a `:parallel` child is caught too. Cover both `:do` forms, the single step map and the vector of steps, for cycles and for `:task`-child reference errors.
- [x] **Step 2: Run them to see them fail**
  Run: `lgx test`
  Expected: FAIL.
- [x] **Step 3: Implement**
  - Add `:parallel` to the action keys in `exactly-one-action-errors`.
  - Add a closed child schema (`:sh`, `:task`, `:cwd` for `:sh` only, `:label`), where each child needs exactly one of `:sh` or `:task`.
  - Run `step-ref-errors` over `:sh` children.
  - Extend `task-steps` to yield `[child [:do i :parallel j]]` for `:task` children, so `depends-refs-errors` and the cycle graph both see them.
- [x] **Step 4: Run the tests and commit**
  Run: `lgx test`
  Expected: PASS.
  `git commit -m "feat: validate :parallel steps"`

> Deviation: `exactly-one-action-errors` now says "must contain exactly one of :sh, :run, :task, :parallel"; existing tests were updated. A bad child gets its own messages ("`:run is not allowed in :parallel; use :sh or :task`", "`:parallel steps cannot be nested`"), and `:cwd` on a `:task` child is rejected like on a `:task` step.

### Task 6: Pure helpers in `rite.parallel`

**Files:**
- Create: `src/rite/parallel.lg`
- Test: `test/rite/parallel_test.lg`

- [x] **Step 1: Write the failing tests**
  The helpers take already-expanded children:
  - `(labels children)`: explicit labels win and are reserved first; a `:task` child uses its task name; an `:sh` child uses its command's first word; duplicates take the first free suffix, so `[go go go-2(explicit)]` gives `go`, `go-3`, `go-2`.
  - `(prefixes labels color?)`: `[api] ` and `[web] ` padded to equal width; purple escape codes only when `color?` is true.
  - `(task-child-command project exe task-name arg-strings)` gives `cd '<project>' && exec '<exe>' '<task>' '<arg>'`, each part quoted with `args/shell-quote`.
  - `(supervisor-argv children-with-labels)` gives `["sh" "-c" supervisor-script "sh" "<prefix1>" "<cmd1>" ...]`.
- [x] **Step 2: Implement**
  Write the four helpers and the `supervisor-script` constant, following the Design's supervisor bullets, with the comment block. The script takes pairs of (prefix, command) from `"$@"`.
- [x] **Step 3: Exercise the script directly**
  Before wiring it in, run the constant against dash and bash from a throwaway harness. Check six cases:
  - two children;
  - one failing child with a `sleep 30` sibling;
  - an instantly failing child;
  - a TERM-ignoring child;
  - a TERM-ignoring grandchild whose parent dies;
  - SIGINT;
  - SIGTERM to the parent.

  Expect the prefixed output, the exit codes 3, 2, 130 and 143, KILL after the bound, and no leftover `sleep 3[0]`.
- [x] **Step 4: Run the unit tests and commit**
  Run: `lgx test`
  Expected: PASS.
  `git commit -m "feat: add the :parallel supervisor and helpers"`

> Deviation: the supervisor's argv is `sh -c <script> sh <stop-open> <stop-close>` followed by a (prefix, label, command) triple per child, not (prefix, command) pairs. The supervisor needs the bare label and the colour codes to print the stop line itself. `supervisor-argv` therefore takes `[{:prefix :label :command}]` and `color?`.
> Deviation: the watchdog compares `ps -o ppid= -p $$` with the original `$PPID` instead of `kill -0 "$PPID"`, because a dead but unreaped parent still answers `kill -0`. Prefixes reach awk through `ENVIRON`, not `-v`, so backslashes in a label stay literal. On exit the supervisor gives the prefixers up to 2 seconds to drain (polling every 0.1 s) before it exits.
> Deviation: the throwaway harness ran under dash, bash and `bash --posix`. Every case passed: exit codes 3, 2, 130 and 143; KILL after the 5-second bound for a TERM-ignoring child and grandchild; no leftover `sleep 3x`; the watchdog also fired for a parent killed and never reaped. The SIGINT case has to signal the job's process group under `set -m`. A background job without job control starts with INT ignored, and a non-interactive sh cannot trap a signal that was ignored on entry.

> Deviation (codex must-fix, fixup `5c0c50e`): the prefixer is a shell `while IFS= read -r` loop, not `awk ... fflush()`. mawk, Ubuntu's default awk, block-buffers its piped input, so a dev server's lines would not show until much later. The `read` builtin takes a pipe byte by byte, so each line streams as soon as it is complete. The loop also keeps a final line that has no trailing newline. All harness cases were re-run under dash, bash and `bash --posix`.

### Task 7: Run `:parallel` steps

**Files:**
- Modify: `src/rite/tasks.lg` (`run-step!`, `run-steps!`), `src/rite/parallel.lg` (`run-parallel-step!`), `src/rite/plan.lg` (expose the `:task` arg resolver), `src/rite/style.lg` (`parallel-stop-line`)
- Test: `tests/e2e.sh`

- [x] **Step 1: Implement `run-parallel-step!`**
  1. Expand each `:sh` child with `sh-command`. Compute its default label from that expanded command, then wrap it in `with-cwd` (its own `:cwd`, else the task's).
  2. Turn each `:task` child into `task-child-command`, with args resolved against the caller's bindings the same way `rite.plan` resolves `:task` step args. Reuse that resolver rather than copying it.
  3. Compute the labels and prefixes, then print the echo lines from the Design (`$ parallel: ...` and one `[label] $ cmd` line per child), plus the `--verbose` lines.
  4. Run `(apply os/exec* (supervisor-argv ...))` inside the task's `with-env!`, and return its exit code.

  rite's exe is resolved once, before env is applied, as `run-steps!` already does for `:run`. The supervisor itself prints the stop line, via `$1`-style args or an env var carrying the preformatted `=>` text.
- [x] **Step 2: E2E scenarios**
  - prefixed output from two `:sh` children;
  - a `:task` child runs another task with an arg;
  - a failing child stops a `sleep 30` sibling in under 5 seconds: the exit code is the child's, the stop line and the task failure line print, and `pgrep -f 'sleep 3[0]'` finds nothing;
  - a child that exits 2 immediately still stops a `sleep 30` sibling;
  - a child running `trap '' TERM; sleep 30` is gone within 8 seconds (TERM, the 5-second bound, then KILL);
  - a TERM-ignoring grandchild whose parent exits is gone within 8 seconds, KILLed from the snapshot;
  - start rite as a `set -m` background job (see the process-group harness under Testing), send SIGINT to its group: exit 130 and no leftovers;
  - send SIGTERM to rite's PID only: within 3 seconds no leftovers (the watchdog);
  - task `:env` reaches both children.
- [x] **Step 3: Run the suite and commit**
  Run: `bash tests/run.sh`
  Expected: PASS.
  `git commit -m "feat: run :parallel steps"`

> Deviation: `run-parallel-step!` lives in `tasks.lg`, not `parallel.lg`. It needs `sh-command`, `with-cwd` and `display-command`, and `rite.parallel` cannot require `rite.tasks` without a cycle. `rite.parallel` keeps the script and the pure helpers. There is no `style/parallel-stop-line`: the supervisor prints the stop line itself, using colour codes from `style/purple-codes`. `style/label` colours a `[label]`. `plan/resolve-entry` is now public and reused for `:task` children.
> Deviation: `run-steps!` also resolves rite's exe when a `:parallel` step has a `:task` child. The e2e leak checks use `sleep 51`–`sleep 57`, one per scenario, matched as a whole `ps` line (`^sleep 51$`) rather than with `pgrep -f`. The child echo lines are `  [label] $ cmd`; with `--verbose` each child also gets a `  [label] + cd <dir>` or `  [label] + <subprocess command>` line.

### Task 8: README

**Files:**
- Modify: `README.md`

- [x] **Step 1: Document**
  Use /writing-clearly.
  - In `#### :do steps`, list `:parallel` as an action key and mention multi-line `:sh` strings with a short example.
  - In `#### :env and :cwd`, cover step-level `:cwd` and its precedence.
  - Add `#### :fail-on-output`, including the buffered-output note.
  - Add `#### :parallel steps`: shape, labels, the stop rules, no stdin, env and cwd, the `:task` subprocess, and the platform requirements.
  - In `## Development`, note that `:task` children need the built bundle.
- [x] **Step 2: Commit**
  `git commit -m "docs: document step :cwd, :fail-on-output and :parallel"`

> Advisory (codex, Task 7): a `:task` child naming a task that ends in `.lg` re-runs `rite build.lg`, which `cli/user-args` takes for dev mode, so the child prints help and exits 0. Running `rite build.lg` from a shell has the same problem, so this predates `:parallel`. It is backlogged in `docs/backlog/task-name-ending-in-lg.md` and not fixed here.

### Task 9: macOS CI job

**Files:**
- Modify: `.github/workflows/checks.yml`

- [x] **Step 1: Add the job**
  Add a `macos-latest` job (or a matrix entry) that runs the same `lgx check`. Install the same mise tools the Ubuntu job uses.
- [ ] **Step 2: Verify**
  Run: `actionlint` if available, otherwise check the YAML by eye.
  The job only runs on GitHub: push the branch and have the maintainer confirm that both jobs pass. A macOS failure in the `:parallel` scenarios is a real finding, not flakiness. bash 3.2 was not in the spike.
- [x] **Step 3: Commit**
  `git commit -m "ci: run checks on macOS"`

> Deviation: the macOS job is a `matrix.os` entry (`ubuntu-latest`, `macos-latest`, `fail-fast: false`) on the existing job, so `release.yml`'s `workflow_call` runs both. `actionlint` 1.7.12 (with shellcheck 0.11.0) reports nothing for `checks.yml`; its only finding is an existing info-level SC2035 in `release.yml`. Step 2 is still open. `checks.yml` runs only for pull requests and pushes to `master`, so pushing the feature branch started no run, and the macOS job has not run. Opening a PR against `master` runs both matrix jobs.

---

## Completion summary

**Implemented** (branch `feat/step-cwd-scripts-parallel`):

- per-step `:cwd` on `:sh` and `:run` steps;
- compact `$` echo for multi-line `:sh` steps;
- `:fail-on-output` on `:sh` steps;
- `:parallel` steps with `:sh` and `:task` children, run by a POSIX `sh` supervisor that provides prefixed streaming output, stop on first failure, the startup barrier, a TERM, 5 s, KILL stop over a snapshot of each process tree, SIGINT/SIGTERM handling and a parent watchdog;
- README sections;
- a macOS CI matrix entry.

Codex reviewed every task. One must-fix (mawk buffering) was fixed in `5c0c50e`, and one P2 (task names ending in `.lg`) was backlogged because it predates this work. `lgx check` passes: 376 unit tests and 167 e2e assertions. An end-to-end run of a kopi-style `rite.edn` (`deps`, `gen-check`, `dev`) behaved as designed.

**Issues encountered**

- The `lgx` first on PATH (0.5.4) cannot load this repo's test harness, so every command ran through `mise exec --`.
- Codex must-fix after Task 6: mawk block-buffers its piped input, so the awk prefixer did not stream. Fixed in `5c0c50e` with a shell `read` loop.
- Codex advisory after Task 7: a task named like `build.lg` is mistaken for dev mode when re-executed. The bug predates this work, so it was backlogged (`docs/backlog/task-name-ending-in-lg.md`).
- Harness lesson: SIGINT tests must signal a `set -m` job's process group. A background job without job control starts with INT ignored, and sh cannot trap a signal that was ignored on entry.

**Deviations**, each also noted under its task:

1. The "allowed keys" and "exactly one of" messages changed, and existing tests were updated.
2. `display-command` also trims a lone line padded with newlines.
3. Child validation has its own messages for `:run` children, nested `:parallel`, and `:cwd` on a `:task` child.
4. The supervisor's argv is `<stop-open> <stop-close>` followed by a (prefix, label, command) triple per child, not pairs. `supervisor-argv` takes `[{:prefix :label :command}]` and `color?`.
5. The watchdog compares `ps -o ppid=` with the original `$PPID` instead of using `kill -0 $PPID`, which a zombie parent still answers.
6. The prefixer is a `while read -r` loop, not awk.
7. On exit the supervisor gives the prefixers up to 2 s to drain.
8. `run-parallel-step!` lives in `tasks.lg` to avoid a require cycle. There is no `style/parallel-stop-line`; `style/purple-codes` and `style/label` were added instead, and `plan/resolve-entry` was made public.
9. Exe resolution also covers `:parallel` `:task` children.
10. E2E leak checks match a whole `ps` line instead of using `pgrep -f`.
11. macOS runs as a matrix entry on the existing job.

**What the plan could have specified better:** it should have named the awk implementation as a risk. The spike tested dash and bash but not mawk, Ubuntu's default awk, and that was where the plan broke. It should also have checked module dependencies when assigning `run-parallel-step!` to `rite.parallel`, since that placement creates a require cycle with `rite.tasks`.
