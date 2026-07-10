#!/usr/bin/env bash
# E2E tests for the rite bundle. Drives bin/rite (self-contained — the bundle
# re-execs itself for :run steps, so no external lg is needed) against
# throwaway RITE_HOME dirs and a file:// git dep seeded per test. Hermetic — no
# network.
#
# Run with: bash tests/e2e.sh   (from project root; build bin/rite first)

set -eu

# Every scenario sets its own RITE_HOME, but blank XDG_CACHE_HOME anyway so a
# caller's value can never leak into the default-home fallback.
export XDG_CACHE_HOME=""

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RITE="$ROOT/bin/rite"

[[ -x "$RITE" ]] || { echo "FAIL: $RITE not built (run: lgx build)" >&2; exit 1; }

# Git identity so seed commits work without global config (matters in CI).
export GIT_AUTHOR_NAME=rite-test
export GIT_AUTHOR_EMAIL=rite@test.invalid
export GIT_COMMITTER_NAME=rite-test
export GIT_COMMITTER_EMAIL=rite@test.invalid

PASS_COUNT=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "  PASS: $1"; }
skip() { echo "  SKIP: $1"; }

assert_contains() {
    local haystack="$1"; local needle="$2"; local label="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "---- output ----" >&2; echo "$haystack" >&2
        echo "---- expected to contain: $needle ----" >&2
        fail "$label"
    fi
    pass "$label"
}

assert_not_contains() {
    local haystack="$1"; local needle="$2"; local label="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "---- output ----" >&2; echo "$haystack" >&2
        echo "---- expected NOT to contain: $needle ----" >&2
        fail "$label"
    fi
    pass "$label"
}

assert_eq() {
    local actual="$1"; local expected="$2"; local label="$3"
    if [[ "$actual" != "$expected" ]]; then
        echo "---- actual ----" >&2; echo "$actual" >&2
        echo "---- expected ----" >&2; echo "$expected" >&2
        fail "$label"
    fi
    pass "$label"
}

has_esc() { printf '%s' "$1" | grep -q $'\x1b'; }

# Seed a bare git repo with one commit containing src/greetlib.lg (a let-go
# library the :run scenario requires) and a v0.1.0 tag. Echoes the resolved sha.
make_bare_repo() {
    local bare="$1"; local work
    work="$(mktemp -d)"
    git init --quiet --bare "$bare"
    git clone --quiet "$bare" "$work" 2>/dev/null
    mkdir -p "$work/src"
    cat > "$work/src/greetlib.lg" <<'EOF'
(ns greetlib)
(defn hello [name] (str "hello " name " from dep"))
EOF
    git -C "$work" add .
    git -C "$work" commit --quiet -m "seed"
    git -C "$work" tag v0.1.0
    git -C "$work" push --quiet origin master 2>/dev/null \
        || git -C "$work" push --quiet origin main
    git -C "$work" push --quiet origin v0.1.0
    local sha; sha="$(git -C "$work" rev-parse HEAD)"
    rm -rf "$work"
    echo "$sha"
}

# ---------------------------------------------------------------------------
echo "==> Scenario 1: usage / tasks listing / no-project / empty tasks"
out="$("$RITE" help)"
assert_contains "$out" "rite - task runner for any project" "help: synopsis"
assert_contains "$out" "Usage: rite" "help: usage line"
assert_contains "$out" "rite tasks" "help: lists tasks command"

# bare `rite` behaves like help
out_bare="$("$RITE")"
assert_contains "$out_bare" "Usage: rite" "bare rite: prints usage"

proj="$(mktemp -d)"; home="$(mktemp -d)"
cat > "$proj/rite.edn" <<'EOF'
{:tasks {fmt {:doc "Format sources" :do [{:sh "echo fmt"}]}
         deploy {:doc "Deploy" :args [{:name :env}] :do [{:sh "echo d"}]}}}
EOF
out="$(cd "$proj" && RITE_HOME="$home" "$RITE" help)"
assert_contains "$out" "Tasks:" "help: shows Tasks block"
assert_contains "$out" "rite fmt" "help: task row uses rite prefix"
assert_contains "$out" "Format sources" "help: shows :doc"
assert_contains "$out" "rite deploy <env>" "help: shows arg signature"

out="$(cd "$proj" && RITE_HOME="$home" "$RITE" tasks)"
assert_contains "$out" "rite fmt" "tasks: lists fmt"
assert_not_contains "$out" "Usage:" "tasks: list only (no synopsis)"

