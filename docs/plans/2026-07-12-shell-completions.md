# Shell Completions Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** TAB-complete rite's task names and a task's `[:enum ...]` arg values in bash, zsh, and fish, via `rite completion <shell>` and a hidden `rite __complete` endpoint.

**Tech Stack:** let-go (lg) / lgx toolchain, shell scripts embedded as string constants.

---

## Design

Mirror the two-endpoint design proven in lgx (`../lgx/lgx/completion.lg`),
adapted to rite's simpler grammar. lgx's `completion.lg` already implements
enum-arg-value completion, so this is close to a direct port with the word-walk
simplified. Two entry points, both hidden from help and from TAB candidates,
both new branches in `dispatch` in `main.lg`:

1. **`rite completion <shell>`** — prints the bash/zsh/fish completion script to
   stdout. Hidden: no CLI/help row, not offered as a TAB candidate; documented
   only in the README. Unknown or missing shell → one-line error to stderr,
   exit 1.

2. **`rite __complete <words…>`** — hidden endpoint the shell scripts call on
   TAB. The last argument is the word under the cursor (possibly empty). Prints
   one prefix-filtered candidate per line. **Always exits 0** and swallows every
   error (no project, invalid `rite.edn`) so completion can never break the
   user's shell. Empty output makes the shell fall back to file completion.

Both are new branches in the `dispatch` `case` in `main.lg`, taking precedence
over task lookup. `"completion"` and `"__complete"` are **already** in
`config/reserved-task-names`, so a task cannot shadow them and they are already
excluded from `tasks` listing — no `config.lg` change is needed.

### What gets completed

- **Task names** at the command position — the project's custom tasks from
  `rite.edn` (namespaced names like `foo/bar` preserved), plus the one built-in
  word-command `tasks`.
- **Enum arg values** at a task's arg positions — for any arg whose `:type` is
  `[:enum ...]`. E.g. `rite fmt <TAB>` → `check fix`. rite's arg model
  (`:type [:enum "fix" "check"]`) matches lgx's, so the logic ports directly.
- Nothing else: no flag completion (`cur` starting with `-` → `[]`), no
  completion for `:int`/`:string` args (empty → the shell falls back to file
  completion).

### Candidate logic (pure, in `rite.completion`)

`(candidates words cur tasks)` — `words` are the typed tokens before the cursor
(binary name and `__complete` excluded), `cur` the word being completed (may be
`""`), `tasks` a map of task-name string → its `:args` decls vector. Returns a
sorted, prefix-filtered vector.

Grammar is `rite [--verbose]* <task> [args…]` — simpler than lgx (no `--with`),
so the word-walk drops lgx's `--with`/`:awaiting-value` handling entirely. A
private `prompt-state` classifies `words`:

```
(defn- prompt-state [words]
  (loop [ws (seq words)]
    (cond
      (nil? ws) {:state :command-position}
      (= "--verbose" (first ws)) (recur (next ws))   ; the only leading flag
      :else {:state :command-typed
             :command (first ws)
             :args-typed (count (rest ws))})))
```

`prompt-state` mirrors `cli/parse-leading-flags` exactly: **only** `--verbose`
is a leading flag (repeatable). Any other token — a stray `--bogus`, a terminal
`--help`/`-v` — is what the real parser treats as the command word, so it ends
the command position and completion offers nothing after it (an unknown command
is not in `tasks` → `[]`). (Per the committed-code Codex review; an earlier
draft skipped every `-`-prefixed token, which wrongly offered task names after
`rite --help `.)

`candidates` then:

```
(defn candidates [words cur tasks]
  (let [{:keys [state command args-typed]} (prompt-state words)]
    (cond
      (str/starts-with? cur "-") []
      (= :command-position state)
        (matches (filter shell-safe? (concat builtin-commands (keys tasks))) cur)
      (and (= :command-typed state) (contains? tasks command))
        (matches (or (enum-values (get tasks command) args-typed) []) cur)
      :else [])))
```

**Task names are `shell-safe?`-filtered too** (not only enum values): task
names are project-controlled symbols inserted onto the command line on TAB just
like enum values, so the same never-insert-unsafe-syntax guarantee must cover
them. EDN's symbol grammar already excludes the worst metacharacters (`()`,
backtick, `;`, `|`, spaces, quotes), but `$ * ? < > &` remain possible; a task
whose name contains one is omitted from completion (it still runs when typed by
hand). Built-in names are inherently safe, so filtering the concatenated list is
equivalent and simplest. (This is a deliberate, uniform hardening over lgx,
which filters only enum values.)

