/**
 * Structural types for the NCP frames that v0.1.0 builds and parses.
 *
 * These types describe the JSON shape per NPS-1 §4. They are advisory — the codec
 * serializes whatever the caller passes in as the payload object and does not
 * enforce field-level validation. Higher layers (schema validators, the kit's
 * orchestrator package) are responsible for semantic checks.
 */

export interface AnchorFrameField {
  readonly name: string;
  readonly type:
    | "string"
    | "uint64"
    | "int64"
    | "decimal"
    | "bool"
    | "timestamp"
    | "bytes"
    | "object"
    | "array";
  readonly semantic?: string;
  readonly nullable?: boolean;
}

export interface AnchorFramePayload {
  readonly frame: "0x01";
  readonly anchor_id: string;
  readonly schema: { readonly fields: readonly AnchorFrameField[] };
  readonly ttl?: number;
}

export interface DiffFramePayload {
  readonly frame: "0x02";
  readonly anchor_ref: string;
  readonly base_seq: number;
  readonly patch_format?: "json_patch" | "binary_bitset";
  readonly patch: unknown;
  readonly entity_id?: string;
}

export interface StreamFramePayload {
  readonly frame: "0x03";
  readonly stream_id: string;
  readonly seq: number;
  readonly is_last: boolean;
  readonly anchor_ref?: string;
  readonly data: readonly unknown[];
  readonly window_size?: number;
  readonly error_code?: string;
}

export interface CapsFramePayload {
  readonly frame: "0x04";
  readonly anchor_ref: string;
  readonly count: number;
  readonly data: readonly unknown[];
  readonly next_cursor?: string | null;
  readonly token_est?: number;
  readonly tokenizer_used?: string;
  readonly cached?: boolean;
  readonly inline_anchor?: AnchorFramePayload;
}

export interface HelloFramePayload {
  readonly frame: "0x06";
  readonly nps_version: string;
  readonly min_version?: string;
  readonly supported_encodings: readonly string[];
  readonly supported_protocols: readonly string[];
  readonly agent_id?: string;
  readonly max_frame_payload?: number;
  readonly ext_support?: boolean;
  readonly max_concurrent_streams?: number;
  readonly e2e_enc_algorithms?: readonly string[];
}

export interface ErrorFramePayload {
  readonly frame: "0xFE";
  readonly status: string;
  readonly error: string;
  readonly message?: string;
  readonly details?: Readonly<Record<string, unknown>>;
}

export type KnownFramePayload =
  | AnchorFramePayload
  | DiffFramePayload
  | StreamFramePayload
  | CapsFramePayload
  | HelloFramePayload
  | ErrorFramePayload;
