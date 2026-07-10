# Template Prefixes Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace bare `{{name}}` string templates with mandatory namespaced tokens `{{arg/<name>}}` / `{{var/<name>}}`, validated at load time; every other `{{...}}` passes through as plain text.

**Tech Stack:** let-go (lg), lgx build/test, bash e2e harness.

---

## Design

### Current behavior

Two placeholder forms reference a task's bound args and the project vars:

- `:arg/<name>` / `:var/<name>` keywords in step **vectors**, validated at
  load time (`step-ref-errors` / `depends-entry-ref-errors` in
  `src/rite/config.lg`).
- Bare `{{name}}` tokens in **strings** (`expand` in `src/rite/args.lg`),
  looked up arg-first-then-var (args shadow vars), unknown tokens pass
  through, never a load error, inner whitespace not trimmed.

### New behavior

String tokens become the keyword placeholders in string clothing:

- `{{arg/<name>}}` and `{{var/<name>}}` are the only recognized tokens.
  Whitespace inside the delimiters is insignificant: `{{ var/version }}`
  ≡ `{{var/version}}`.
- Recognized tokens are validated at load time exactly like the keyword
  forms: `{{arg/x}}` in a task's step string must name that task's declared
  arg; `{{var/x}}` must name a defined var; in a `:depends` tail string,
  `{{arg/x}}` must name the *parent's* declared arg.
- Any other `{{...}}` content — `{{name}}`, `{{ github.sha }}`, `{{a/b/c}}`,
  `{{}}`, unclosed `{{` — passes through untouched and is never an error.
  This keeps foreign template syntax (Jinja, Actions, frame) safe inside
  step strings.
- The arg-shadows-var rule is deleted; the token itself names its namespace.
- No backward compatibility: bare `{{name}}` simply stops being a token.

### Token grammar

Between `{{` and the first following `}}`, after trimming surrounding
whitespace: `arg/` or `var/` followed by a name that is non-empty and
contains no `/`, no whitespace, and no `{` or `}`. Parse result is the
keyword `:arg/<name>` or `:var/<name>`; anything else is not a token.

### Key decisions

- **Whitespace-insensitive delimiters.** Today `{{ version }}` silently
  fails to expand — a footgun. Trimming matches frame/Liquid style.
- **Non-tokens always pass through, never error.** Step strings
  legitimately contain `{{ }}` destined for other tools; only unambiguous
  `arg/`/`var/` tokens are rite's.
- **Runtime unbound recognized token throws** `ex-info` (mirroring
  `substitute`). Unreachable after load validation, but a loud failure
  beats silent pass-through if a code path ever skips validation.
- **`entry-value-checkable?` tightens (a win):** a `:depends` tail string
  is literal unless it contains a *recognized* token, so
  `[notify "v{{foreign}}"]` becomes value-checkable against the dep's
  `:args` at load, while `[notify "v{{var/version}}"]` stays lenient.
- **Shared scanner.** One `template-tokens` function in `rite.args` is the
  single definition of the grammar, used by both `expand` and the config
  validation passes.
- **Rescan behavior kept:** on a non-token, emit through the opening `{{`
  and rescan right after, so `{{x{{arg/env}}` still expands the inner
  token. Substituted values are never re-scanned.

### Out of scope

- This repo's own `lgx.edn` uses `{{action}}` — that is lgx's syntax, a
  different tool. Untouched.
- frame's `{% raw %}` escape tag (separate project).

## File Structure

- Modify: `src/rite/args.lg` — token parser + `template-tokens` scanner;
  rewrite `expand`; drop the shadowing note from `task-bindings`; update
  the ns header comment.
- Modify: `src/rite/config.lg` — scan strings in `step-ref-errors` and
  `depends-entry-ref-errors`; retarget `entry-value-checkable?`; update
  comments (`depends-item-errors` docstring, cross-check section comments).