- `builtin-commands` is a `def` of `["tasks"]` (rite's only non-flag built-in),
  with a comment naming `dispatch` in `main.lg` as the source of truth.
  `completion`/`__complete` are deliberately absent (hidden).
- `matches` returns the `sort`ed subset of values that `str/starts-with?` `cur`,
  as a vector.
- `args-typed` is the 0-indexed position of the arg under the cursor: with
  `words = ["fmt"]` (cursor on the first arg) it is `0`, so `enum-values` reads
  decl `0`.

### Enum values (shell-safe)

`(enum-values decls idx)` returns the `[:enum ...]` values of the decl at
position `idx`, or nil when there is no decl there or its `:type` isn't a vector
(config validation guarantees an enum `:type` is a vector and the only vector
`:type`). Values are filtered through `shell-safe?` first:

```
(def ^:private shell-safe-re #"^[A-Za-z0-9._/:=+,@-]+$")
```

Enum values are project-controlled strings inserted onto the shell command line
on TAB; a value like `$(cmd)` or one with spaces would be active syntax once
accepted, so a malicious `rite.edn` could run code on a stray TAB. Only values
made of inert characters are offered; anything else is omitted from completion
(the arg still validates and runs when typed by hand). This covers realistic
values (`prod`, `us-east-1`, `v1.2.0`) while excluding every shell metacharacter.

### I/O entry points (in `rite.completion`)

- `project-tasks` — map of task name (string, namespaces preserved) → `:args`
  decls for the project enclosing the cwd, or `{}` when there is no project or
  its `rite.edn` is invalid. Uses the **non-throwing** readers
  `config/find-project` (nil outside a project) and `config/load-config`
  (returns `{:cfg …}` or `{:errors …}`); wrapped in its own try/catch so
  built-in completion survives even if the config layer surprises.
- `complete!` — the `__complete` handler: takes the raw argv after
  `__complete`, splits it into `words` (butlast) and `cur` (last, or `""` when
  argv is empty), and prints each candidate on its own line. The whole body is
  wrapped in try/catch → prints nothing on any error. It never calls `os/exit`;
  the dispatch branch does `(os/exit 0)` after it returns, keeping the function
  testable.
- `cmd-completion!` — the `completion` handler: exactly one argument in
  `#{"bash" "zsh" "fish"}` → print the matching script constant to stdout; empty
  args → `rite: completion requires a shell argument (bash, zsh, or fish)`;
  more than one → `rite: completion takes exactly one argument (bash, zsh, or
  fish)`; unknown shell → `rite: unsupported shell: <arg> (expected one of:
  bash, zsh, fish)`. All errors to stderr, exit 1.

Note on argv: `cli/parse-leading-flags` runs before dispatch, but `__complete`
is always the first user token (the shell scripts call `rite __complete
<words…>`), so the words being completed are never consumed as leading flags —
`rite __complete --verbose ""` reaches dispatch intact.

### Shell scripts

Three string constants in `rite.completion` — **not** `io/resource`. Although
rite embeds `resources/VERSION` via `io/resource`, string constants resolve
identically under `lgx test` (source) and the bundle with no resource-root
uncertainty, and let the unit tests assert on script contents directly. Each
script is ~15 lines, ported from lgx with `lgx` → `rite` and `_lgx` → `_rite`.
Scripts invoke the binary by the name it was called as, so install location
does not matter:

- **bash** — `_rite_complete()` reads `"${COMP_WORDS[0]}" __complete
  "${COMP_WORDS[@]:1:COMP_CWORD}"` line by line into `COMPREPLY` (no `compgen
  -W`, which would shell-expand project-controlled text); registered with
  `complete -o default -F _rite_complete rite` (`-o default` = filename fallback
  when output is empty).
- **zsh** — `#compdef rite` header; reads `"${words[1]}" __complete
  "${(@)words[2,CURRENT]}"` into an array, offers via `compadd -Q`, falls back
  to `_default` when empty; works both sourced and as `_rite` on `$fpath` (the
  `funcstack` check at the bottom).
- **fish** — a `__rite_complete` function calling `$words[1] __complete
  $words[2..-1] "$cur"` (quoted `"$cur"` so the empty boundary word survives),
  one `complete -c rite -f -n` rule for dynamic candidates and one
  `complete -c rite -n 'not …' -F` fallback rule for file completion.

`completion-script` maps `"bash"|"zsh"|"fish"` to its constant, else nil.

### Error handling summary

- `__complete`: never errors, always exits 0, prints nothing on any failure.
  Outside a project or with a broken `rite.edn`, `tasks` still completes; task
  names just drop out.
- `completion` with unknown/missing/extra shell arg: error to stderr, exit 1.
- `rite --help` / `rite tasks` output unchanged (the commands are hidden).

## File Structure

- **Create** `src/rite/completion.lg` (ns `rite.completion`) — `builtin-commands`,
  pure `candidates` (+ private `prompt-state`, `enum-values`, `matches`,
  `shell-safe?`), the three script constants + `completion-script`, and the I/O
  handlers `project-tasks`, `complete!`, `cmd-completion!`.
- **Create** `test/rite/completion_test.lg` (ns `rite.completion-test`) — unit
  tests for `candidates`, the script constants, and `completion-script`.
- **Modify** `main.lg` — require `rite.completion`; add `"completion"` and
  `"__complete"` branches to `dispatch`.
- **Modify** `tests/e2e.sh` — new Scenario 9 for completion.
- **Modify** `README.md` — a new `## Shell completions` section at the bottom,
  plus a row in the `## CLI` block.

No `config.lg` change: `reserved-task-names` already holds `"completion"` and
`"__complete"`. rite has no `ARCHITECTURE.md`.

All commands run from the repo root (`/Users/andrew/Projects/rite`). Dev-mode
unit-test command: `lgx test` (baseline before this work: 260 tests, 317
assertions, 0 failures). Full build + unit + e2e: `bash tests/run.sh` (or
`lgx e2e`).

## Implementation Steps

### Task 1: Pure candidate logic

> Deviation (execution): the module is small and cohesive, so Tasks 1 and 2
> (candidate logic + scripts + the `completion`/`__complete` dispatch wiring in
> `main.lg`) were implemented and committed together, and the `__complete`
> dispatch branch was pulled forward from Task 3. Behavior matches the plan.
> Also, per the background Codex plan review, task-name candidates are now
> `shell-safe?`-filtered too (not only enum values) — a uniform hardening; see
> the Design note.

**Files:**
- Create: `src/rite/completion.lg`
- Test: `test/rite/completion_test.lg`

- [x] **Step 1: Write failing tests for `candidates`**
  In `test/rite/completion_test.lg` (ns `rite.completion-test`, requiring
  `clojure.test` and `rite.completion`), following the `deftest`/`is` style of
  `test/rite/cli_test.lg`. Cover, using a `tasks` map literal like
  `{"fmt" [{:name :action :type [:enum "fix" "check"] :default "fix"}]
    "lint" nil "foo/bar" nil}`:
  - empty `words` + empty `cur` → `["foo/bar" "fmt" "lint" "tasks"]` (built-in
    `tasks` plus task names, sorted);
  - prefix filter: `cur "fm"` → `["fmt"]`; `cur "ta"` → `["tasks"]`;
  - namespaced task `foo/bar` offered and prefix-matched by `cur "foo"`
    (`/` is in the shell-safe set, so namespaced names survive);
  - a task name with an unsafe char (e.g. `"a$b"`) is omitted at the command
    position;
  - empty `tasks` map → `["tasks"]` only;
  - `"completion"` and `"__complete"` never appear in output;
  - leading `["--verbose"]` before the cursor → command names still complete;
  - enum values: `words ["fmt"]`, `cur ""` → `["check" "fix"]`; `cur "f"` →
    `["fix"]`;
  - a typed command with no enum arg there: `words ["lint"]`, `cur ""` → `[]`;
    and past the last decl: `words ["fmt" "fix"]`, `cur ""` → `[]`;
  - an unknown typed command: `words ["nope"]`, `cur ""` → `[]`;
  - `cur "-"` and `cur "--"` → `[]` in every position.

- [x] **Step 2: Run tests to verify they fail**
  Run: `lgx test test/rite/completion_test.lg`
  Expected: FAIL (namespace `rite.completion` does not exist yet).

- [x] **Step 3: Implement `builtin-commands`, `candidates`, and helpers**
  Pure code only, no I/O. Implement `prompt-state`, `matches`, `shell-safe?`,
  `enum-values`, and `candidates` per the Design (signatures and the
  `shell-safe-re` regex are fixed above; match them exactly). `builtin-commands`
  is `["tasks"]` with a comment naming `dispatch` in `main.lg` as source of
  truth. Require `[string :as str]`.

- [x] **Step 4: Run the full unit suite**
  Run: `lgx test`
  Expected: PASS (260 + new assertions, 0 failures).

- [x] **Step 5: Commit**
  `git commit -m "feat: add pure shell-completion candidate logic"`

### Task 2: Script constants and the `completion` command

**Files:**
- Modify: `src/rite/completion.lg`, `main.lg`
- Test: `test/rite/completion_test.lg`

- [x] **Step 1: Write failing tests for the script constants and shell lookup**
  Each of the three script strings is non-empty, contains `__complete`, and
  registers completion for `rite` (bash: `complete -o default`; zsh:
  `#compdef rite`; fish: `complete -c rite`). `(completion-script "bash")`,
  `"zsh"`, `"fish"` are non-empty; `(completion-script "nope")` is nil.

- [x] **Step 2: Run tests to verify they fail**
  Run: `lgx test test/rite/completion_test.lg`
  Expected: FAIL (constants and `completion-script` missing).

- [x] **Step 3: Implement the scripts, lookup, and `cmd-completion!`**
  Port the three lgx scripts (`../lgx/lgx/completion.lg`) as `^:private` string
  constants, replacing `lgx` → `rite` and `_lgx` → `_rite` throughout (including
  the load-instruction comments and the `funcstack`/function names). Add
  `completion-script` and `cmd-completion!` per the Design (four distinct
  stderr messages: empty arg, >1 arg, unknown shell, plus the success path).
  In `main.lg`: require `[rite.completion :as completion]` and add the
  `"completion"` branch to `dispatch`:
  `"completion" (completion/cmd-completion! rest-args)`. Do **not** add a CLI/help
  row — the command stays hidden.

- [x] **Step 4: Run the full unit suite**
  Run: `lgx test`
  Expected: PASS.

- [x] **Step 5: Smoke-check the built binary**
  Run: `lgx build >/dev/null && ./bin/rite completion bash | head -3`
  → bash script lines. Then `./bin/rite completion nope; echo exit=$?` →
  stderr error and `exit=1`; `./bin/rite completion; echo exit=$?` → the
  "requires a shell argument" error and `exit=1`; `./bin/rite --help | grep -c
  completion` → `0`.

- [x] **Step 6: Commit**
  `git commit -m "feat: add hidden rite completion command with bash/zsh/fish scripts"`

### Task 3: `__complete` endpoint and e2e coverage

**Files:**
- Modify: `src/rite/completion.lg`, `main.lg`, `tests/e2e.sh`

- [x] **Step 1: Implement `project-tasks`, `complete!`, and the dispatch branch**
  In `rite.completion`, add `project-tasks` (non-throwing config read →
  `{task-name-string [args-decls] …}`, own try/catch → `{}`) and `complete!`
  (words/cur split, try/catch around the whole body, no `os/exit` inside), per
  the Design. In `main.lg`, add the `"__complete"` branch to `dispatch`:
  `"__complete" (do (completion/complete! rest-args) (os/exit 0))`.

- [x] **Step 2: Smoke-check the built binary**
  Run: `lgx build >/dev/null`, then from the repo root (rite is itself a rite
  project — `rite.edn` declares `fmt`/`lint`/`check`):
  `./bin/rite __complete ""` → includes `fmt`, `lint`, `check`, `tasks`;
  `./bin/rite __complete fm` → `fmt`;
  `./bin/rite __complete fmt ""` → `check` and `fix` (the enum values);
  `./bin/rite __complete lint ""; echo exit=$?` → nothing, `exit=0`.

- [x] **Step 3: Add Scenario 9 to `tests/e2e.sh`**
  Following the file's existing helper/assert style (`assert_contains`,
  `assert_not_contains`, `assert_eq`, `fail`, per-scenario `mktemp -d` project
  + `RITE_HOME`). In a fixture `rite.edn` declaring a task with an `[:enum …]`
  arg (e.g. `deploy {:args [{:name :env :type [:enum "prod" "staging"]}] :do
  [{:sh "echo deploy"}]}`) plus a plain task:
  - `__complete ""` lists the task names and `tasks`;
  - `__complete <prefix>` filters to the matching task;
  - `__complete <task-with-enum> ""` lists the enum values, and
    `__complete <task-with-enum> <val-prefix>` filters them;
  - outside any project (a fresh temp dir with no `rite.edn`), `__complete ""`
    exits 0 (assert the exit code with the `set +e` / `rc=$?` / `set -e`
    pattern already used in Scenario 1);
  - with an invalid `rite.edn` fixture (e.g. `{:tasks {bad {}}}`), `__complete
    ""` exits 0;
  - `completion bash` is non-empty and contains `__complete`;
  - `completion nope` exits 1;
  - `--help` output does not contain `completion` (`assert_not_contains`).
  Increment the final assertion-count message automatically via `PASS_COUNT`
  (already handled by `pass`).

