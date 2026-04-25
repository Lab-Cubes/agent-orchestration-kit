#!/usr/bin/env bash
# Copyright 2026 Lab-Cubes
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# adapter.sh — NOP OpenClaw Adapter v1
#
# Usage:
#   echo '<TaskPacket JSON>' | ./adapter.sh --event-log /path/to/events.ndjson
#
# Reads a TaskPacket JSON document from stdin.
# Emits NDJSON lifecycle events to the file given by --event-log.
# Invokes: openclaw agent --agent <id> --message <prompt> --json
#
# Spec: NOP Adapter Contract v0.2

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
EVENT_LOG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --event-log)
      EVENT_LOG="$2"
      shift 2
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$EVENT_LOG" ]]; then
  echo "ERROR: --event-log <path> is required" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Read TaskPacket from stdin before delegating to python3
# ---------------------------------------------------------------------------
TASK_PACKET=$(cat)
export TASK_PACKET

# ---------------------------------------------------------------------------
# Delegate execution logic to python3 (avoids JSON escaping in bash)
# ---------------------------------------------------------------------------
python3 - "$EVENT_LOG" <<'PYEOF'
import sys
import json
import os
import uuid
import subprocess
from datetime import datetime, timezone

SENDER_NID = "urn:nps:agent:example.com:openclaw-adapter"

event_log = sys.argv[1]
task_packet_str = os.environ["TASK_PACKET"]

# Parse TaskPacket
try:
    packet = json.loads(task_packet_str)
except json.JSONDecodeError as e:
    # Cannot emit proper events without a valid packet — write minimal failure
    err_envelope = {
        "event": "lifecycle.failed",
        "stream_id": str(uuid.uuid4()),
        "task_id": "",
        "subtask_id": "",
        "sender_nid": SENDER_NID,
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") +
                     f"{datetime.now(timezone.utc).microsecond // 1000:03d}Z",
        "seq": 0,
        "data": {
            "error": {
                "code": "NOP-TASK-PARSE-FAILED",
                "message": f"Failed to parse TaskPacket: {e}",
                "retryable": False,
                "details": {}
            },
            "partial_artifacts": [],
            "cost": {}
        }
    }
    with open(event_log, "a") as f:
        f.write(json.dumps(err_envelope) + "\n")
    sys.exit(1)

# -------------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------------
stream_id = str(uuid.uuid4())
_seq = [0]

def _ts():
    now = datetime.now(timezone.utc)
    ms = now.microsecond // 1000
    return now.strftime(f"%Y-%m-%dT%H:%M:%S.{ms:03d}Z")

def _task_id():
    return packet.get("parent_task_id", packet.get("id", ""))

def _subtask_id():
    return packet.get("subtask_id", packet.get("id", ""))

def emit(event_type, data=None):
    envelope = {
        "event": event_type,
        "stream_id": stream_id,
        "task_id": _task_id(),
        "subtask_id": _subtask_id(),
        "sender_nid": SENDER_NID,
        "timestamp": _ts(),
        "seq": _seq[0],
    }
    if data is not None:
        envelope["data"] = data
    _seq[0] += 1
    with open(event_log, "a") as f:
        f.write(json.dumps(envelope) + "\n")

def _npt(input_tokens, output_tokens):
    """Simplified NPT computation per NPS-0 §4.3 — sum of input + output tokens."""
    return input_tokens + output_tokens

# -------------------------------------------------------------------------
# Extract task fields
# -------------------------------------------------------------------------
params = packet.get("params", {})
prompt = params.get("prompt", "")
context = params.get("context", {})
agent_id = context.get("agent_id", "main")

# -------------------------------------------------------------------------
# Lifecycle: spawning → running → dispatch → terminal
# -------------------------------------------------------------------------
emit("lifecycle.spawning")
emit("lifecycle.running")

cmd = ["openclaw", "agent", "--agent", agent_id, "--message", prompt, "--json"]
result = subprocess.run(cmd, capture_output=True, text=True)

if result.returncode == 0:
    # -----------------------------------------------------------------------
    # Success path: parse JSON and emit lifecycle.done
    # -----------------------------------------------------------------------
    try:
        response = json.loads(result.stdout)
    except json.JSONDecodeError as e:
        emit("lifecycle.failed", {
            "error": {
                "code": "ADAPTER-RUNTIME-ERROR",
                "message": f"openclaw returned exit 0 but stdout is not valid JSON: {e}",
                "retryable": False,
                "details": {"stdout": result.stdout[:2048], "stderr": result.stderr[:2048]}
            },
            "partial_artifacts": [],
            "cost": {}
        })
        sys.exit(1)

    meta = response.get("result", {}).get("meta", {})
    agent_meta = meta.get("agentMeta", {})
    usage = agent_meta.get("usage", {})
    last_call_usage = agent_meta.get("lastCallUsage", {})

    model = agent_meta.get("model", "")
    wall_clock_ms = meta.get("durationMs", 0)

    # input_tokens = usage.input + usage.cacheRead (per contract §CSV mapping)
    cache_read = usage.get("cacheRead", last_call_usage.get("cacheRead", 0))
    input_tokens = usage.get("input", 0) + cache_read
    output_tokens = usage.get("output", 0)
    npt_used = _npt(input_tokens, output_tokens)

    session_id = agent_meta.get("sessionId", "")
    payloads = response.get("result", {}).get("payloads", [])
    text = payloads[0].get("text", "") if payloads else ""

    emit("lifecycle.done", {
        "result": {
            "text": text,
            "session_id": session_id,
        },
        "artifacts": [
            {"kind": "openclaw-session", "session_id": session_id}
        ],
        "cost": {
            "model": model,
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "npt_used": npt_used,
            "wall_clock_ms": wall_clock_ms,
        }
    })

else:
    # -----------------------------------------------------------------------
    # Failure path: classify from stderr + exit code
    # -----------------------------------------------------------------------
    stderr = result.stderr

    # Timeout patterns per empirical probe (researcher-02): "timed out" in stderr
    if "timed out" in stderr.lower():
        emit("lifecycle.timed_out", {
            "error": {
                "code": "NOP-DELEGATE-TIMEOUT",
                "message": "openclaw agent timed out",
                "retryable": True,
                "details": {"stderr": stderr}
            },
            "partial_artifacts": [],
            "cost": {}
        })
    else:
        emit("lifecycle.failed", {
            "error": {
                "code": "ADAPTER-RUNTIME-ERROR",
                "message": "openclaw agent exited with non-zero status",
                "retryable": False,
                "details": {"stderr": stderr, "exit_code": result.returncode}
            },
            "partial_artifacts": [],
            "cost": {}
        })
PYEOF
