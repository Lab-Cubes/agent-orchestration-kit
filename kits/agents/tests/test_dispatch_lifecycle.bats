#!/usr/bin/env bats
# test_dispatch_lifecycle.bats — integration tests for spawn-agent.sh dispatch.
#
# Each test builds an isolated kit tree under $BATS_TMPDIR_UNIQUE, copies the
# real scripts/ and templates/ in, mocks the Claude CLI via a stub on PATH,
# and exercises the full dispatch lifecycle. No real Claude process runs and
# no state in the real kit is touched.

load 'helpers/build-kit-tree.bash'

setup() {
    KIT_TMPDIR="$(mktemp -d)"
    build_kit_tree "$KIT_TMPDIR"
}

teardown() {
    rm -rf "${KIT_TMPDIR:-}"
}

# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------

@test "happy path: setup creates mailbox + CLAUDE.md" {
    run run_spawner setup coder-01 coder

    [ "$status" -eq 0 ]
    [ -d "$KIT_AGENTS/coder-01/inbox" ]
    [ -d "$KIT_AGENTS/coder-01/active" ]
    [ -d "$KIT_AGENTS/coder-01/done" ]
    [ -d "$KIT_AGENTS/coder-01/blocked" ]
    [ -f "$KIT_AGENTS/coder-01/CLAUDE.md" ]
}

