#!/usr/bin/env bats
# test_json_extraction.bats — unit tests for kits/agents/scripts/lib/extract_result_json.py

HELPER="$BATS_TEST_DIRNAME/../scripts/lib/extract_result_json.py"

# ---------------------------------------------------------------------------
# 1. Single-line JSON passes through unchanged (regression guard)
# ---------------------------------------------------------------------------
@test "single-line JSON passes through unchanged" {
    run bash -c 'echo '"'"'{"result":"ok","usage":{}}'"'"' | python3 '"\"$HELPER\""
    [ "$status" -eq 0 ]
    [ "$output" = '{"result":"ok","usage":{}}' ]
}

# ---------------------------------------------------------------------------
# 2. Multi-line pretty-printed JSON is extracted in full (bug-proving — FAILS at RED)
# ---------------------------------------------------------------------------
@test "multi-line pretty-printed JSON is extracted in full" {
    run bash -c 'printf '"'"'{\n  "result": "ok",\n  "usage": {},\n  "cost": 1.5\n}\n'"'"' | python3 '"\"$HELPER\""
    [ "$status" -eq 0 ]
    python3 -c "import json,sys; json.loads(sys.stdin.read())" <<< "$output"
}

# ---------------------------------------------------------------------------
# 3. JSON after log-prefix lines is extracted (bug-proving — FAILS at RED)
# ---------------------------------------------------------------------------
@test "JSON after log-prefix lines is extracted" {
    run bash -c 'printf '"'"'worker started\n{"result":"ok"}\n'"'"' | python3 '"\"$HELPER\""
    [ "$status" -eq 0 ]
    [ "$output" = '{"result":"ok"}' ]
}

# ---------------------------------------------------------------------------
# 4. JSON before trailing log lines is extracted (regression guard — may pass at RED)
# ---------------------------------------------------------------------------
@test "JSON before trailing log lines is extracted" {
    run bash -c 'printf '"'"'{"result":"ok"}\nfinal log line\n'"'"' | python3 '"\"$HELPER\""
    [ "$status" -eq 0 ]
    [ "$output" = '{"result":"ok"}' ]
}

# ---------------------------------------------------------------------------
# 5. Last JSON object wins when multiple are present (bug-proving — FAILS at RED)
# ---------------------------------------------------------------------------
@test "last JSON object wins when multiple are present" {
    run bash -c 'printf '"'"'{"type":"event"}\n{"type":"result","result":"ok"}\n'"'"' | python3 '"\"$HELPER\""
    [ "$status" -eq 0 ]
    [ "$output" = '{"type":"result","result":"ok"}' ]
}
