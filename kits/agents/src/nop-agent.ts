// nop-agent.ts — Minimal NOP worker: scans inbox, claims a task, writes result.
//
// This is the simplest possible NOP worker implementation — useful for testing the
// mailbox protocol without a real agent runtime. Production workers are Claude Code
// (or any agent runtime) wrapped by scripts/spawn-agent.sh.
//
// Usage: NPS_AGENT_ID=echo-01 NPS_AGENTS_HOME=./agents npx tsx src/nop-agent.ts

import { readFileSync, writeFileSync, readdirSync, renameSync, mkdirSync } from "node:fs";
import { join, resolve } from "node:path";
import type { IntentMessage, ResultMessage } from "./nop-types.js";
import { buildNid } from "./nop-types.js";
import { MAILBOX_DEFAULTS, FILE_EXTENSIONS } from "./types.js";

const AGENT_ID = process.env.NPS_AGENT_ID ?? "echo-agent";
const AGENTS_HOME = resolve(process.env.NPS_AGENTS_HOME ?? "./agents");
const ISSUER_DOMAIN = process.env.NPS_ISSUER_DOMAIN ?? "dev.localhost";

const inboxDir = join(AGENTS_HOME, AGENT_ID, MAILBOX_DEFAULTS.inbox);
const activeDir = join(AGENTS_HOME, AGENT_ID, MAILBOX_DEFAULTS.active);
const doneDir = join(AGENTS_HOME, AGENT_ID, MAILBOX_DEFAULTS.done);

mkdirSync(inboxDir, { recursive: true });
mkdirSync(activeDir, { recursive: true });
mkdirSync(doneDir, { recursive: true });

const files = readdirSync(inboxDir).filter((f) => f.endsWith(FILE_EXTENSIONS.intent));
if (files.length === 0) {
  console.log("[nop-agent] No tasks in inbox. Exiting.");
  process.exit(0);
}

const intentFile = files.sort()[0]!;
const intentPath = join(inboxDir, intentFile);
const intent: IntentMessage = JSON.parse(readFileSync(intentPath, "utf-8"));
const taskId = intent.payload.id;

console.log(`[nop-agent] Task: ${taskId} — "${intent.intent}" from ${intent.payload.from}`);

const activePath = join(activeDir, intentFile);
try {
  renameSync(intentPath, activePath);
} catch (err: unknown) {
  if ((err as NodeJS.ErrnoException).code === "ENOENT") {
    console.log("[nop-agent] Task already claimed by another worker. Exiting.");
    process.exit(0);
  }
  throw err;
}

const pickedUpAt = new Date().toISOString();
const knowledge = intent.payload.context?.knowledge ?? [];
const resultValue = `Echo from ${AGENT_ID}: received "${intent.intent}". Context: ${knowledge.join("; ")}`;

const donePath = join(doneDir, intentFile);
renameSync(activePath, donePath);

const completedAt = new Date().toISOString();
const duration = Math.round(
  (new Date(completedAt).getTime() - new Date(pickedUpAt).getTime()) / 1000,
);

const result: ResultMessage = {
  _ncp: 1,
  type: "result",
  value: resultValue,
  probability: 1.0,
  alternatives: [],
  payload: {
    _nop: 1,
    id: taskId,
    status: "completed",
    from: buildNid("agent", ISSUER_DOMAIN, AGENT_ID),
    picked_up_at: pickedUpAt,
    completed_at: completedAt,
    files_changed: [],
    commits: [],
    follow_up: [],
    duration,
    error: null,
  },
};

const resultPath = join(doneDir, `${taskId}${FILE_EXTENSIONS.result}`);
writeFileSync(resultPath, JSON.stringify(result, null, 2) + "\n");

console.log(`[nop-agent] Result written: ${resultPath}`);
