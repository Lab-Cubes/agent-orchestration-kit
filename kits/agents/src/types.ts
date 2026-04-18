// NOP Task Protocol — TypeScript Type Definitions
//
// NCP carries the envelope. NOP fills the payload.
// IntentMessage dispatches. ResultMessage reports back.
//
// Reference: NPS-5 (NOP) spec at https://github.com/labacacia/NPS-Release

// -----------------------------------------------------------------------------
// NCP Envelope Types
// -----------------------------------------------------------------------------

type NcpVersion = 1;

export interface Alternative {
  value: string;
  probability: number;
}

// -----------------------------------------------------------------------------
// NOP Payload Types — Intent (Dispatch)
// -----------------------------------------------------------------------------

type NopVersion = 1;

export type Priority = "urgent" | "normal" | "low";

export type TaskCategory = "code" | "research" | "docs" | "test" | "refactor" | "ops";

export interface Mailbox {
  base: string;
  active?: string;
  done?: string;
}

export interface TaskContext {
  files?: string[];
  knowledge?: string[];
  branch?: string;
}

export interface TaskConstraints {
  model?: string;
  time_limit?: number;
  scope?: string[];
  /** If true, the worker pauses before file changes and waits for operator approval. */
  proceed_gate?: boolean;
  /** Max NPT the worker may consume for this task (NPS-0 §4.3). */
  budget_npt?: number;
}

export interface NopIntentPayload {
  _nop: NopVersion;
  /** Unique task ID: task-{issuer}-{YYYYMMDD}-{HHMMSS} */
  id: string;
  /** Issuer NID (orchestrator who dispatched) */
  from: string;
  /** Target worker NID. Omit = any available worker picks up */
  to?: string;
  created_at: string;
  priority?: Priority;
  category?: TaskCategory;
  mailbox: Mailbox;
  context?: TaskContext;
  constraints?: TaskConstraints;
}

// -----------------------------------------------------------------------------
// NOP Payload Types — Result (Report Back)
// -----------------------------------------------------------------------------

export type TaskStatus = "completed" | "failed" | "timeout" | "blocked";

export interface NopResultPayload {
  _nop: NopVersion;
  id: string;
  status: TaskStatus;
  from: string;
  picked_up_at: string;
  completed_at: string;
  files_changed?: string[];
  commits?: string[];
  follow_up?: string[];
  duration?: number;
  /** NPT consumed executing this task. */
  cost_npt?: number;
  error?: string | null;
}

// -----------------------------------------------------------------------------
// Full NCP+NOP Messages
// -----------------------------------------------------------------------------

export interface IntentMessage {
  _ncp: NcpVersion;
  type: "intent";
  /** Short verb phrase: "fix-bug", "write-test", "research", "refactor" */
  intent: string;
  /** Orchestrator's confidence this is the right task/worker. 0-1 */
  confidence: number;
  payload: NopIntentPayload;
}

export interface ResultMessage {
  _ncp: NcpVersion;
  type: "result";
  /** Human-readable summary of what was done */
  value: string;
  /** Worker's confidence in the result quality. 0-1 */
  probability: number;
  alternatives: Alternative[];
  payload: NopResultPayload;
}

export type NopMessage = IntentMessage | ResultMessage;

// -----------------------------------------------------------------------------
// Task Lifecycle
// -----------------------------------------------------------------------------

export type TaskState =
  | "pending"
  | "active"
  | "completed"
  | "failed"
  | "timeout"
  | "blocked"
  | "cancelled";

export const VALID_TRANSITIONS: Record<string, TaskState[]> = {
  pending: ["active", "cancelled"],
  active: ["completed", "failed", "timeout", "blocked"],
  blocked: ["active", "cancelled"],
  completed: [],
  failed: [],
  timeout: [],
  cancelled: [],
};

export const STATE_DIRECTORY: Record<TaskState, string> = {
  pending: "inbox",
  active: "active",
  completed: "done",
  failed: "done",
  timeout: "done",
  blocked: "blocked",
  cancelled: "done",
};

export const FILE_EXTENSIONS = {
  intent: ".intent.json",
  result: ".result.json",
  caps: ".caps.json",
} as const;

export const MAILBOX_DEFAULTS = {
  active: "active",
  done: "done",
  inbox: "inbox",
  blocked: "blocked",
  registry: "registry",
} as const;