- [x] **Step 4: Run the full suite (build + unit + e2e)**
  Run: `bash tests/run.sh`
  Expected: all pass (unit + all e2e scenarios including the new one).

- [x] **Step 5: Interactive bash smoke test**
  In a bash shell: `source <(./bin/rite completion bash)`, then confirm
  `rite <TAB>` lists task names + `tasks` and `rite fm<TAB>` completes to `fmt`
  and `rite fmt <TAB>` offers `check`/`fix`. zsh/fish scripts are byte-for-byte
  ports of lgx's interactively tested ones; if those shells are unavailable
  here, note it in the final report.

- [x] **Step 6: Commit**
  `git commit -m "feat: add __complete endpoint for dynamic shell completion"`

### Task 4: Documentation

**Files:**
- Modify: `README.md`

- [x] **Step 1: Add a `## Shell completions` section at the bottom of `README.md`**
  A new top-level section after `## Development` (the last current section),
  introduced with one sentence noting completion covers task names and a task's
  enum arg values. One subsection/snippet per shell:
  - bash: `source <(rite completion bash)` in `~/.bashrc`;
  - zsh: `rite completion zsh > ~/.zfunc/_rite` (with an `fpath` note) or
    `source <(rite completion zsh)`;
  - fish: `rite completion fish > ~/.config/fish/completions/rite.fish`.
  Use the /writing-clearly skill.

