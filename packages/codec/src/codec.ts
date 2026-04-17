import { CodecError } from "./errors.js";
import {
  DEFAULT_TIER1_FLAGS,
  type Flags,
} from "./flags.js";
import {
  FIXED_HEADER_BYTES,
  type FrameHeader,
  MAX_FIXED_PAYLOAD,
  decodeFixedHeader,
  encodeFixedHeader,
} from "./header.js";
import { FrameType, isNcpRangeOrError } from "./frame-types.js";

const TEXT_ENCODER = new TextEncoder();
const TEXT_DECODER = new TextDecoder("utf-8", { fatal: true });

export interface BuildFrameOptions {
  /** Override flag bits. Defaults to Tier-1 JSON, FINAL=1, ENC=0, EXT=0. */
  readonly flags?: Partial<Flags>;
}

export interface ParsedFrame<T = unknown> {
  readonly type: number;
  readonly flags: Flags;
  readonly payload: T;
  /** Raw payload bytes as transmitted on the wire (pre-JSON-parse). */
  readonly payloadBytes: Uint8Array;
}

/**
 * Build a Tier-1 JSON NCP frame.
 *
 * The caller passes the frame type code and the payload object. The payload is
 * serialized as UTF-8 JSON and framed with the 4-byte fixed header (NPS-1 §3.1).
 *
 * Throws CodecError(NCP-FRAME-PAYLOAD-TOO-LARGE) if the serialized payload
 * exceeds the 64 KiB fixed-header limit — callers producing larger payloads
 * should split with StreamFrame per NPS-1 §3.3.
 *
 * Disallows AlignFrame (0x05, deprecated per NPS-1 §4.5); the codec accepts
 * AlignFrames on parseFrame for receive-side compatibility but will not build
 * them.
 */
export function buildFrame(
  type: number,
  payload: unknown,
  options: BuildFrameOptions = {},
): Uint8Array {
  if (type === FrameType.AlignFrame) {
    throw new CodecError(
      "NCP-FRAME-UNKNOWN-TYPE",
      "AlignFrame (0x05) is deprecated per NPS-1 §4.5; use NOP AlignStream (0x43)",
      { type },
    );
  }
  if (!isNcpRangeOrError(type)) {
    throw new CodecError(
      "NCP-FRAME-UNKNOWN-TYPE",
      `Frame type 0x${type.toString(16).padStart(2, "0")} is outside the NCP range (0x01-0x0F) and is not the shared ErrorFrame (0xFE)`,
      { type },
    );
  }

  const flags = resolveFlags(options.flags);
  if (flags.encodingTier !== "tier1-json") {
    throw new CodecError(
      "NCP-ENCODING-UNSUPPORTED",
      `v0.1.0 codec builds Tier-1 JSON only; requested tier '${flags.encodingTier}'`,
      { encodingTier: flags.encodingTier },
    );
  }
  if (flags.encrypted) {
    throw new CodecError(
      "NCP-FRAME-FLAGS-INVALID",
      "Application-layer encryption (ENC=1) is not supported by v0.1.0 codec",
      { flags },
    );
  }
  if (flags.extended) {
    throw new CodecError(
      "NCP-FRAME-FLAGS-INVALID",
      "Extended header (EXT=1) is not supported by v0.1.0 codec",
      { flags },
    );
  }

  const json = JSON.stringify(payload);
  if (json === undefined) {
    throw new CodecError(
      "NCP-PAYLOAD-NOT-JSON",
      "Payload is not JSON-serializable (undefined / function / symbol at root)",
    );
  }
  const payloadBytes = TEXT_ENCODER.encode(json);
  if (payloadBytes.length > MAX_FIXED_PAYLOAD) {
    throw new CodecError(
      "NCP-FRAME-PAYLOAD-TOO-LARGE",
      `Serialized payload ${payloadBytes.length}B exceeds fixed-header max of ${MAX_FIXED_PAYLOAD}B; split with StreamFrame (NPS-1 §3.3)`,
      { payloadLength: payloadBytes.length, max: MAX_FIXED_PAYLOAD },
    );
  }

  const header: FrameHeader = {
    type,
    flags,
    payloadLength: payloadBytes.length,
  };
  const headerBytes = encodeFixedHeader(header);
  const out = new Uint8Array(headerBytes.length + payloadBytes.length);
  out.set(headerBytes, 0);
  out.set(payloadBytes, headerBytes.length);
  return out;
}

/**
 * Parse a single Tier-1 JSON NCP frame.
 *
 * Accepts either the exact framed bytes (4-byte header + payload) or a buffer
 * whose prefix is the frame. Input bytes after `headerBytes + payloadLength` are
 * ignored — wire-stream consumers should slice before calling.
 *
 * AlignFrame (0x05, deprecated) parses successfully to allow receive-side
 * compatibility with legacy traffic, but callers should treat it as legacy.
 */
export function parseFrame<T = unknown>(input: Uint8Array): ParsedFrame<T> {
  const header = decodeFixedHeader(input);

  if (!isNcpRangeOrError(header.type)) {
    throw new CodecError(
      "NCP-FRAME-UNKNOWN-TYPE",
      `Frame type 0x${header.type.toString(16).padStart(2, "0")} is outside the NCP range (0x01-0x0F) and is not the shared ErrorFrame (0xFE)`,
      { type: header.type },
    );
  }

  const totalLength = FIXED_HEADER_BYTES + header.payloadLength;
  if (input.length < totalLength) {
    throw new CodecError(
      "NCP-FRAME-TRUNCATED",
      `Frame claims ${header.payloadLength} payload bytes, only ${input.length - FIXED_HEADER_BYTES} available`,
      {
        payloadLength: header.payloadLength,
        available: input.length - FIXED_HEADER_BYTES,
      },
    );
  }

  const payloadBytes = input.subarray(FIXED_HEADER_BYTES, totalLength);

  if (header.flags.encodingTier !== "tier1-json") {
    throw new CodecError(
      "NCP-ENCODING-UNSUPPORTED",
      `v0.1.0 codec parses Tier-1 JSON only; received tier '${header.flags.encodingTier}'`,
      { encodingTier: header.flags.encodingTier },
    );
  }
  if (header.flags.encrypted) {
    throw new CodecError(
      "NCP-FRAME-FLAGS-INVALID",
      "Application-layer encryption (ENC=1) is not supported by v0.1.0 codec",
      { flags: header.flags },
    );
  }

  let decodedText: string;
  try {
    decodedText = TEXT_DECODER.decode(payloadBytes);
  } catch (cause) {
    throw new CodecError("NCP-PAYLOAD-NOT-JSON", "Payload is not valid UTF-8", {
      cause: (cause as Error).message,
    });
  }

  let payload: unknown;
  try {
    payload = decodedText === "" ? undefined : JSON.parse(decodedText);
  } catch (cause) {
    throw new CodecError("NCP-PAYLOAD-NOT-JSON", "Payload is not valid JSON", {
      cause: (cause as Error).message,
    });
  }

  return {
    type: header.type,
    flags: header.flags,
    payload: payload as T,
    payloadBytes,
  };
}

function resolveFlags(overrides: Partial<Flags> | undefined): Flags {
  if (!overrides) return DEFAULT_TIER1_FLAGS;
  return {
    encodingTier: overrides.encodingTier ?? DEFAULT_TIER1_FLAGS.encodingTier,
    final: overrides.final ?? DEFAULT_TIER1_FLAGS.final,
    encrypted: overrides.encrypted ?? DEFAULT_TIER1_FLAGS.encrypted,
    extended: overrides.extended ?? DEFAULT_TIER1_FLAGS.extended,
  };
}
