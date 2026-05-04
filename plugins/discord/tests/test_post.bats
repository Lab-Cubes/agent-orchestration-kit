#!/usr/bin/env bats
# test_post.bats — unit tests for plugins/discord/_post.sh
#
# Uses a temporary plugin directory so each test is fully isolated.
# Mock curl in tests/bin/ captures args without calling the real Discord API.

PLUGIN_SRC="$BATS_TEST_DIRNAME/.."
FIXTURES="$BATS_TEST_DIRNAME/fixtures"

setup() {
    # Isolated plugin dir: _post.sh + optional config.json per test
    PLUGIN_TMPDIR="$(mktemp -d)"
    cp "$PLUGIN_SRC/_post.sh" "$PLUGIN_TMPDIR/_post.sh"
    chmod +x "$PLUGIN_TMPDIR/_post.sh"

    # File where mock curl writes its args
    CURL_ARGS_FILE="$PLUGIN_TMPDIR/curl_args"
    > "$CURL_ARGS_FILE"
    export CURL_ARGS_FILE

    # File where mock curl tracks invocation count (shared across curl calls in one run)
    CURL_COUNT_FILE="$PLUGIN_TMPDIR/curl_count"
    export CURL_COUNT_FILE

    # Prepend mock curl so _post.sh never calls the real Discord API
    export PATH="$BATS_TEST_DIRNAME/bin:$PATH"
}

teardown() {
    rm -rf "$PLUGIN_TMPDIR"
}

# ---------------------------------------------------------------------------
# 1. Silent fallback: no config.json → exit 0, no output, no curl call
# ---------------------------------------------------------------------------
@test "_post.sh exits 0 when config.json is missing (silent fallback)" {
    # Deliberately no config.json in PLUGIN_TMPDIR
    run "$PLUGIN_TMPDIR/_post.sh" task_claimed
    [ "$status" -eq 0 ]
    [ ! -s "$CURL_ARGS_FILE" ]   # curl must NOT have been called
}

# ---------------------------------------------------------------------------
# 2. User-Agent header present when curl is invoked
# ---------------------------------------------------------------------------
@test "_post.sh includes User-Agent header with valid config" {
    cp "$FIXTURES/valid_config.json" "$PLUGIN_TMPDIR/config.json"

    export NPS_AGENT_ID="coder-01"
    export NPS_TASK_ID="task-ua-test"
    export NPS_COST_CGN="0"

    run "$PLUGIN_TMPDIR/_post.sh" task_claimed
    [ "$status" -eq 0 ]
    grep -q "User-Agent" "$CURL_ARGS_FILE"
}

# ---------------------------------------------------------------------------
# 3. Placeholder substitution: {task_id}, {account}, {cost_cgn}
# ---------------------------------------------------------------------------
@test "_post.sh substitutes {task_id}, {account}, {cost_cgn} in the message" {
    cp "$FIXTURES/valid_config.json" "$PLUGIN_TMPDIR/config.json"

    export NPS_AGENT_ID="coder-01"
    export NPS_TASK_ID="task-sub-test-42"
    export NPS_COST_CGN="3.14"

    run "$PLUGIN_TMPDIR/_post.sh" task_completed
    [ "$status" -eq 0 ]

    # The message JSON is passed as the last argument to curl
    curl_output="$(cat "$CURL_ARGS_FILE")"
    echo "$curl_output" | grep -q "task-sub-test-42"
    echo "$curl_output" | grep -q "3.14"
    echo "$curl_output" | grep -q "coder-01"   # display_name from accounts.coder1
}

# ---------------------------------------------------------------------------
# 4. Token from accounts block
# ---------------------------------------------------------------------------
@test "_post.sh uses accounts.<account>.token" {
    cp "$FIXTURES/valid_config.json" "$PLUGIN_TMPDIR/config.json"

    export NPS_AGENT_ID="coder-01"
    export NPS_TASK_ID="task-token-test"
    export NPS_COST_CGN="0"

    run "$PLUGIN_TMPDIR/_post.sh" task_claimed
    [ "$status" -eq 0 ]

    # curl Authorization header must carry the account token
    grep -q "TEST_TOKEN_CODER1_FAKE" "$CURL_ARGS_FILE"
}