- [x] **Step 2: Add a CLI row**
  In the `## CLI` code block, add a line documenting
  `rite completion <shell>   # print a bash/zsh/fish completion script`.

- [x] **Step 3: Format check and final run**
  Run: `lgx fmt check` then `lgx test`
  Expected: both pass.

- [x] **Step 4: Commit**
  `git commit -m "docs: document shell completions"`

---

## Notes for the executor

- rite's grammar has only a leading `--verbose` flag; there is no lgx-style
  `--with`, so `prompt-state` is simpler than lgx's — do not port the `--with`
  branch or the `:awaiting-value` state.
- `reserved-task-names` in `src/rite/config.lg` already contains `"completion"`
  and `"__complete"`; do not add them again.
- The shell scripts and the `shell-safe-re` regex are security-relevant
  (project-controlled enum values reach the command line on TAB). Port them
  verbatim from lgx — do not "simplify" the no-`compgen -W` bash loop or the
  regex.

---

## Status: Completed (2026-07-12)

All four tasks implemented and verified.

**What was built:** `rite completion <shell>` prints bash/zsh/fish scripts
embedded as string constants in `src/rite/completion.lg`; a hidden
`rite __complete` dispatch branch returns sorted, prefix-filtered candidates —
the project's task names plus the `tasks` built-in at the command position, and
a task arg's declared `[:enum ...]` values at that arg's position. Both commands
are hidden from help and from TAB candidates, and were already reserved as task
names in `config.lg`. `__complete` swallows all errors and exits 0; outside a
project or with a broken `rite.edn`, the `tasks` built-in still completes and
task names drop out. Task names and enum values are both `shell-safe?`-filtered
so completion never inserts active shell syntax on TAB.

