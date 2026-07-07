# rite Task Runner Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract lgx's task subsystem into rite — a generic, self-contained task runner binary with an embedded let-go runtime for `:run` steps, plus new `:vars` and `:depends` features.

**Tech Stack:** let-go (>= 1.11), built with lgx (`lgx build` → `bin/rite` via `lg -b`), bash e2e harness.

---

## Design

### What rite is

A single-binary task runner for any project. Config lives in `rite.edn` at the project root (found by walking up from CWD). Because rite is itself a let-go program bundled with `lg -b`, the shipped binary contains the full let-go compiler and namespace resolver — so `:run` steps execute let-go scripts with no external `lg` installed.

Reference implementation: `../lgx` (absolute: `/Users/andrew/Projects/lgx`). Most modules are ports of lgx modules with contexts/build/test/new machinery removed. When this plan says "port from lgx", read the named lgx file first and keep its style, docstrings, and edge-case handling unless the plan says otherwise.

### Verified let-go facts this design relies on

All verified against the let-go 1.11.1 source (`~/.lgx/let-go/source/1.11.1`):

1. A bundled binary (`lg -b` output) still initializes a full compiler context and `NSResolver` at startup, with search paths from the `LG_SOURCE_PATHS` env var (`lg.go` `runMain`/`buildSearchPaths`). So `require` inside a script evaluated in-process resolves namespaces from the filesystem.
2. `load-string` compiles and evaluates a string of code in-process (`pkg/compiler/eval.go`).
3. `alter-var-root` exists (`pkg/rt/lang.go`), so the script-mode child can rebind `*command-line-args*`.
4. `set-read-clj!` is callable in-process (enables `.clj`/reader-conditional support without the `LG_READ_CLJ` env var).
5. `os/args` returns the full `os.Args` including the executable path at index 0 — rite can re-exec itself.
6. `os/exec*` spawns a child with inherited stdin/stdout/stderr and returns its exit code — live streaming output.
7. **Limitation:** in a bundled binary, `io/resource` serves only the archive embedded at build time; filesystem resource roots are ignored. Therefore rite tasks have **no** `:resource-paths` key. Task scripts use `slurp` for files.

### `rite.edn` format

```edn
{:vars {:version "1.2.0"}          ; optional; shared template values

 :tasks
 {fmt    {:doc "Format sources"
          :do {:sh "cljfmt fix"}}

  check  {:doc "All checks"
          :depends [fmt lint]}      ; aggregate task: :depends without :do

  deploy {:doc "Deploy"
          :args [{:name :env :type [:enum "prod" "staging"]}]
          :depends [check [notify :arg/env]]
          :do [{:sh ["./deploy.sh" :arg/env]}
               {:sh "echo released {{version}}"}]}

  notify {:args [{:name :env}]
          :deps {abogoyavlensky/tiny-cli {:git/url "https://github.com/abogoyavlensky/tiny-cli"
                                          :git/tag "0.1.0"}}
          :paths ["scripts"]
          :do {:run ["scripts/notify.lg" :arg/env]}}}}
```

- Root map is **closed**: only `:vars` and `:tasks`. Anything else (`:contexts`, `:paths`, `:main`, …) is rejected with a schema error.
- `:vars` — map of **unqualified keyword** → string or number (numbers are stringified during normalization). Flat: vars do not reference other vars.
- Task keys (closed map): `:doc`, `:args`, `:do`, `:depends`, `:deps`, `:paths`. Renames from lgx: `:extra-deps` → `:deps`, `:extra-paths` → `:paths`. Dropped: `:with`, `:extra-resource-paths`. A task must have at least `:do` or `:depends` (cross-check).
- `:args`, `:do`, step grammar (`:sh`/`:run`, string or vector values, `:arg/<name>` placeholders, `{{name}}` templates) keep lgx semantics exactly (see `lgx/config.lg`, `lgx/args.lg`, `lgx/tasks.lg`).
- Task names are symbols; reserved names: `help`, `version`, `tasks`, `completion`, `__complete`.

### Placeholders: args and vars

