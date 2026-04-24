/**
 * NOP wire-protocol types + NID builder, inlined from the former
 * @nps-kit/codec + @nps-kit/identity packages.
 *
 * This kit no longer depends on those packages — kits/agents is atomic and
 * self-contained at the TypeScript layer.
 *
 * Sources:
 *   - NOP types: packages/codec/src/payloads.ts (NPS-5 §4, frame range 0x40-0x4F)
 *   - buildNid:  packages/identity/src/nid.ts    (NPS-0 §5.2 / NPS-3 §3)
 */

/* ── NipError (required by buildNid) ─────────────────────────────────────── */

export type NipErrorCode =
  | "NIP-KEY-GENERATION-FAILED"
  | "NIP-KEY-IMPORT-FAILED"
  | "NIP-SIGNATURE-FAILED"
  | "NIP-PUBLIC-KEY-FORMAT-INVALID"
  | "NIP-SIGNATURE-FORMAT-INVALID"
  | "NIP-NID-FORMAT-INVALID"
  | "NIP-DEV-MODE-AGENT-ID-INVALID"
  | "NIP-SCOPE-EXPANSION-DENIED";

export class NipError extends Error {
  readonly code: NipErrorCode;
  readonly details: Readonly<Record<string, unknown>>;

  constructor(
    code: NipErrorCode,
    message: string,
    details: Record<string, unknown> = {},
  ) {
    super(message);
    this.name = "NipError";
    this.code = code;
    this.details = Object.freeze({ ...details });
  }
}

/* ── NID builder (NPS-0 §5.2 / NPS-3 §3) ────────────────────────────────── */

/**
 * NID format per NPS-0 §5.2 / NPS-3 §3:
 *
 *   urn:nps:<entity-type>:<issuer-domain>:<identifier>
 *
 *   entity-type  = "agent" | "node" | "org"
 *   issuer-domain = RFC 1034 domain
 *   identifier   = 1*(ALPHA / DIGIT / "-" / "_" / ".")
 */
export type NidEntityType = "agent" | "node" | "org";

const NID_PATTERN = /^urn:nps:(agent|node|org):([A-Za-z0-9.-]+):([A-Za-z0-9._-]+)$/;
const ORG_PATTERN = /^urn:nps:org:([A-Za-z0-9.-]+)$/;

export function buildNid(
  entityType: NidEntityType,
  issuerDomain: string,
  identifier?: string,
): string {
  if (entityType === "org") {
    if (identifier !== undefined) {
      throw new NipError(
        "NIP-NID-FORMAT-INVALID",
        "Org NIDs do not take an identifier — the domain itself is the org identity",
        { issuerDomain, identifier },
      );
    }
    const nid = `urn:nps:org:${issuerDomain}`;
    if (!ORG_PATTERN.test(nid)) {
      throw new NipError(
        "NIP-NID-FORMAT-INVALID",
        `Constructed org NID '${nid}' fails format validation`,
        { nid },
      );
    }
    return nid;
  }
  if (identifier === undefined || identifier.length === 0) {
    throw new NipError(
      "NIP-NID-FORMAT-INVALID",
      `${entityType} NIDs require a non-empty identifier`,
      { entityType, issuerDomain },
    );
  }
  const nid = `urn:nps:${entityType}:${issuerDomain}:${identifier}`;
  if (!NID_PATTERN.test(nid)) {
    throw new NipError(
      "NIP-NID-FORMAT-INVALID",
      `Constructed NID '${nid}' fails format validation`,
      { nid },
    );
  }
  return nid;
}

/* ── NOP (NPS-5) wire-protocol types — frame range 0x40-0x4F ────────────── */

export interface Alternative {
  value: string;
  probability: number;
}

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
  /** Max NPT the worker may consume for this task (NPS-0 §4.3). */
  budget_npt?: number;
}

type NopVersion = 1;
type NcpVersion = 1;