# ---------------------------------------------------------------------------
# 5. Empty channel_id → silent exit 0 (no curl call)
# ---------------------------------------------------------------------------
@test "_post.sh exits 0 (no error) when channel_id is empty" {
    python3 - "$FIXTURES/valid_config.json" "$PLUGIN_TMPDIR/config.json" << 'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["channel_id"] = ""
with open(sys.argv[2], "w") as f:
    json.dump(d, f)
PYEOF

    export NPS_AGENT_ID="coder-01"
    export NPS_TASK_ID="task-nochannel"
    export NPS_COST_CGN="0"

    run "$PLUGIN_TMPDIR/_post.sh" task_claimed
    [ "$status" -eq 0 ]
    [ ! -s "$CURL_ARGS_FILE" ]   # curl must NOT have been called
}

# ---------------------------------------------------------------------------
# 7. 429 → 200: retries once on 429 then succeeds on 200
# ---------------------------------------------------------------------------
@test "_post.sh retries once on 429 then succeeds on 200" {
    cp "$FIXTURES/valid_config.json" "$PLUGIN_TMPDIR/config.json"

    export NPS_AGENT_ID="coder-01"
    export NPS_TASK_ID="task-429-retry"
    export NPS_COST_CGN="0"
    export MOCK_CURL_SCRIPT="429,200"

    run "$PLUGIN_TMPDIR/_post.sh" task_claimed
    [ "$status" -eq 0 ]
    [ "$(grep -c "discord.com/api" "$CURL_ARGS_FILE")" -eq 2 ]
}

# ---------------------------------------------------------------------------
# 8. Persistent 429: capped at 3 attempts (attempt 0, 1, 2; max_retries=2)
# ---------------------------------------------------------------------------
@test "_post.sh caps retries on persistent 429 (exits 0, bounded attempts)" {
    cp "$FIXTURES/valid_config.json" "$PLUGIN_TMPDIR/config.json"

    export NPS_AGENT_ID="coder-01"
    export NPS_TASK_ID="task-429-cap"
    export NPS_COST_CGN="0"
    export MOCK_CURL_SCRIPT="429,429,429,429,429"

    run "$PLUGIN_TMPDIR/_post.sh" task_claimed
    [ "$status" -eq 0 ]
    [ "$(grep -c "discord.com/api" "$CURL_ARGS_FILE")" -eq 3 ]
}

# ---------------------------------------------------------------------------
# 9. 500: non-429 error — no retry, silent exit 0
# ---------------------------------------------------------------------------
@test "_post.sh does not retry on 500 (non-429 error, silent drop)" {
    cp "$FIXTURES/valid_config.json" "$PLUGIN_TMPDIR/config.json"

    export NPS_AGENT_ID="coder-01"
    export NPS_TASK_ID="task-500-noretry"
    export NPS_COST_CGN="0"
    export MOCK_CURL_SCRIPT="500"

    run "$PLUGIN_TMPDIR/_post.sh" task_claimed
    [ "$status" -eq 0 ]
    [ "$(grep -c "discord.com/api" "$CURL_ARGS_FILE")" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 10. 200: happy path — single invocation, exit 0
# ---------------------------------------------------------------------------
@test "_post.sh does not retry on 200 (happy path, single invocation)" {
    cp "$FIXTURES/valid_config.json" "$PLUGIN_TMPDIR/config.json"

    export NPS_AGENT_ID="coder-01"
    export NPS_TASK_ID="task-200-happy"
    export NPS_COST_CGN="0"
    export MOCK_CURL_SCRIPT="200"

    run "$PLUGIN_TMPDIR/_post.sh" task_claimed
    [ "$status" -eq 0 ]
    [ "$(grep -c "discord.com/api" "$CURL_ARGS_FILE")" -eq 1 ]
}