Bindings for a running task form one map with two namespaces: `{:arg/env "prod", :var/version "1.2.0"}`.

- Vector-form step items: `:arg/<name>` and `:var/<name>` keywords substitute whole items — shell-quoted in `:sh`, verbatim in `:run` (same rules as lgx `args/substitute`).
- `{{name}}` in any step string: looked up as `:arg/name` first, then `:var/name` — **args shadow vars**. Unknown tokens pass through untouched (lgx `args/expand` behavior).
- Validation: an `:arg/*` placeholder must name a declared arg of that task; a `:var/*` placeholder (and any `{{name}}` that would only match a var) must name a key in `:vars` — except `{{name}}` tokens keep lgx's lenient pass-through (no load error for unknown `{{...}}`; only keyword placeholders are strictly validated).

### `:depends`

- Vector of entries. Entry = a symbol (`fmt`) or a vector `[task-sym item...]` where each item is a string (with `{{...}}` expansion), `:arg/<name>` (forwards the parent's bound arg), or `:var/<name>`.
- Execution: depth-first, in listed order, deps before the task's own steps. The whole invocation is flattened into a **plan** (ordered list of `{:name :task :bindings}`), **deduped by `[task-name resolved-arg-strings]`** — a diamond dependency runs once. First non-zero exit aborts the whole run with that exit code.
- Each planned task binds its resolved arg strings against its own `:args` declarations (types checked at plan-build time, before anything runs).
- Load-time validation (config cross-checks): every `:depends` entry names a defined task; placeholders in entry items must name the *parent's* declared args / defined vars; **literal-only** entries are arity- and type-checked against the dep's declarations; **cycle detection** on the static task-name graph (a cycle by name is an error even if args differ).

### `:run` steps — the built-in let-go mechanism

Parent side (per `:run` step):
1. Resolve the task's basis: fetch `:deps` (and their transitive deps) into the gitlibs cache; source paths = project root's task `:paths` (absolute) ++ dep source dirs. (rite has no project-level `:paths`; only the task's.)
2. Set env: `RITE_SCRIPT=1`, `LG_SOURCE_PATHS=<paths joined by os/path-separator>`, `LG_READ_CLJ=1`.
3. `os/exec*` `(first (os/args))` with argv = the step's argv (after `{{}}`/placeholder substitution and dropping the first `--`, per lgx `runner/drop-arg-separator`).
4. Restore the three env vars afterward so later `:sh` steps don't inherit them.

Child side — this is why one code path works in both dev and production:
- **Bundled rite**: the child is rite itself. Before any CLI parsing, `main.lg` checks `RITE_SCRIPT`: when non-blank, `os/args` is `[<exe> <script> <args>...]` — take script and args, call `(set-read-clj! true)`, rebind `*command-line-args*` via `alter-var-root` to the args seq (nil when empty, matching lg), `(load-string (slurp script))` inside try/catch (print `ex-message` to stderr, exit 1), else exit 0. The resolver already picked up `LG_SOURCE_PATHS` at process startup.
- **Dev (`lgx run` / `lg main.lg`)**: `(first (os/args))` is the `lg` binary itself, so the child is plain `lg <script> <args>` — which natively honors `LG_SOURCE_PATHS`/`LG_READ_CLJ` and sets `*command-line-args*`. `RITE_SCRIPT` is ignored by lg. Identical observable behavior, no dev/bundle branch in the parent.

Steps run from the invocation CWD (lgx parity): `:sh` commands and `:run` script paths resolve relative to where the user ran `rite`, while dep/`:paths` entries resolve against the project root.

### Deps cache — shared with lgx

- Home root: `$RITE_HOME`, else `$LGX_HOME`, else `~/.lgx`. Layout identical to lgx: `<home>/gitlibs/<host>/<owner>/<repo>/<ref>/`. Deps fetched by either tool are reused by the other.
- Coord grammar identical to lgx (`:git/url` + `:git/sha`|`:git/tag`, or `:local/root`, optional `:deps/root`).
- Transitive resolution ported from lgx: breadth-first, first-wins with warning on conflict, reading each fetched dep's **`lgx.edn`** (deps are let-go libraries and declare their deps the lgx way; rite does not look for `rite.edn` inside deps).

### CLI

```
rite                     # usage + task list (same as `rite help`)
rite help | -h | --help  # same
rite tasks               # just the task list
rite version             # print version
rite <task> [args...]    # run a task
rite --verbose <task>    # print resolved child invocations / env before running
```

- Task list rows: `rite <name> <req> [opt]` aligned to a doc column, `:doc` as description (port lgx `task-line`/`tasks-block`; keep help usable when `rite.edn` is invalid — print a one-line warning row instead of failing).
- Invalid task args print the errors + `usage: rite <task> <sig>` and exit 1 (lgx behavior).
- No project / no `rite.edn`: `help`/`version` still work (tasks block omitted); running a task errors.
- Styling: purple task headers and `$` step lines on stderr, ported from `lgx/style.lg`; disabled by `RITE_NO_COLOR`.

### Output behavior

Unlike lgx (which buffers via `os/sh` and replays), rite streams: `:sh` steps run as `(os/exec* "sh" "-c" cmd)`, `:run` children via `os/exec*` — child inherits stdio, so output is live and interactive programs work.

### Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `RITE_HOME` | `$LGX_HOME`, else `~/.lgx` | State root for the gitlibs cache (shared with lgx by default). |
| `RITE_NO_COLOR` | unset | Disable colored headers/step markers. |
| `RITE_SCRIPT` | set by rite | Internal marker: child process runs in script mode. Not user-facing. |

### Testing strategy

- **Unit tests** (`test/rite/*_test.lg`, run with `lgx test`): all pure logic — path/spec/style/home helpers, cli parsing, arg/var binding and substitution, config validation (including every new cross-check), plan building (dedup, forwarding, cycle/arity errors), git URL parsing, argv/env assembly for `:run`.
- **E2E** (`tests/run.sh` + `tests/e2e.sh` + `tests/fixtures/`, bash, modeled on lgx's): build `bin/rite`, then drive a fixture project covering: help/tasks listing, `:sh` task, `:vars` expansion, `:args` binding + validation errors, `:depends` chain with arg forwarding and diamond dedup, failure aborts the chain with the step's exit code, and a `:run` task with a `file://` git dep resolved through the embedded runtime — the integration proof for the self-exec mechanism.
- Dev loop stays lgx-based: `lgx test`, `lgx build`, existing `fmt`/`lint`/`check` tasks in this repo's `lgx.edn`.

## File Structure

```
main.lg                    # entry: script-mode branch, then CLI dispatch + usage (rewrite of scaffold)
src/rite/
  path.lg                  # port of lgx/path.lg (verbatim, ns renamed)
  style.lg                 # port of lgx/style.lg (RITE_NO_COLOR)
  spec.lg                  # port of lgx/spec.lg (verbatim, ns renamed)
  home.lg                  # state root: RITE_HOME → LGX_HOME → ~/.lgx
  cli.lg                   # user-args + leading-flags parsing (trimmed lgx/cli.lg)
  args.lg                  # bind-args, shell-quote, substitute, expand, signature, usage-line (+ :var/* support)
  config.lg                # rite.edn schema, validation, cross-checks, normalization, coords-at
  plan.lg                  # pure :depends graph → ordered deduped execution plan
  deps.lg                  # gitlibs cache + transitive resolution (port of lgx/cache.lg + ensure-all!)
  script.lg                # :run step: parent-side invocation + child-side script mode
  tasks.lg                 # step/plan execution (streaming)
  core.lg                  # DELETE (scaffold leftover)
test/rite/
  path_test.lg, style_test.lg, spec_test.lg, home_test.lg,
  cli_test.lg, args_test.lg, config_test.lg, plan_test.lg,
  deps_test.lg, script_test.lg, main_test.lg   # main's pure help-rendering helpers live in main-testable ns (see Task 9)
tests/
  run.sh                   # build bundle → unit tests → e2e
  e2e.sh                   # black-box scenarios against bin/rite
  fixtures/                # fixture project(s) + a file:// git dep repo
docs/plans/2026-07-07-rite-task-runner.md   # this plan
README.md                  # rewrite for rite
```

Note on lgx test sources: unit tests for ported modules start from the corresponding `../lgx/test/lgx/*_test.lg` files (adapt ns + trims), so coverage carries over instead of being rewritten.

---

### Task 1: Port foundation helpers (path, style, spec, home) and remove scaffold

**Files:**
- Create: `src/rite/path.lg`, `src/rite/style.lg`, `src/rite/spec.lg`, `src/rite/home.lg`
- Create: `test/rite/path_test.lg`, `test/rite/style_test.lg`, `test/rite/spec_test.lg`, `test/rite/home_test.lg`
- Delete: `src/rite/core.lg`, `test/rite/core_test.lg`

- [ ] **Step 1: Port tests from lgx**
  Copy `../lgx/test/lgx/{path,style,spec,home}_test.lg` to `test/rite/`, renaming namespaces `lgx.*` → `rite.*`. Adapt: style tests use `RITE_NO_COLOR`; home tests cover the new fallback chain — `RITE_HOME` wins, else `LGX_HOME`, else `$HOME/.lgx` — and drop `test-runner-dir`.

- [ ] **Step 2: Run tests to verify they fail**
  Run: `lgx test`
  Expected: FAIL (namespaces `rite.path` etc. not found).

- [ ] **Step 3: Port implementations**
  Copy `../lgx/lgx/{path,spec}.lg` verbatim with ns renames. `style.lg`: rename env gate to `RITE_NO_COLOR`; keep `green`/`purple`/`header`/`task-header`/`step-line` API. `home.lg`: only `root` — `RITE_HOME` if non-blank, else `LGX_HOME` if non-blank, else `(path/join (os/getenv "HOME") ".lgx")`. Delete `src/rite/core.lg` and `test/rite/core_test.lg`.

- [ ] **Step 4: Run tests to verify they pass**
  Run: `lgx test`
  Expected: PASS, 0 failures.

- [ ] **Step 5: Commit**
  `git commit -m "feat: port path/style/spec/home helpers from lgx"`

### Task 2: CLI argv parsing

**Files:**
- Create: `src/rite/cli.lg`
- Test: `test/rite/cli_test.lg`

- [ ] **Step 1: Write tests**
  Start from `../lgx/test/lgx/cli_test.lg`. Keep `user-args` cases (dev `.lg`-script prefix vs bundle prefix). `parse-leading-flags` now handles only `--verbose` (repeatable, order-independent, stops at first non-flag): returns `{:verbose? bool :args [...]}`. Drop `--with`/nrepl/new parser tests.

- [ ] **Step 2: Run tests to verify they fail**
  Run: `lgx test test/rite/cli_test.lg` — Expected: FAIL.

- [ ] **Step 3: Implement**
  Trim `../lgx/lgx/cli.lg`: keep `user-args` as-is; simplify `parse-leading-flags` to `--verbose` only.

- [ ] **Step 4: Run tests** — `lgx test test/rite/cli_test.lg` — Expected: PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat: add CLI argv parsing"`

### Task 3: Args + vars binding and substitution

**Files:**
- Create: `src/rite/args.lg`
- Test: `test/rite/args_test.lg`

- [ ] **Step 1: Write tests**
  Start from `../lgx/test/lgx/args_test.lg` (bind-args arity/types/defaults, shell-quote, substitute, expand, signature, usage-line — usage says `rite`, not `lgx`). Add new cases:
  - `var-bindings`: `{:version "1.2.0"}` (keyword keys) → `{:var/version "1.2.0"}`.
  - `substitute` replaces `:var/<name>` items (quoted for `:sh`, verbatim otherwise); unbound `:var/*` throws like unbound `:arg/*`.
  - `expand` with merged bindings: `{{name}}` prefers `:arg/name` over `:var/name` when both exist; falls back to `:var/name`; unknown tokens pass through.

- [ ] **Step 2: Run** — `lgx test test/rite/args_test.lg` — Expected: FAIL.

- [ ] **Step 3: Implement**
  Port `../lgx/lgx/args.lg`. Changes: `placeholder?` accepts namespace `"arg"` or `"var"`; add `var-bindings` (vars map → `:var/*`-keyed map of strings); `expand` lookup order `:arg/name` then `:var/name`. Callers pass one merged bindings map — `(merge (var-bindings vars) arg-bindings)` is NOT done here; add a tiny `task-bindings` fn `(fn [vars arg-bindings] (merge (var-bindings vars) arg-bindings))` so Task 5/8 agree on the shape.

- [ ] **Step 4: Run** — `lgx test test/rite/args_test.lg` — Expected: PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat: add task args and vars binding/substitution"`

### Task 4: Config schema and validation

**Files:**
- Create: `src/rite/config.lg`
- Test: `test/rite/config_test.lg`

- [ ] **Step 1: Write tests (structural schema)**
  Start from `../lgx/test/lgx/config_test.lg`, keeping: find-project walking, EDN parse errors, deps coord rules, task-name rules (symbols, reserved set now `help version tasks completion __complete`), `:args` rules, step rules, `:do` normalization, unknown-`:arg/*` placeholder cross-check. Adapt/add:
  - Root map closed to `:vars`/`:tasks`; `:contexts`, `:paths`, `:main` etc. rejected.
  - `:vars`: keys must be unqualified keywords; values strings or numbers; number values normalized to strings.
  - Task map closed to `:doc :args :do :depends :deps :paths`; `:extra-deps`/`:extra-paths`/`:with` rejected (typo-loud).
  - `:do` is now optional; a task with neither `:do` nor `:depends` is an error.
  - `:var/*` placeholders in steps must name a defined var; `:arg/*` must name a declared arg (existing check).
  - `coords-at` reads a dep dir's `lgx.edn` (keep lgx name/behavior).

- [ ] **Step 2: Run** — `lgx test test/rite/config_test.lg` — Expected: FAIL.

- [ ] **Step 3: Implement**
  Port and trim `../lgx/lgx/config.lg`: `config-name` is `"rite.edn"`; drop contexts/targets/main/lg-version/resource-paths schemas and accessors; keep `rel-path-errors`, coord/deps schemas, task/step/args schemas with the key changes above; keep `load-config`/`load-config!`/`errors-report`/`normalize-config` (extend normalization: stringify `:vars` values). `:depends` is schema-checked structurally here (vector; entries symbol or non-empty vector starting with a symbol whose tail items are strings/`:arg/*`/`:var/*` keywords); semantic cross-checks land in Task 5's validation section below — implement them here in config.lg but they may call into pure helpers. Accessors: `tasks`, `vars`.

- [ ] **Step 4: Run** — `lgx test test/rite/config_test.lg` — Expected: PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat: add rite.edn config schema and validation"`

### Task 5: Depends cross-checks and execution plan

**Files:**
- Create: `src/rite/plan.lg`
- Modify: `src/rite/config.lg` (root-level `:depends` cross-checks)
- Test: `test/rite/plan_test.lg`, extend `test/rite/config_test.lg`

- [ ] **Step 1: Write tests**
  Config cross-checks (load-time, in `config_test.lg`):
  - `:depends` entry naming an unknown task → error listing defined tasks.
  - Entry-item placeholders: `:arg/x` must be declared by the *parent* task, `:var/x` by `:vars`.
  - Literal-only entries type/arity-checked against the dep's `:args` (too many, missing required, enum/int mismatch → load error; entries containing placeholders skip value checks but still check max arity).
  - Cycle detection on the task-name graph: self-cycle `a → a` and `a → b → a` rejected with a message showing the cycle path.
  Plan building (pure, `plan_test.lg`) — `plan/build-plan` signature agreed here:
  ```
  (build-plan tasks-map vars root-name root-arg-strings)
  ;; → {:plan [{:name sym :task map :bindings {...}} ...]}  (root last)
  ;;    or {:errors ["..."]}
  ```
  Cases: no depends → single entry; chain order (depth-first, listed order, deps before dependents); diamond `d → [b c]`, `b → a`, `c → a` runs `a` once; same dep with *different* resolved args runs twice; arg forwarding (`[notify :arg/env]` with root bound `env=prod` → notify's bindings have `:arg/env "prod"`); `{{var}}` in dep-entry strings expands from vars+parent args; dep's own `:args` defaults fill; bad runtime value (enum mismatch via forwarded arg) → `:errors`.

- [ ] **Step 2: Run** — `lgx test` — Expected: FAIL on new tests.

- [ ] **Step 3: Implement**
  `plan.lg` is pure (no I/O). Resolve one entry: symbol → `[sym []]`; vector → substitute items against parent bindings (`args/substitute` verbatim mode + `args/expand` for strings), then `args/bind-args` against the dep task's decls, then `args/task-bindings` with vars. Dedup key `[name resolved-arg-strings]`; post-order DFS; collect errors with the referencing task named. Config cross-checks reuse the same entry-resolution helpers for the literal checks; cycle detection is a plain DFS over `{task → dep-names}` in config.lg.

- [ ] **Step 4: Run** — `lgx test` — Expected: PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat: add :depends validation and execution planning"`

### Task 6: Deps fetching (gitlibs cache + transitive resolution)

**Files:**
- Create: `src/rite/deps.lg`
- Test: `test/rite/deps_test.lg`

- [ ] **Step 1: Write tests**
  Start from `../lgx/test/lgx/cache_test.lg` (parse-git-url forms, coord-dir layout, ensure-lib! against `file://` fixture repos with RITE_HOME pointed at a temp dir, `:deps/root`, `:local/root`). Add `ensure-all!` transitive cases (move the lgx tests for it if they live in the lgx main-adjacent tests; otherwise write: dep with its own lgx.edn declaring a second dep → both fetched; conflicting coord → first-wins warning; cycle terminates). Drop let-go-source tests.

- [ ] **Step 2: Run** — `lgx test test/rite/deps_test.lg` — Expected: FAIL.

- [ ] **Step 3: Implement**
  Port `../lgx/lgx/cache.lg` minus the let-go-source section (gitlibs root under `home/root`). Move `ensure-all!`, `coords-at!`, `coord-label`, `coord-id`, and `print-installs!` from `../lgx/lgx.lg` into `deps.lg` (they were main-file privates in lgx; rite gives them a home so `tasks.lg` can call them). `merge-coords` comes along from lgx config (task `:deps` has nothing to merge over in rite — drop it unless `ensure-all!` needs the pair-list helpers; prefer dropping).

- [ ] **Step 4: Run** — `lgx test test/rite/deps_test.lg` — Expected: PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat: add gitlibs dep fetching with transitive resolution"`

### Task 7: `:run` script mode (self-exec) 

**Files:**
- Create: `src/rite/script.lg`
- Test: `test/rite/script_test.lg`

- [ ] **Step 1: Spike the mechanism (throwaway, do first)**
  Before writing tests, verify the child-side contract with the real runtime: build any tiny bundle (or use `lg -e`) and confirm (a) `(alter-var-root (var *command-line-args*) (constantly '("x")))` works, (b) `load-string` of a script with `(ns t (:require ...))` resolves a namespace from `LG_SOURCE_PATHS` in a bundled binary, (c) `set-read-clj!` is callable. Record any deviation in the module's header comment and adapt. This de-risks the whole design; if (a) fails, fall back to passing args through a `RITE_SCRIPT_ARGS` env var read by the script-mode child — but verify first.

- [ ] **Step 2: Write tests for the pure parts**
  - `script-mode?`: true iff `RITE_SCRIPT` env non-blank (pass lookup fn for testability).
  - `child-argv`: from a substituted `:run` step value → argv with first `--` dropped (port `drop-arg-separator` + `as-arg-vec` behavior from `../lgx/lgx/runner.lg` / `tasks.lg`: string splits on whitespace after expansion; vector passes through).
  - `source-paths`: project root + task `:paths` (absolutized against project, warn-on-missing like lgx `resolve-project-paths`) ++ dep result paths, joined with `os/path-separator` for the env value.
  - `verbose` trace lines: `+ env RITE_SCRIPT=1 LG_SOURCE_PATHS=... LG_READ_CLJ=1` and `+ <exe> <argv>`.

- [ ] **Step 3: Run** — `lgx test test/rite/script_test.lg` — Expected: FAIL.

- [ ] **Step 4: Implement**
  - `run-script!` (child side): take raw `(os/args)`; script = second element, script-args = rest. `(set-read-clj! true)`; `alter-var-root` `*command-line-args*` to a seq of script-args or nil; `(load-string (slurp script))` in try/catch → on exception write `ex-message` to stderr, `(os/exit 1)`; else `(os/exit 0)`. Missing script file → clear error, exit 1.
  - `exec-run-step!` (parent side): resolve basis (call `deps/ensure-all!` on the task's `:deps` pairs, print installs), set the three env vars, `(os/exec* (first (os/args)) & argv)`, restore prior env values, return exit code.

- [ ] **Step 5: Run** — `lgx test test/rite/script_test.lg` — Expected: PASS.

- [ ] **Step 6: Commit** — `git commit -m "feat: add self-exec script mode for :run steps"`

### Task 8: Task execution

**Files:**
- Create: `src/rite/tasks.lg`
- Test: `test/rite/tasks_test.lg`

- [ ] **Step 1: Write tests**
  Port the pure helpers' tests from lgx's tasks coverage (`as-string`, substitution of step values with merged arg+var bindings). New: `run-plan!` semantics are exercised in e2e (side-effectful); here test step-value preparation: `:sh` vector with `:var/x` → quoted; `:sh` string with `{{x}}`; `:run` string → argv split after expansion.

- [ ] **Step 2: Run** — `lgx test test/rite/tasks_test.lg` — Expected: FAIL.

- [ ] **Step 3: Implement**
  Port `../lgx/lgx/tasks.lg` with changes: `:sh` runs `(os/exec* "sh" "-c" cmd)` (streaming — no buffered replay); `:run` delegates to `script/exec-run-step!`; `run-plan!` iterates the plan from Task 5 — for each entry print `task-header`, run its steps with its bindings; first non-zero exit → `(os/exit code)`; all done → `(os/exit 0)`. A `:depends`-only task prints its header and runs nothing. Each entry with `:run` steps resolves its own basis once (lazily, only when the task has a `:run` step).

- [ ] **Step 4: Run** — `lgx test test/rite/tasks_test.lg` — Expected: PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat: add streaming task execution over the plan"`

### Task 9: Entry point, dispatch, and help

**Files:**
- Rewrite: `main.lg`
- Create: `src/rite/help.lg` (pure usage rendering, so it's testable — main.lg stays a thin shell since requiring `rite.main` from tests would execute it)
- Test: `test/rite/help_test.lg`

- [ ] **Step 1: Write tests for help rendering**
  Port `task-line`/`tasks-block`/usage assembly behavior from `../lgx/lgx.lg` (doc-column alignment, arg signatures, sorted task names, invalid-config warning row, nil project → no tasks block). Usage text: `rite - task runner for any project`, commands `rite <task> [args...]`, `rite tasks`, `rite version`, `rite help`; options: `--verbose`.

- [ ] **Step 2: Run** — `lgx test test/rite/help_test.lg` — Expected: FAIL.

- [ ] **Step 3: Implement**
  `help.lg`: pure renderers. `main.lg` (mirror `../lgx/lgx.lg` structure, heavily trimmed):
  1. `(def version "0.1.0")`.
  2. In `main`: **first** check `(script/script-mode? os/getenv)` → `(script/run-script!)` (never returns). This must precede `cli/user-args` — in script mode argv[1] is the task script and must not be misread as the dev-mode prefix.
  3. Else: `cli/user-args` → `parse-leading-flags` → dispatch: nil/`help`/`-h`/`--help` → print usage; `tasks` → tasks block only (error exit 1 when no project/no tasks? — print "no tasks defined" info, exit 0); `version` → `rite <version>`; anything else → task lookup: find-project! + load-config!, unknown task → `rite: '<x>' is not a task. See 'rite help'.` exit 1; else bind CLI args (errors + usage-line on failure, exit 1), `plan/build-plan`, plan errors → print + exit 1, else `tasks/run-plan!`.
  4. Keep the `*compiling-aot*` guard around `(main)`.

- [ ] **Step 4: Verify manually in dev mode**
  Run: `lgx run` (bare) → usage prints. Create a scratch `rite.edn` in a temp dir with an `:sh` task and run `lgx run -- <task>`... note: dev-mode arg passing goes through `lgx run --`; simpler: `lgx build && ./bin/rite` from a temp project. Confirm: `rite` lists tasks, `rite <task>` runs, `rite version` prints.
  Run: `lgx test` — Expected: full suite PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat: add rite entry point, dispatch, and help"`

### Task 10: E2E harness

**Files:**
- Create: `tests/run.sh`, `tests/e2e.sh`, `tests/fixtures/` (fixture project + `file://` dep repo builder)
- Modify: `lgx.edn` (add `e2e` task: `{:sh "bash tests/run.sh"}` — or make `check` include it)

- [ ] **Step 1: Write the harness**
  Model on `../lgx/tests/run.sh` + `e2e.sh` (pin `lg` via mise, `lgx build`, temp `RITE_HOME`, assert helpers). Scenarios, each a fresh temp project dir:
  1. `rite` / `rite help` → usage with task rows and signatures; `rite tasks` → list only.
  2. `:sh` task runs, streams output, exit code propagates on failure.
  3. `{{var}}` and `:var/kw` substitution (incl. shell-quoting of a var with spaces).
  4. `:args`: defaults, enum rejection message + usage line, too-many-args.
  5. `:depends`: chain order asserted via echoed markers; diamond dedup (dep echoes once); arg forwarding `[dep :arg/env]`; failure mid-chain stops and propagates code; load-time cycle error.
  6. `:run` task: script requiring a namespace from a `file://` git dep (create a bare-ish fixture repo with `git init`/commit in the harness) + a task `:paths` dir; assert dep fetched under `$RITE_HOME/gitlibs`, script args arrive in `*command-line-args*`, second run reuses cache (no "installing" output).
  7. Config validation: unknown root key, unknown task key (`:extra-deps` typo), reserved task name — each errors with the schema report.
  8. `RITE_NO_COLOR=1` output contains no escape codes.

- [ ] **Step 2: Run** — `bash tests/run.sh` — Expected: all scenarios PASS.

- [ ] **Step 3: Fix anything the e2e surfaces, re-run until green.**

- [ ] **Step 4: Commit** — `git commit -m "test: add e2e harness for rite binary"`

### Task 11: README and repo housekeeping

**Files:**
- Rewrite: `README.md`
- Modify: `lgx.edn` (ensure `check` covers fmt+lint+test+e2e), `.gitignore` (bin/, tmp)

- [ ] **Step 1: Rewrite README**
  Use /writing-clearly. Cover: what rite is (generic task runner, embedded let-go, single binary); quickstart with a minimal `rite.edn`; full annotated `rite.edn` reference (`:vars`, task keys, args, steps, `:depends` incl. arg forwarding and run-once semantics); the `:run` embedded-runtime explanation + the `io/resource` limitation; env vars table (`RITE_HOME` sharing lgx's cache, `RITE_NO_COLOR`); CLI reference; development section (lgx-based: `lgx test`, `lgx build`, `bash tests/run.sh`).

- [ ] **Step 2: Verify all checks**
  Run: `lgx check` (and `bash tests/run.sh` if not included) — Expected: PASS.

- [ ] **Step 3: Commit** — `git commit -m "docs: rewrite README for rite task runner"`