@test "happy path: dispatch runs mock worker, writes result, appends CSV row" {
    export MOCK_CLAUDE_MODE=happy

    run_spawner setup coder-01 coder
    run run_spawner dispatch coder-01 "smoke test task" \
        --budget 5000 --category code --time-limit 60

    [ "$status" -eq 0 ]

    # Mock claude was invoked
    [ -s "$MOCK_CLAUDE_ARGS_FILE" ]

    # Raw output captured
    local raw_count
    raw_count=$(ls "$KIT_AGENTS/coder-01/done"/*.raw-output.json 2>/dev/null | wc -l | tr -d ' ')
    [ "$raw_count" -ge 1 ]

    # Cost CSV exists with header + at least one data row
    [ -f "$KIT_LOGS/dispatch-costs.csv" ]
    local rows
    rows=$(wc -l < "$KIT_LOGS/dispatch-costs.csv" | tr -d ' ')
    [ "$rows" -eq 2 ]

    local task_id
    task_id=$(echo "$output" | grep -oE 'task-[a-zA-Z0-9_-]+' | head -1)
    [ -n "$task_id" ]
    [ ! -f "$KIT_AGENTS/coder-01/inbox/${task_id}.intent.json" ]
    [ ! -f "$KIT_AGENTS/coder-01/done/${task_id}.unclaimed.intent.json" ]

    local result_file="$KIT_AGENTS/coder-01/done/${task_id}.result.json"
    [ -f "$result_file" ]
    run python3 - "$result_file" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["payload"]["status"] == "completed", d["payload"]["status"]
print("ok")
PYEOF
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# NPT budget flow — regression test for the pre-#18 bug where --budget was
# silently ignored. The CSV's budget_npt column must equal what the operator
# passed.
# ---------------------------------------------------------------------------

@test "--budget N threads through to the CSV budget_npt column" {
    export MOCK_CLAUDE_MODE=happy

    run_spawner setup coder-01 coder
    run run_spawner dispatch coder-01 "budget thread test" \
        --budget 12345 --category code --time-limit 60

    [ "$status" -eq 0 ]

    # CSV schema (post-#18): timestamp,task_id,agent_id,model,category,priority,budget_npt,cost_npt,turns,duration_s,denials,status
    # budget_npt is column 7.
    local row
    row=$(tail -n1 "$KIT_LOGS/dispatch-costs.csv")
    local budget_field
    budget_field=$(echo "$row" | awk -F',' '{gsub(/"/, "", $7); print $7}')

    [ "$budget_field" = "12345" ]
}

# ---------------------------------------------------------------------------
# Cost CSV — NPT columns present, USD columns absent
# (regression test for #18: USD purged from kit)
# ---------------------------------------------------------------------------

@test "cost CSV header has NPT fields and no USD fields" {
    export MOCK_CLAUDE_MODE=happy

    run_spawner setup coder-01 coder
    run_spawner dispatch coder-01 "csv schema test" --category code --time-limit 60

    local header
    header=$(head -n1 "$KIT_LOGS/dispatch-costs.csv")

    # NPT columns present
    echo "$header" | grep -q "budget_npt"
    echo "$header" | grep -q "cost_npt"

    # USD columns absent
    ! echo "$header" | grep -q -i "usd"
}

# ---------------------------------------------------------------------------
# Failure path — mock claude exits non-zero. Dispatch must not crash; it
# must still produce a CSV row (with status=error) and not leave stray state.
# ---------------------------------------------------------------------------

@test "dispatch handles Claude CLI error without crashing" {
    export MOCK_CLAUDE_MODE=error

    run_spawner setup coder-01 coder
    run run_spawner dispatch coder-01 "error path test" --category code --time-limit 60

    # The spawner is intentionally tolerant (|| true on claude invocation) so
    # exit 0 is expected — but a CSV row must be appended.
    [ "$status" -eq 0 ]
    [ -f "$KIT_LOGS/dispatch-costs.csv" ]

    local rows
    rows=$(wc -l < "$KIT_LOGS/dispatch-costs.csv" | tr -d ' ')
    [ "$rows" -eq 2 ]

    # Status column (last field) should be "error" or "success" — not empty.
    local status_field
    status_field=$(tail -n1 "$KIT_LOGS/dispatch-costs.csv" | awk -F',' '{gsub(/"/, "", $12); print $12}')
    [ -n "$status_field" ]
}

@test "#177 no-lifecycle: unclaimed intent fails loudly without result, CSV row, or terminal hook" {
    export MOCK_CLAUDE_MODE=no_claim

    cat > "$KIT_HOOKS/on-task-completed.sh" <<HOOK
#!/usr/bin/env bash
touch "$KIT_TMPDIR/completed-hook-fired"
HOOK
    chmod +x "$KIT_HOOKS/on-task-completed.sh"
    cat > "$KIT_HOOKS/on-task-failed.sh" <<HOOK
#!/usr/bin/env bash
touch "$KIT_TMPDIR/failed-hook-fired"
HOOK
    chmod +x "$KIT_HOOKS/on-task-failed.sh"

    run_spawner setup coder-01 coder
    run run_spawner dispatch coder-01 "no lifecycle test" --category code --time-limit 60

    [ "$status" -ne 0 ]
    echo "$output" | grep -q "KIT-DISPATCH-NO-LIFECYCLE"

    local task_id
    task_id=$(echo "$output" | grep -oE 'task-[a-zA-Z0-9_-]+' | head -1)
    [ -n "$task_id" ]
    [ ! -f "$KIT_AGENTS/coder-01/inbox/${task_id}.intent.json" ]
    [ -f "$KIT_AGENTS/coder-01/done/${task_id}.unclaimed.intent.json" ]
    [ ! -f "$KIT_AGENTS/coder-01/done/${task_id}.result.json" ]

    if [[ -f "$KIT_LOGS/dispatch-costs.csv" ]]; then
        ! grep -q "$task_id" "$KIT_LOGS/dispatch-costs.csv"
    fi
    [ ! -f "$KIT_TMPDIR/completed-hook-fired" ]
    [ ! -f "$KIT_TMPDIR/failed-hook-fired" ]
}

@test "#177 mid-task failure: claimed intent without result still uses fallback synthesis" {
    export MOCK_CLAUDE_MODE=claim_no_result

    run_spawner setup coder-01 coder
    run run_spawner dispatch coder-01 "claimed without result test" --category code --time-limit 60

    [ "$status" -eq 0 ]

    local task_id
    task_id=$(echo "$output" | grep -oE 'task-[a-zA-Z0-9_-]+' | head -1)
    [ -n "$task_id" ]
    [ -f "$KIT_AGENTS/coder-01/done/${task_id}.intent.json" ]
    [ ! -f "$KIT_AGENTS/coder-01/done/${task_id}.unclaimed.intent.json" ]

    local result_file="$KIT_AGENTS/coder-01/done/${task_id}.result.json"
    [ -f "$result_file" ]
    run python3 - "$result_file" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
p = d["payload"]
assert p["status"] == "failed", p["status"]
assert p.get("_fallback") is True
print("ok")
PYEOF
    [ "$status" -eq 0 ]

    [ -f "$KIT_LOGS/dispatch-costs.csv" ]
    grep -q "$task_id" "$KIT_LOGS/dispatch-costs.csv"
}

# ---------------------------------------------------------------------------
# Dry-run must not mutate operator-visible state. Currently the intent file
# is written to inbox/ before the dry-run branch is checked (bug #6), so a
# subsequent real dispatch would pick up the stale intent. This test fails
# against current main and should pass once bug #6 is fixed.
# ---------------------------------------------------------------------------

@test "--dry-run does not write intent file to the inbox" {
    run_spawner setup coder-01 coder
    run run_spawner dispatch coder-01 "dry-run leak test" --dry-run --category code

    [ "$status" -eq 0 ]

    # The operator must still see the intent JSON on stdout (or somewhere
    # non-mailbox) — dry-run's whole point is to preview.
    echo "$output" | grep -q '"_ncp": 1'
    echo "$output" | grep -q '"type": "intent"'

    # But the mailbox must be untouched. Inbox, active, done, blocked all
    # empty — a dry-run is not a dispatch.
    local inbox_count active_count done_count blocked_count
    inbox_count=$(ls "$KIT_AGENTS/coder-01/inbox/" 2>/dev/null | wc -l | tr -d ' ')
    active_count=$(ls "$KIT_AGENTS/coder-01/active/" 2>/dev/null | wc -l | tr -d ' ')
    done_count=$(ls "$KIT_AGENTS/coder-01/done/" 2>/dev/null | wc -l | tr -d ' ')
    blocked_count=$(ls "$KIT_AGENTS/coder-01/blocked/" 2>/dev/null | wc -l | tr -d ' ')
    [ "$inbox_count" -eq 0 ]
    [ "$active_count" -eq 0 ]
    [ "$done_count" -eq 0 ]
    [ "$blocked_count" -eq 0 ]

    # No CSV row either — dry-run is not a cost-logged event.
    if [[ -f "$KIT_LOGS/dispatch-costs.csv" ]]; then
        local rows
        rows=$(wc -l < "$KIT_LOGS/dispatch-costs.csv" | tr -d ' ')
        # Header only (0 or 1 line), no data row.
        [ "$rows" -le 1 ]
    fi
}

# ---------------------------------------------------------------------------
# Branch-name override — bug #5. The spawner currently hardcodes
# branch_name="agent/<id>/<task-id>" at spawn-agent.sh:260 with no way to
# override, so a brief's requested branch name is silently ignored. Fix:
# surface a --branch-name flag.
# ---------------------------------------------------------------------------

# Helper: stand up a throwaway git repo inside the test tree to use as scope.
_init_scope_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" -c user.email=t@t.local -c user.name=t commit --allow-empty -m init -q
}

@test "--branch-name overrides the auto-generated agent/<id>/<task-id>" {
    export MOCK_CLAUDE_MODE=happy

    local scope_repo="$KIT_TREE/scope-repo"
    _init_scope_repo "$scope_repo"

    run_spawner setup coder-01 coder
    run run_spawner dispatch coder-01 "branch-name override test" \
        --scope "$scope_repo" --branch-name "feat/custom-branch" \
        --category code --time-limit 60

    [ "$status" -eq 0 ]

    # Operator-requested branch must exist on the scope repo
    run git -C "$scope_repo" rev-parse --verify --quiet "feat/custom-branch"
    [ "$status" -eq 0 ]

    # Auto-generated pattern must NOT have been created
    local auto_count
    auto_count=$(git -C "$scope_repo" for-each-ref --format='%(refname:short)' \
        'refs/heads/agent/coder-01/*' 2>/dev/null | wc -l | tr -d ' ')
    [ "$auto_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Budget enforcement — dispatcher must terminate the worker when NPT exceeds
# budget_npt and record is_error in the CSV status column.
# ---------------------------------------------------------------------------

@test "--budget kills worker on NPT overrun and records error status" {
    export MOCK_CLAUDE_MODE=budget_exceeded

    run_spawner setup coder-01 coder
    run run_spawner dispatch coder-01 "budget enforcement test" \
        --budget 1000 --category code --time-limit 30

    [ "$status" -eq 0 ]
    [ -f "$KIT_LOGS/dispatch-costs.csv" ]

    local rows
    rows=$(wc -l < "$KIT_LOGS/dispatch-costs.csv" | tr -d ' ')
    [ "$rows" -eq 2 ]

    local status_field
    status_field=$(tail -n1 "$KIT_LOGS/dispatch-costs.csv" | awk -F',' '{gsub(/"/, "", $12); print $12}')
    [ "$status_field" = "error" ]
}

# ---------------------------------------------------------------------------
# Time-limit enforcement — dispatcher must kill the slow worker within
# time_limit seconds and produce a CSV row (not hang indefinitely).
# ---------------------------------------------------------------------------

@test "--time-limit kills slow worker and records error status" {
    export MOCK_CLAUDE_MODE=slow

    run_spawner setup coder-01 coder
    run run_spawner dispatch coder-01 "time-limit enforcement test" \
        --budget 50000 --category code --time-limit 1

    [ "$status" -eq 0 ]
    [ -f "$KIT_LOGS/dispatch-costs.csv" ]

    local rows
    rows=$(wc -l < "$KIT_LOGS/dispatch-costs.csv" | tr -d ' ')
    [ "$rows" -eq 2 ]

    local status_field
    status_field=$(tail -n1 "$KIT_LOGS/dispatch-costs.csv" | awk -F',' '{gsub(/"/, "", $12); print $12}')
    [ "$status_field" = "error" ]
}

@test "default branch name is agent/<id>/<task-id> when --branch-name omitted" {
    export MOCK_CLAUDE_MODE=happy

    local scope_repo="$KIT_TREE/scope-repo"
    _init_scope_repo "$scope_repo"

    run_spawner setup coder-01 coder
    run run_spawner dispatch coder-01 "default branch name test" \
        --scope "$scope_repo" --category code --time-limit 60

    [ "$status" -eq 0 ]

    # Exactly one agent/coder-01/task-* branch must have been created
    local agent_count
    agent_count=$(git -C "$scope_repo" for-each-ref --format='%(refname:short)' \
        'refs/heads/agent/coder-01/*' 2>/dev/null | wc -l | tr -d ' ')
    [ "$agent_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Worker prompt — bug #9. The prompt passed via `claude -p` currently uses
# relative paths (./inbox/, ./active/, ./done/) which resolve against the
# worker's cwd. A worker with a worktree scope may cd into the worktree and
# have relative "./done/" land in the wrong filesystem location. Fix: the
# prompt must reference absolute mailbox paths.
# ---------------------------------------------------------------------------

@test "worker prompt references absolute mailbox paths, not relative" {
    export MOCK_CLAUDE_MODE=happy

    run_spawner setup coder-01 coder
    run_spawner dispatch coder-01 "prompt path semantics test" \
        --category code --time-limit 60

    # The args log captures everything passed to claude, including the
    # -p prompt content.
    [ -s "$MOCK_CLAUDE_ARGS_FILE" ]

    # Absolute mailbox paths must appear so the worker's cwd cannot
    # redirect mailbox operations elsewhere.
    grep -qF "$KIT_AGENTS/coder-01/inbox" "$MOCK_CLAUDE_ARGS_FILE"
    grep -qF "$KIT_AGENTS/coder-01/active" "$MOCK_CLAUDE_ARGS_FILE"
    grep -qF "$KIT_AGENTS/coder-01/done" "$MOCK_CLAUDE_ARGS_FILE"

    # Relative mailbox references must not appear in the prompt. These
    # are the ones that silently break when cwd changes.
    ! grep -qE "\./inbox/" "$MOCK_CLAUDE_ARGS_FILE"
    ! grep -qE "\./active/" "$MOCK_CLAUDE_ARGS_FILE"
    ! grep -qE "\./done/" "$MOCK_CLAUDE_ARGS_FILE"
}

# ---------------------------------------------------------------------------
# Issue #33 — NPT enforcement gaps (concerns #1–#5).
#
# Test labelling per plan:
#   (a) bug-proving (RED)  — concern #1: cache_creation_input_tokens excluded
#   (b) bug-proving (RED)  — concern #2: no 1.05× NPT exchange rate applied
#   (c) bug-proving (RED)  — concern #3: no soft cap; overshoot_ratio column absent
#   (d) bug-proving (RED)  — concern #4: SIGTERM kills worker; SIGINT trap never fires
#   (e) bug-proving (RED)  — concern #5: forced-result stuffs accum_npt into output_tokens
# ---------------------------------------------------------------------------

# (a) bug-proving — RED until concern #1 fix lands
# cache_creation mode: input=1000, output=500, cache_creation=200, cache_read=0
# Today (3-channel, no rate): 1000+500+0 = 1500
# After fix (4-channel + 1.05×): ceil((1000+500+200+0) * 1.05) = 1785
@test "#33(a) cost_npt counts cache_creation_input_tokens" {
    export MOCK_CLAUDE_MODE=cache_creation

    run_spawner setup coder-01 coder
    run run_spawner dispatch coder-01 "cache_creation npt test" \
        --budget 50000 --category code --time-limit 30

    [ "$status" -eq 0 ]

    local row cost_npt_field
    row=$(tail -n1 "$KIT_LOGS/dispatch-costs.csv")
    cost_npt_field=$(echo "$row" | awk -F',' '{gsub(/"/, "", $8); print $8}')

    [ "$cost_npt_field" = "1785" ]
}

# (b) bug-proving — RED until concern #2 fix lands
# rate_check mode: input=1000, output=500, cache_creation=0, cache_read=0
# Today (no rate): 1500
# After fix (1.05× Claude rate): ceil(1500 * 1.05) = ceil(1575) = 1575
@test "#33(b) cost_npt applies 1.05x NPT exchange rate for claude model family" {
    export MOCK_CLAUDE_MODE=rate_check

    run_spawner setup coder-01 coder
    run run_spawner dispatch coder-01 "exchange rate npt test" \
        --budget 50000 --category code --time-limit 30

    [ "$status" -eq 0 ]

    local row cost_npt_field
    row=$(tail -n1 "$KIT_LOGS/dispatch-costs.csv")
    cost_npt_field=$(echo "$row" | awk -F',' '{gsub(/"/, "", $8); print $8}')

    [ "$cost_npt_field" = "1575" ]
}

# (c) bug-proving — RED until concern #3 fix lands
# Note: mock token count is native; soft cap compares post-rate NPT.
# budget_exceeded emits 5M native tokens; with budget=1000, soft_cap=900 NPT.
# Today: hard-cap check only, no soft_cap stop_reason, no overshoot_ratio column.
# After fix: soft_cap fires at 900 NPT (well below 5M*1.05), overshoot_ratio logged.
@test "#33(c) CSV has overshoot_ratio column and stop_reason reflects soft cap" {
    export MOCK_CLAUDE_MODE=budget_exceeded

    run_spawner setup coder-01 coder
    run run_spawner dispatch coder-01 "soft cap test" \
        --budget 1000 --category code --time-limit 30

    [ "$status" -eq 0 ]

    local header
    header=$(head -n1 "$KIT_LOGS/dispatch-costs.csv")
    echo "$header" | grep -q "overshoot_ratio"

    local raw_file
    raw_file=$(ls "$KIT_AGENTS/coder-01/done/"*.raw-output.json 2>/dev/null | head -1)
    [ -f "$raw_file" ]

    run python3 -c "
import json, sys
d = json.load(open('$raw_file'))
assert d.get('stop_reason') == 'soft_cap', \
    f'expected stop_reason=soft_cap, got {d.get(\"stop_reason\")!r}'
print('ok')
"
    [ "$status" -eq 0 ]
}

# (d) bug-proving — RED until concern #4 fix lands
# sigint_handler mock: emits 5M tokens (triggers kill), traps SIGINT, emits
# result event "SIGINT graceful shutdown". Today dispatcher sends SIGTERM →
# mock's INT trap never fires → forced path → result = "Worker terminated: ...".
# After fix (SIGINT-first ladder): INT trap fires → result event collected →
# raw-output result = "SIGINT graceful shutdown".
@test "#33(d) graceful SIGINT shutdown uses worker result event over forced path" {
    export MOCK_CLAUDE_MODE=sigint_handler

    run_spawner setup coder-01 coder
    run run_spawner dispatch coder-01 "sigint grace test" \
        --budget 1000 --category code --time-limit 30

    [ "$status" -eq 0 ]

    local raw_file
    raw_file=$(ls "$KIT_AGENTS/coder-01/done/"*.raw-output.json 2>/dev/null | head -1)
    [ -f "$raw_file" ]

    run python3 -c "
import json, sys
d = json.load(open('$raw_file'))
assert d.get('result') == 'SIGINT graceful shutdown', \
    f'expected SIGINT graceful shutdown, got {d.get(\"result\")!r}'
print('ok')
"
    [ "$status" -eq 0 ]
}

# (e) bug-proving — RED until concern #5 fix lands
# budget_exceeded: input=5M, output=0, cache_creation=0, cache_read=0
# Today forced-result: usage={input:0, output:5000000, cache_read:0}
#   (accum_npt stuffed into output_tokens; cache_creation absent)
# After fix: usage={input:5000000, output:0, cache_read:0, cache_creation:0}
#   + _terminated_npt field present
@test "#33(e) forced-result usage preserves per-channel native counts" {
    export MOCK_CLAUDE_MODE=budget_exceeded

    run_spawner setup coder-01 coder
    run run_spawner dispatch coder-01 "forced channels test" \
        --budget 1000 --category code --time-limit 30

    [ "$status" -eq 0 ]

    local raw_file
    raw_file=$(ls "$KIT_AGENTS/coder-01/done/"*.raw-output.json 2>/dev/null | head -1)
    [ -f "$raw_file" ]

    run python3 -c "
import json, sys
d = json.load(open('$raw_file'))
u = d.get('usage', {})
assert 'cache_creation_input_tokens' in u, \
    f'usage missing cache_creation_input_tokens: {u}'
assert '_terminated_npt' in d, \
    f'missing _terminated_npt field: {list(d.keys())}'
assert u.get('input_tokens') == 5000000, \
    f'input_tokens should be 5000000, got {u.get(\"input_tokens\")}'
assert u.get('output_tokens') == 0, \
    f'output_tokens should be 0 (not accum_npt), got {u.get(\"output_tokens\")}'
print('ok')
"
    [ "$status" -eq 0 ]
}
