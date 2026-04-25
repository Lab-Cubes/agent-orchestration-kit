#!/usr/bin/env bats
# test_adapter.bats — unit tests for experiments/openclaw-adapter/adapter.sh
#
# Uses tests/bin/openclaw (stub) so no real OpenClaw gateway is needed.

ADAPTER="$BATS_TEST_DIRNAME/../adapter.sh"

setup() {
  TMPDIR="$(mktemp -d)"
  EVENT_LOG="$TMPDIR/events.ndjson"
  export MOCK_OPENCLAW_ARGS_FILE="$TMPDIR/openclaw_args"
  > "$MOCK_OPENCLAW_ARGS_FILE"

  # Prepend stub directory so adapter.sh calls our mock, not the real openclaw
  export PATH="$BATS_TEST_DIRNAME/bin:$PATH"
}

teardown() {
  rm -rf "$TMPDIR"
}

# Minimal TaskPacket factory
make_packet() {
  python3 -c "
import json, sys
print(json.dumps({
  'id': 'task-test-001',
  'subtask_id': 'sub-0000-1111',
  'parent_task_id': 'parent-aaaa-bbbb',
  'params': {
    'prompt': 'say hello',
    'context': {'agent_id': 'main'}
  }
}))
"
}

# ---------------------------------------------------------------------------
# 1. Happy path — lifecycle.done emitted with required envelope fields
# ---------------------------------------------------------------------------
@test "happy path: lifecycle.done emitted with required envelope fields" {
  export MOCK_OPENCLAW_MODE="happy"

  make_packet > "$TMPDIR/packet.json"
  run bash -c "cat '$TMPDIR/packet.json' | '$ADAPTER' --event-log '$EVENT_LOG'"
  [ "$status" -eq 0 ]
  [ -s "$EVENT_LOG" ]

  # Extract the terminal lifecycle.done event
  DONE_EVENT=$(python3 -c "
import sys, json
events = [json.loads(l) for l in open('$EVENT_LOG')]
done = [e for e in events if e.get('event') == 'lifecycle.done']
if not done:
    print('NO_DONE_EVENT')
    sys.exit(1)
print(json.dumps(done[0]))
")

  # Required envelope fields
  echo "$DONE_EVENT" | python3 -c "
import sys, json, re
e = json.load(sys.stdin)
assert e['event'] == 'lifecycle.done', f'event mismatch: {e[\"event\"]}'
assert re.match(r'^[0-9a-f-]{36}$', e['stream_id']), f'stream_id not a UUID: {e[\"stream_id\"]}'
assert e['task_id'] == 'parent-aaaa-bbbb', f'task_id mismatch: {e[\"task_id\"]}'
assert e['subtask_id'] == 'sub-0000-1111', f'subtask_id mismatch: {e[\"subtask_id\"]}'
assert e['sender_nid'] == 'urn:nps:agent:example.com:openclaw-adapter', f'sender_nid mismatch'
assert 'timestamp' in e and e['timestamp'].endswith('Z'), f'timestamp missing or bad format'
assert isinstance(e['seq'], int), f'seq not int'
print('envelope OK')
"

  # data.cost fields (per contract §CSV mapping)
  echo "$DONE_EVENT" | python3 -c "
import sys, json
e = json.load(sys.stdin)
cost = e['data']['cost']
assert cost['model'] == 'claude-sonnet-4-6', f'model mismatch: {cost[\"model\"]}'
assert cost['wall_clock_ms'] == 1234, f'wall_clock_ms: {cost[\"wall_clock_ms\"]}'
# input_tokens = usage.input(10) + usage.cacheRead(2) = 12
assert cost['input_tokens'] == 12, f'input_tokens: {cost[\"input_tokens\"]}'
assert cost['output_tokens'] == 5, f'output_tokens: {cost[\"output_tokens\"]}'
print('cost fields OK')
"

  # stream_id is consistent across all events
  python3 -c "
import json
events = [json.loads(l) for l in open('$EVENT_LOG')]
ids = set(e['stream_id'] for e in events)
assert len(ids) == 1, f'stream_id not consistent across events: {ids}'
print('stream_id consistent OK')
"

  # seq is monotonically increasing from 0
  python3 -c "
import json
events = [json.loads(l) for l in open('$EVENT_LOG')]
seqs = [e['seq'] for e in events]
assert seqs == list(range(len(seqs))), f'seq not monotonic: {seqs}'
print('seq monotonic OK')
"
}

# ---------------------------------------------------------------------------
# 2. Timeout path — lifecycle.timed_out emitted with stderr in error.details
# ---------------------------------------------------------------------------
@test "timeout path: lifecycle.timed_out emitted with stderr in error.details" {
  export MOCK_OPENCLAW_MODE="timeout"

  make_packet > "$TMPDIR/packet.json"
  run bash -c "cat '$TMPDIR/packet.json' | '$ADAPTER' --event-log '$EVENT_LOG'"
  # adapter.sh itself should exit 0 — the timeout is a terminal event, not a crash
  [ "$status" -eq 0 ]
  [ -s "$EVENT_LOG" ]

  # Extract the terminal lifecycle.timed_out event
  TIMED_OUT_EVENT=$(python3 -c "
import sys, json
events = [json.loads(l) for l in open('$EVENT_LOG')]
to = [e for e in events if e.get('event') == 'lifecycle.timed_out']
if not to:
    print('NO_TIMED_OUT_EVENT')
    sys.exit(1)
print(json.dumps(to[0]))
")

  # Required envelope fields
  echo "$TIMED_OUT_EVENT" | python3 -c "
import sys, json, re
e = json.load(sys.stdin)
assert e['event'] == 'lifecycle.timed_out', f'event mismatch: {e[\"event\"]}'
assert re.match(r'^[0-9a-f-]{36}$', e['stream_id']), 'stream_id not a UUID'
assert e['task_id'] == 'parent-aaaa-bbbb', f'task_id mismatch'
assert e['subtask_id'] == 'sub-0000-1111', f'subtask_id mismatch'
assert e['sender_nid'] == 'urn:nps:agent:example.com:openclaw-adapter', 'sender_nid mismatch'
assert 'timestamp' in e and e['timestamp'].endswith('Z'), 'timestamp bad'
print('envelope OK')
"

  # error.details.stderr must contain the timeout message from the mock
  echo "$TIMED_OUT_EVENT" | python3 -c "
import sys, json
e = json.load(sys.stdin)
err = e['data']['error']
assert err['code'] == 'NOP-DELEGATE-TIMEOUT', f'code mismatch: {err[\"code\"]}'
assert 'stderr' in err['details'], 'stderr missing from error.details'
assert 'timed out' in err['details']['stderr'].lower(), f'stderr does not contain timed out: {err[\"details\"][\"stderr\"]}'
print('error.details.stderr OK')
"
}

# ---------------------------------------------------------------------------
# 3. Failure path — lifecycle.failed emitted for non-timeout non-zero exit
# ---------------------------------------------------------------------------
@test "failure path: lifecycle.failed emitted for non-timeout error" {
  export MOCK_OPENCLAW_MODE="failure"

  make_packet > "$TMPDIR/packet.json"
  run bash -c "cat '$TMPDIR/packet.json' | '$ADAPTER' --event-log '$EVENT_LOG'"
  [ "$status" -eq 0 ]
  [ -s "$EVENT_LOG" ]

  FAILED_EVENT=$(python3 -c "
import sys, json
events = [json.loads(l) for l in open('$EVENT_LOG')]
fail = [e for e in events if e.get('event') == 'lifecycle.failed']
if not fail:
    print('NO_FAILED_EVENT')
    sys.exit(1)
print(json.dumps(fail[0]))
")

  echo "$FAILED_EVENT" | python3 -c "
import sys, json
e = json.load(sys.stdin)
assert e['event'] == 'lifecycle.failed', f'event mismatch'
assert e['data']['error']['code'] == 'ADAPTER-RUNTIME-ERROR', 'code mismatch'
print('failure path OK')
"
}