noproj="$(mktemp -d)"
set +e; out="$(cd "$noproj" && "$RITE" tasks 2>&1)"; rc=$?; set -e
[[ $rc -eq 1 ]] || fail "tasks no-project: expected exit 1 (got $rc)"
assert_contains "$out" "no rite.edn found" "tasks no-project: error message"
rm -rf "$noproj"

proj_e="$(mktemp -d)"; echo '{}' > "$proj_e/rite.edn"
set +e; out="$(cd "$proj_e" && RITE_HOME="$home" "$RITE" tasks 2>&1)"; rc=$?; set -e
[[ $rc -eq 0 ]] || fail "tasks empty: expected exit 0 (got $rc)"
assert_contains "$out" "no tasks defined in rite.edn" "tasks empty: friendly message"
rm -rf "$proj" "$proj_e" "$home"

# ---------------------------------------------------------------------------
echo "==> Scenario 2: :sh task runs, streams, exit code propagates"
proj="$(mktemp -d)"; home="$(mktemp -d)"
cat > "$proj/rite.edn" <<'EOF'
{:tasks {hi {:do [{:sh "echo hi-from-task"}]}
         fail {:do [{:sh "echo before"} {:sh "exit 7"} {:sh "echo after"}]}}}
EOF
out="$(cd "$proj" && RITE_HOME="$home" "$RITE" hi 2>/dev/null)"
assert_eq "$out" "hi-from-task" ":sh: single step output"
set +e; out="$(cd "$proj" && RITE_HOME="$home" "$RITE" fail 2>/dev/null)"; rc=$?; set -e
[[ $rc -eq 7 ]] || fail ":sh fail: expected exit 7 (got $rc)"
pass ":sh fail: propagates exit code 7"
assert_contains "$out" "before" ":sh fail: first step ran"
assert_not_contains "$out" "after" ":sh fail: later step skipped"
rm -rf "$proj" "$home"

# ---------------------------------------------------------------------------
echo "==> Scenario 3: {{var/*}} + :var/kw substitution (incl. shell-quoting)"
proj="$(mktemp -d)"; home="$(mktemp -d)"
cat > "$proj/rite.edn" <<'EOF'
{:vars {:version "1.2.0" :greeting "hi there"}
 :tasks {tmpl {:do [{:sh "echo v{{var/version}}"}]}
         kw   {:do [{:sh ["echo" :var/greeting]}]}
         raw  {:do [{:sh "echo '{{ untouched }}'"}]}}}
EOF
out="$(cd "$proj" && RITE_HOME="$home" "$RITE" tmpl 2>/dev/null)"
assert_eq "$out" "v1.2.0" "{{var/*}}: expands in :sh string"
out="$(cd "$proj" && RITE_HOME="$home" "$RITE" kw 2>/dev/null)"
assert_eq "$out" "hi there" ":var/kw: shell-quoted, spaces stay one arg"
out="$(cd "$proj" && RITE_HOME="$home" "$RITE" raw 2>/dev/null)"
assert_eq "$out" "{{ untouched }}" "non-token {{...}}: passes through verbatim"

# unknown prefixed token is a load error: invoking an unrelated valid task
# still fails, so the rejection can only come from config loading, not from
# runtime expansion of the malformed step.
cat > "$proj/rite.edn" <<'EOF'
{:tasks {tmpl {:do [{:sh "echo v{{var/missing}}"}]}
         ok   {:do [{:sh "echo fine"}]}}}
EOF
set +e; out="$(cd "$proj" && RITE_HOME="$home" "$RITE" ok 2>&1)"; rc=$?; set -e
[[ $rc -eq 1 ]] || fail "unknown {{var/*}} token: expected exit 1 (got $rc)"
assert_contains "$out" "invalid rite.edn" "unknown {{var/*}} token: rejected at load"
assert_contains "$out" "placeholder :var/missing used but no :vars defined" "unknown {{var/*}} token: load error message"
rm -rf "$proj" "$home"

# ---------------------------------------------------------------------------
echo "==> Scenario 4: :args defaults, enum rejection, too-many"
proj="$(mktemp -d)"; home="$(mktemp -d)"
cat > "$proj/rite.edn" <<'EOF'
{:tasks {deploy {:args [{:name :env :type [:enum "prod" "staging"]}
                        {:name :tag :default "latest"}]
                 :do [{:sh "echo {{arg/env}} {{arg/tag}}"}]}
         noargs {:do [{:sh "echo hi"}]}}}