- Modify: `src/rite/tasks.lg`, `src/rite/plan.lg` — docstrings/comments only.
- Modify: `test/rite/args_test.lg`, `test/rite/tasks_test.lg`,
  `test/rite/plan_test.lg` — new token syntax; shadowing tests become
  pass-through tests.
- Modify: `test/rite/config_test.lg` — load-error cases for unknown
  prefixed tokens in strings; checkability cases.
- Modify: `README.md` — Placeholders and `:vars` sections, all examples.
- Modify: `tests/e2e.sh` — template scenarios plus a pass-through assertion.

### Task 1: Scanner and expand (`rite.args`)

**Files:**
- Modify: `src/rite/args.lg`
- Modify: `src/rite/tasks.lg` (comments), `src/rite/plan.lg` (comments)
- Test: `test/rite/args_test.lg`, `test/rite/tasks_test.lg`, `test/rite/plan_test.lg`

- [ ] **Step 1: Rewrite the expand tests**
  In `test/rite/args_test.lg`, replace the bare-token tests (lines ~170–225)
  with the new grammar. Cover: `{{arg/name}}` and `{{var/name}}` expansion;
  spaced form `{{ var/version }}` expands; adjacent tokens
  (`{{arg/env}}-{{var/version}}`); bare `{{name}}` passes through even when
  an arg/var of that name is bound (the old shadowing tests inverted);
  foreign syntax pass-through (`{{ github.sha }}`, `{{a/b/c}}`, `{{}}`,
  name with inner space like `{{arg/a b}}`); unclosed `{{`; rescan
  (`{{x{{arg/env}}` → `{{xprod`); substituted values never re-scanned
  (`:arg/a` bound to `"{{var/b}}"` stays literal); raw splice unchanged
  (value with `;` not quoted); recognized-but-unbound token throws ex-info
  (e.g. `{{arg/env}}` with empty bindings).
  Add `template-tokens` tests: returns `[:arg/env :var/version]` in
  document order from a mixed string; `[]` for plain text and for
  non-tokens; duplicates preserved.

- [ ] **Step 2: Update downstream test fixtures**
  Switch tokens in `test/rite/tasks_test.lg` (`{{msg}}` → `{{arg/msg}}`,
  `{{version}}` → `{{var/version}}`, `{{env}}` → `{{arg/env}}`) and
  `test/rite/plan_test.lg` (`echo {{version}}` → `echo {{var/version}}`,
  dep entry `"v{{version}}"` → `"v{{var/version}}"`).

- [ ] **Step 3: Run tests to verify they fail**
  Run: `lgx test`
  Expected: FAIL — new-grammar assertions in `args_test`, `tasks_test`,
  `plan_test`; `template-tokens` unresolved.

- [ ] **Step 4: Implement the scanner and new expand**
  In `src/rite/args.lg`:
  - A private `parse-token` helper: inner text → `:arg/<name>` /
    `:var/<name>` keyword or nil, per the grammar above (trim, prefix
    check, name charset check).
  - Public `template-tokens`: scan a string with the same `{{`/`}}` walk
    as `expand`, returning a vector of parsed keywords in order.
  - Rewrite `expand`'s lookup: parse the token; nil → pass-through with
    the existing emit-and-rescan strategy; parsed but unbound → throw
    ex-info `(str "unbound placeholder " k)` with `{:placeholder k}`;
    bound → splice raw. Keep never-rescan-substituted-values.
  - Update the `expand` docstring, `task-bindings` docstring (shadowing
    gone), and the ns/section comments in `args.lg`, `tasks.lg` (lines
    19–23), `plan.lg` (`resolve-item` docstring).

- [ ] **Step 5: Run tests to verify they pass**
  Run: `lgx test`
  Expected: PASS.

- [ ] **Step 6: Commit**
  `git commit -m "feat: require arg/ and var/ prefixes in string templates"`

### Task 2: Load-time validation (`rite.config`)

