// dispatch.ts — Orchestrator drops a task into a worker's inbox.
// Usage: npx tsx src/dispatch.ts <worker-id> "<intent>"

import { writeFileSync, mkdirSync } from "node:fs";
import { join, resolve } from "node:path";
import type { IntentMessage } from "@nps-kit/codec";
import { buildNid } from "@nps-kit/identity";
import { MAILBOX_DEFAULTS, FILE_EXTENSIONS } from "./types.js";

const workerId = process.argv[2];
const intentText = process.argv[3];

if (!workerId || !intentText) {
  console.error("Usage: npx tsx src/dispatch.ts <worker-id> \"<intent>\"");
  process.exit(2);
}

const AGENTS_HOME = resolve(process.env.NPS_AGENTS_HOME ?? "./agents");
const ISSUER_DOMAIN = process.env.NPS_ISSUER_DOMAIN ?? "dev.localhost";
const ISSUER_AGENT_ID = process.env.NPS_ISSUER_AGENT_ID ?? "operator";

const now = new Date();
const pad = (n: number) => String(n).padStart(2, "0");
const taskId = `task-${ISSUER_AGENT_ID}-${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;

const message: IntentMessage = {
  _ncp: 1,
  type: "intent",
  intent: intentText,
  confidence: 1.0,
  payload: {
    _nop: 1,
    id: taskId,
    from: buildNid("agent", ISSUER_DOMAIN, ISSUER_AGENT_ID),
    to: buildNid("agent", ISSUER_DOMAIN, workerId),
    created_at: now.toISOString(),
    priority: "normal",
    mailbox: { base: "./" },
    constraints: { time_limit: 900 },
  },
};

const inboxDir = join(AGENTS_HOME, workerId, MAILBOX_DEFAULTS.inbox);
mkdirSync(inboxDir, { recursive: true });

const filename = `${taskId}${FILE_EXTENSIONS.intent}`;
const filepath = join(inboxDir, filename);
writeFileSync(filepath, JSON.stringify(message, null, 2) + "\n");

console.log(`[dispatch] Task created: ${taskId}`);
console.log(`[dispatch] Written to: ${filepath}`);