EOF
out="$(cd "$proj" && RITE_HOME="$home" "$RITE" deploy prod 2>/dev/null)"
assert_eq "$out" "prod latest" "args: default fills omitted trailing"
set +e; out="$(cd "$proj" && RITE_HOME="$home" "$RITE" deploy qa 2>&1)"; rc=$?; set -e
[[ $rc -eq 1 ]] || fail "args enum: expected exit 1 (got $rc)"
assert_contains "$out" "must be one of: prod, staging" "args enum: rejection message"
assert_contains "$out" "usage: rite deploy" "args enum: usage line"
set +e; out="$(cd "$proj" && RITE_HOME="$home" "$RITE" noargs extra 2>&1)"; rc=$?; set -e
[[ $rc -eq 1 ]] || fail "args too-many: expected exit 1 (got $rc)"
assert_contains "$out" "task takes no arguments" "args too-many: message"
rm -rf "$proj" "$home"

# ---------------------------------------------------------------------------
echo "==> Scenario 5: :depends order, diamond dedup, forwarding, failure, cycle"
proj="$(mktemp -d)"; home="$(mktemp -d)"
cat > "$proj/rite.edn" <<'EOF'
{:tasks {a {:do [{:sh "echo mark-a"}]}
         b {:depends [a] :do [{:sh "echo mark-b"}]}
         c {:depends [a] :do [{:sh "echo mark-c"}]}
         d {:depends [b c] :do [{:sh "echo mark-d"}]}}}
EOF
out="$(cd "$proj" && RITE_HOME="$home" "$RITE" d 2>/dev/null)"
assert_eq "$out" "mark-a
mark-b
mark-c
mark-d" ":depends: diamond runs a once, depth-first listed order"
rm -rf "$proj" "$home"

proj="$(mktemp -d)"; home="$(mktemp -d)"
cat > "$proj/rite.edn" <<'EOF'
{:tasks {notify {:args [{:name :env}] :do [{:sh "echo notify-{{arg/env}}"}]}
         deploy {:args [{:name :env :type [:enum "prod" "staging"]}]
                 :depends [[notify :arg/env]]
                 :do [{:sh "echo deploy-{{arg/env}}"}]}}}
EOF
out="$(cd "$proj" && RITE_HOME="$home" "$RITE" deploy prod 2>/dev/null)"
assert_eq "$out" "notify-prod
deploy-prod" ":depends: arg forwarding [notify :arg/env]"
rm -rf "$proj" "$home"

proj="$(mktemp -d)"; home="$(mktemp -d)"
cat > "$proj/rite.edn" <<'EOF'
{:tasks {boom {:do [{:sh "echo boom-ran"} {:sh "exit 5"}]}
         top {:depends [boom] :do [{:sh "echo top-ran"}]}}}
EOF
set +e; out="$(cd "$proj" && RITE_HOME="$home" "$RITE" top 2>/dev/null)"; rc=$?; set -e
[[ $rc -eq 5 ]] || fail ":depends failure: expected exit 5 (got $rc)"
pass ":depends failure: propagates dep's exit code 5"
assert_contains "$out" "boom-ran" ":depends failure: dep step ran"
assert_not_contains "$out" "top-ran" ":depends failure: dependent skipped"
rm -rf "$proj" "$home"

proj="$(mktemp -d)"; home="$(mktemp -d)"
cat > "$proj/rite.edn" <<'EOF'
{:tasks {a {:depends [b]} b {:depends [a]}}}
EOF
set +e; out="$(cd "$proj" && RITE_HOME="$home" "$RITE" a 2>&1)"; rc=$?; set -e
[[ $rc -eq 1 ]] || fail ":depends cycle: expected exit 1 (got $rc)"
assert_contains "$out" "dependency cycle" ":depends cycle: load-time error"
rm -rf "$proj" "$home"

# ---------------------------------------------------------------------------
echo "==> Scenario 6: :run task with a file:// git dep and a task :paths dir"
if command -v git >/dev/null 2>&1; then
    home="$(mktemp -d)"
    bare="$home/_fixtures/greet.git"
    mkdir -p "$(dirname "$bare")"
    sha="$(make_bare_repo "$bare")"
    proj="$(mktemp -d)"
    mkdir -p "$proj/scripts"
    cat > "$proj/scripts/helper.lg" <<'EOF'