**Files:**
- Modify: `src/rite/config.lg`
- Test: `test/rite/config_test.lg`

- [ ] **Step 1: Write the failing validation tests**
  In `test/rite/config_test.lg`:
  - A string step value with an unknown token errors:
    `{:sh "echo {{arg/x}}"}` with no `:args` → error at path
    `[:tasks <name> :do ... :sh]`, message matching the existing
    "used but no :args declared" / "unknown placeholder ... (declared: ...)"
    style. Same for `{{var/x}}` vs `:vars`.
  - A string item *inside* a step vector is scanned:
    `{:sh ["echo" "{{var/x}}"]}` with no `:vars` → error at `[:sh 1]`.
  - Valid tokens pass; bare `{{name}}` and foreign `{{...}}` are never
    load errors (update the existing lenient test at ~line 64 to use
    prefixed tokens where it expects validity).
  - `:depends` tail strings: `['notify "v{{arg/x}}"]` with parent
    declaring no args → error; `"v{{var/x}}"` with no such var → error.
  - Checkability: `['notify "v{{foreign}}"]` where notify declares zero
    args → load error (arity mismatch now caught);
    `['notify "v{{var/version}}"]` with `version` defined → no error
    (update the lenient test at ~line 529).

- [ ] **Step 2: Run tests to verify they fail**
  Run: `lgx test`
  Expected: FAIL on the new config cases only.

- [ ] **Step 3: Implement**
  In `src/rite/config.lg`:
  - `step-ref-errors`: handle a **string** step value (scan with
    `args/template-tokens`, errors at path `[k]`) and string items in
    vectors (errors at `[k j]`), alongside the existing keyword checks.
    Factor the unknown-arg/unknown-var message construction so keyword
    items and string tokens share it.
  - `depends-entry-ref-errors`: for string tail items, run each token of
    `args/template-tokens` through the same arg-forwarding/var checks as
    keyword items.
  - `entry-value-checkable?`: an item is literal iff it is a string with
    `(empty? (args/template-tokens item))`.
  - Update `depends-item-errors` docstring and the cross-check section
    comments (config.lg ~lines 250, 341, 418–424).

- [ ] **Step 4: Run tests to verify they pass**
  Run: `lgx test`
  Expected: PASS.

- [ ] **Step 5: Commit**
  `git commit -m "feat: validate {{arg/*}}/{{var/*}} string tokens at load time"`

### Task 3: Docs and e2e

**Files:**
- Modify: `README.md`
- Modify: `tests/e2e.sh`

- [ ] **Step 1: Update README**
  - Quickstart/reference examples: `{{version}}` → `{{var/version}}`.
  - `:vars` section: "Reference a var as `{{var/name}}` in any step string
    or as `:var/name` in a step vector."
  - Placeholders section: describe the two forms symmetrically; state the
    grammar (whitespace inside delimiters insignificant), that prefixed
    tokens are validated at load exactly like keyword placeholders, that
    any other `{{...}}` passes through untouched (safe for text destined
    for other template tools), and that string splices are raw/unquoted.
    Remove the shadowing sentence and the "`{{...}}` tokens are never a
    load error" sentence.
  Use /writing-clearly.

- [ ] **Step 2: Update e2e scenarios**
  In `tests/e2e.sh`: switch Scenario 3 and the deploy/notify fixtures to
  prefixed tokens (`{{var/version}}`, `{{arg/env}}`, `{{arg/tag}}`); add
  one assertion that a non-token (e.g. `echo '{{ untouched }}'`) passes
  through verbatim; add one assertion that an unknown prefixed token in
  rite.edn fails at load with exit 1 and an "unknown placeholder" message.

- [ ] **Step 3: Run the full check**
  Run: `lgx check`
  Expected: fmt, lint, build, unit, and e2e all PASS.

- [ ] **Step 4: Commit**
  `git commit -m "docs: document prefixed template tokens; update e2e"`