export interface NopIntentPayload {
  _nop: NopVersion;
  /** Unique task ID: task-{issuer}-{YYYYMMDD}-{HHMMSS} */
  id: string;
  /**
   * Back-pointer to the originating plan. @see architecture.md §4.5
   * Optional in v1; required once Dispatcher 4a is the only caller (#63).
   */
  plan_id?: string;
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

export type TaskStatus = "completed" | "failed" | "timeout" | "blocked";

export interface NopResultPayload {
  _nop: NopVersion;
  id: string;
  /**
   * Back-pointer to the originating plan. @see architecture.md §4.5
   * Optional in v1; required once Dispatcher 4a is the only caller (#63).
   */
  plan_id?: string;
  status: TaskStatus;
  /**
   * Worker signals why it blocked; Dispatcher uses this to decide whether to
   * re-invoke the Decomposer. @see architecture.md §4.5
   *
   * Note: EscalationEvent.pushback_reason (below) has a different shape
   * (freeform string | null) — Dispatcher may annotate or pass through worker's
   * narrow enum value as a human-readable string in the escalation log.
   */
  pushback_reason?: "scope_insufficient" | "intent_unclear" | "capability_missing" | null;
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

/* ── Phased-dispatch types (#45) ─────────────────────────────────────────── */

/**
 * Versioned task-list emitted by the Decomposer; aligned with NOP TaskFrame
 * (NPS-5 §3.1). Kit-specific additions documented in architecture.md §4.2.
 * Written to `task-lists/{plan-id}/pending/v{N}.json`; promoted to
 * `v{N}.json` on OSer ack via `cmd_ack`.
 */
export interface TaskListMessage {
  _ncp: 1;
  type: "task_list";
  schema_version: 1;
  plan_id: string;
  version_id: number;
  created_at: string;
  created_by: string;
  prior_version: number | null;
  /**
   * Freeform annotation from the Dispatcher when re-invoking the Decomposer
   * after a worker pushback. @see architecture.md §4.2
   *
   * Note: NopResultPayload.pushback_reason (above) carries a narrow enum
   * — the worker's machine-readable signal. Dispatcher may pass it through
   * here as a human-readable string for Decomposer context.
   */
  pushback_reason: string | null;
  dag: {
    nodes: TaskNode[];
    edges: TaskEdge[];
  };
}

/**
 * A single node in the task DAG. @see architecture.md §4.2
 * Runtime constraints (max 32 nodes, acyclicity, depth limit) are enforced
 * by `cmd_decompose` (issue 6), not by these TypeScript types.
 */
export interface TaskNode {
  id: string;
  /** Verb phrase describing the task. Deviation from NOP's nwp:// URL form — documented in architecture.md §4.2 field-alignment table. */
  action: string;
  /** Target worker NID (NPS-3 §3). */
  agent: string;
  /** Node IDs whose outputs feed this node's inputs. @see architecture.md §4.2 */
  input_from: string[];
  /**
   * Maps this node's input keys to result-field references from upstream nodes.
   * Format: `{ "my_key": "node-1.files_touched[0]" }` — limited to
   * result-field references in kit v1. @see architecture.md §4.2
   */
  input_mapping: Record<string, string>;
  scope: string[];
  budget_npt: number;
  timeout_ms: number;
  /** Retry behaviour; `backoff_ms` is a flat delay between attempts in v1. */
  retry_policy: { max_retries: number; backoff_ms: number };
  /** CEL subset expression, or null (unconditional). @see architecture.md §4.2 */
  condition: string | null;
  /** Machine-checkable DoD; kit extension not present in NOP spec. @see architecture.md §4.2 */
  success_criteria: Record<string, unknown>;
}

/** Directed edge in the task DAG. `from` must complete before `to` is dispatched. */
export interface TaskEdge {
  from: string;
  to: string;
}

/**
 * Graph-level execution state for one active plan version.
 * @see architecture.md §4.3
 * Written to `task-lists/{plan-id}/task-list-state.json`.
 */
export interface TaskListState {
  schema_version: 1;
  plan_id: string;
  active_version: number;
  superseded_versions: number[];
  node_states: Record<string, NodeState>;
  merge_hold: boolean;
  updated_at: string;
}

/**
 * Per-node execution state within a TaskListState.
 * `status` is distinct from `TaskStatus` (wire result enum) and `TaskState`
 * (filesystem lifecycle enum) — do not merge them.
 * @see architecture.md §4.3
 */
export interface NodeState {
  /** `superseded` is set when a higher version supersedes in-flight work. */
  status: "pending" | "running" | "completed" | "failed" | "superseded" | "blocked";
  task_id: string | null;
  started_at: string | null;
  completed_at: string | null;
  result_path: string | null;
  retries: number;
}

/**
 * Append-only escalation log entry (JSONL). One event per line.
 * `schema_version: 1` discriminator enables v1/v2 coexistence.
 * @see architecture.md §4.4
 */
export interface EscalationEvent {
  schema_version: 1;
  timestamp: string;
  plan_id: string;
  prior_version: number | null;
  /** Worker task_id that emitted a pushback result, or null. */
  pushback_source: string | null;
  /**
   * Freeform annotation passed to the Decomposer on re-invocation.
   *
   * Note: NopResultPayload.pushback_reason (above) is a narrow enum — the
   * worker's machine-readable signal. Dispatcher may annotate or pass it
   * through here as a human-readable string in the escalation log.
   */
  pushback_reason: string | null;
  /**
   * What the Dispatcher did in response to the triggering event.
   * `decomposer_failed`: emitted when `cmd_decompose` exits non-zero, times
   *   out, or produces output that fails NOP DAG validation. @see architecture.md §5.3
   * `invoked_decomposer`: Dispatcher triggered a Decomposer re-invocation. @see architecture.md §6.1
   * `supersede_applied`: running worker was SIGINT'd and branch renamed. @see architecture.md §6.4
   * `supersede_archived`: terminal node's branch renamed to superseded/... @see architecture.md §6.4
   * `supersede_complex_state`: abnormal HEAD detected; node blocked for OSer triage. @see architecture.md §6.4
   * `pushback_superseded`: pushback-blocked node naturally superseded by v_{N+1}. @see architecture.md §6.4
   * `supersede_resolved`: OSer completed manual triage of a complex-HEAD node. @see architecture.md §6.4
   * `supersede_gc`: superseded worktree cleanup via `cmd_supersede_gc`.
   * `osi_acked`: OSer acknowledged a decomposer output version.
   * `escalated_to_oser`: Dispatcher escalated to OSer for manual decision.
   * `retried`: Dispatcher retried a failed node within retry_policy limits.
   * `manual_merge_override`: OSer used the merge_hold_enforce escape hatch. @see architecture.md §6.3
   */
  dispatcher_acted:
    | "invoked_decomposer"
    | "escalated_to_oser"
    | "decomposer_failed"
    | "retried"
    | "supersede_applied"
    | "supersede_archived"
    | "supersede_complex_state"
    | "pushback_superseded"
    | "supersede_resolved"
    | "osi_acked"
    | "manual_merge_override"
    | "supersede_gc"
    | null;
  decomposer_output_version: number | null;
  osi_ack_at: string | null;
  osi_ack_verdict: "approve" | "reject" | "amend" | null;
  duration_s: number | null;
  /** `"plan"` reserved for v2; plan-level rejection creates a new plan_id. @see architecture.md §4.4 */
  escalation_level: "task" | "version";
}