(ns helper)
(defn marker [] "helper-from-paths")
EOF
    cat > "$proj/scripts/hi.lg" <<'EOF'
(ns hi
  (:require [greetlib]
            [helper]))
(println (greetlib/hello (first *command-line-args*)))
(println (helper/marker))
EOF
    cat > "$proj/rite.edn" <<EOF
{:tasks
 {say {:doc "Run a script via the embedded runtime"
       :paths ["scripts"]
       :deps {test/greet {:git/url "file://$bare"
                          :git/sha "$sha"}}
       :do [{:run ["scripts/hi.lg" "world"]}]}}}
EOF
    out="$(cd "$proj" && RITE_HOME="$home" "$RITE" say 2>&1)"
    assert_contains "$out" "hello world from dep" \
        ":run: script requires the git dep namespace + gets its arg"
    assert_contains "$out" "helper-from-paths" \
        ":run: script requires a namespace from the task :paths dir"
    [[ -d "$home/gitlibs/_local/_/greet/$sha" ]] \
        || fail ":run: dep not fetched at \$RITE_HOME/gitlibs/_local/_/greet/$sha"
    pass ":run: dep fetched into \$RITE_HOME/gitlibs"
    assert_contains "$out" "installing 1 dep(s)..." ":run: first run installs the dep"
    out2="$(cd "$proj" && RITE_HOME="$home" "$RITE" say 2>&1)"
    assert_not_contains "$out2" "installing" ":run: second run reuses the cache"
    assert_contains "$out2" "hello world from dep" ":run: second run still works"
    rm -rf "$proj" "$home"
else
    skip ":run scenario requires git"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 7: config validation errors"
proj="$(mktemp -d)"; home="$(mktemp -d)"
echo '{:contexts {}}' > "$proj/rite.edn"
set +e; out="$(cd "$proj" && RITE_HOME="$home" "$RITE" tasks 2>&1)"; rc=$?; set -e
[[ $rc -eq 1 ]] || fail "config unknown-root-key: expected exit 1 (got $rc)"
assert_contains "$out" "unknown key :contexts" "config: unknown root key reported"

echo '{:tasks {t {:extra-deps {} :do [{:sh "echo hi"}]}}}' > "$proj/rite.edn"
set +e; out="$(cd "$proj" && RITE_HOME="$home" "$RITE" t 2>&1)"; rc=$?; set -e
[[ $rc -eq 1 ]] || fail "config unknown-task-key: expected exit 1 (got $rc)"
assert_contains "$out" "unknown key :extra-deps" "config: unknown task key (typo) reported"

echo '{:tasks {version {:do [{:sh "echo hi"}]}}}' > "$proj/rite.edn"
set +e; out="$(cd "$proj" && RITE_HOME="$home" "$RITE" tasks 2>&1)"; rc=$?; set -e
[[ $rc -eq 1 ]] || fail "config reserved-name: expected exit 1 (got $rc)"
assert_contains "$out" "conflicts with built-in command" "config: reserved task name reported"
rm -rf "$proj" "$home"

# ---------------------------------------------------------------------------
echo "==> Scenario 8: RITE_NO_COLOR disables escape codes"
proj="$(mktemp -d)"; home="$(mktemp -d)"
cat > "$proj/rite.edn" <<'EOF'
{:tasks {hi {:do [{:sh "echo hi"}]}}}
EOF
out="$(cd "$proj" && RITE_NO_COLOR=1 RITE_HOME="$home" "$RITE" hi 2>&1)"
if has_esc "$out"; then fail "RITE_NO_COLOR: output still had escape codes"; fi
pass "RITE_NO_COLOR: no escape codes in output"
# Clear RITE_NO_COLOR explicitly so a caller that already exported it doesn't
# turn this default-color assertion into a spurious failure.
out_c="$(cd "$proj" && RITE_NO_COLOR= RITE_HOME="$home" "$RITE" hi 2>&1)"
if has_esc "$out_c"; then
    pass "default: colored headers contain escape codes"
else
    fail "default: expected colored output but found none"
fi
rm -rf "$proj" "$home"

# ---------------------------------------------------------------------------
echo
echo "All e2e scenarios passed ($PASS_COUNT assertions)."
