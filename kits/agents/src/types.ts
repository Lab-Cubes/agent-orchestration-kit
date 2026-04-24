// NOP Task Protocol — TypeScript Type Definitions
//
// Wire-protocol types (NCP envelope + NOP payload shapes) are inlined in ./nop-types.ts.
// This file re-exports them for kit consumers and adds filesystem-layer types
// that are specific to the agents kit (task lifecycle, mailbox directory layout).
//
// Reference: NPS-5 (NOP) spec at https://github.com/labacacia/NPS-Release

// -----------------------------------------------------------------------------
// Wire-protocol types — re-exported from ./nop-types
// -----------------------------------------------------------------------------

export type {
  Alternative,
  ContextCapacity,
  IntentMessage,
  Mailbox,
  NopIntentPayload,
  NopMessage,
  NopResultPayload,
  Priority,
  ResultMessage,
  TaskCategory,
  TaskConstraints,
  TaskContext,
  TaskStatus,
} from "./nop-types.js";

// -----------------------------------------------------------------------------
// Phased-dispatch types (#45) — re-exported from ./nop-types
// -----------------------------------------------------------------------------

export type {
  TaskListMessage,
  TaskNode,
  TaskEdge,
  TaskListState,
  NodeState,
  EscalationEvent,
} from "./nop-types.js";

// -----------------------------------------------------------------------------
// Task Lifecycle — filesystem layer (kit-specific, not wire protocol)
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
} as const;

export const MAILBOX_DEFAULTS = {
  active: "active",
  done: "done",
  inbox: "inbox",
  blocked: "blocked",
} as const;
