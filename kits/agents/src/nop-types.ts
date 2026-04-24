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