**Verification:** 279 unit tests / 349 assertions pass; full `bash tests/run.sh`
(build + unit + 62 e2e assertions) green, including the new Scenario 9. The bash
flow was driven end to end by sourcing `bin/rite completion bash` and exercising
`_rite_complete` via `COMP_WORDS`/`COMP_CWORD` (command names, prefix filter,
enum values, and the `rite --help <TAB>` → nothing case). zsh and fish were not
installed in this environment; their scripts are byte-for-byte ports of lgx's
interactively tested ones. `lgx fmt check` clean.

**Deviations (all recorded inline):**
1. Tasks 1 and 2 were implemented and committed together (cohesive small
   module), and the `__complete` dispatch branch was pulled forward from Task 3.
2. Two Codex-review-driven changes, both intent-preserving hardening: (a) task
   names are `shell-safe?`-filtered too, not only enum values; (b) `prompt-state`
   skips only `--verbose` (mirroring `cli/parse-leading-flags`) instead of every
   `-`-prefixed token, so completion no longer offers task names after a stray
   or terminal flag like `rite --help `.
3. The invalid-config e2e case asserts the exact output (`tasks` only) rather
   than just exit 0 (Codex advisory).

**What the plan could have specified better:** it inherited lgx's
"skip every `-`-prefixed token" word-walk, which is wrong for rite's grammar
(only `--verbose` is a real leading flag) — Codex caught it. A plan that spells
out the exact leading-flag grammar to mirror, rather than "port from lgx", would
have avoided the fixup.
