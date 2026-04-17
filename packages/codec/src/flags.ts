import { CodecError } from "./errors.js";

/**
 * Flags byte layout per NPS-1 §3.2:
 *
 *   Bit 7   Bit 6   Bit 5   Bit 4   Bit 3   Bit 2   Bit 1   Bit 0
 *   ┌─────┬─────┬─────┬─────┬─────┬───────┬─────┬─────┐
 *   │ EXT │ RSV │ RSV │ RSV │ ENC │ FINAL │ T1  │ T0  │
 *   └─────┴─────┴─────┴─────┴─────┴───────┴─────┴─────┘
 *
 * Bits 0-1 = encoding tier (T0, T1).
 * Bit 2    = FINAL (StreamFrame terminal chunk; fixed 1 for non-stream frames).
 * Bit 3    = ENC   (application-layer E2E encryption on payload).
 * Bits 4-6 = RSV   (MUST be zero; receiver MUST ignore).
 * Bit 7    = EXT   (extended 8-byte header when set).
 */

export type EncodingTier =
  | "tier1-json"
  | "tier2-msgpack"
  | "reserved-10"
  | "reserved-11";

export interface Flags {
  readonly encodingTier: EncodingTier;
  readonly final: boolean;
  readonly encrypted: boolean;
  readonly extended: boolean;
}

const FINAL_BIT = 0b0000_0100;
const ENC_BIT = 0b0000_1000;
const RSV_MASK = 0b0111_0000;
const EXT_BIT = 0b1000_0000;
const TIER_MASK = 0b0000_0011;

const TIER_BY_BITS: Record<number, EncodingTier> = {
  0b00: "tier1-json",
  0b01: "tier2-msgpack",
  0b10: "reserved-10",
  0b11: "reserved-11",
};

const BITS_BY_TIER: Record<EncodingTier, number> = {
  "tier1-json": 0b00,
  "tier2-msgpack": 0b01,
  "reserved-10": 0b10,
  "reserved-11": 0b11,
};

export function encodeFlags(flags: Flags): number {
  const tierBits = BITS_BY_TIER[flags.encodingTier];
  let byte = tierBits & TIER_MASK;
  if (flags.final) byte |= FINAL_BIT;
  if (flags.encrypted) byte |= ENC_BIT;
  if (flags.extended) byte |= EXT_BIT;
  return byte;
}

export function decodeFlags(byte: number): Flags {
  if (byte < 0 || byte > 0xff || !Number.isInteger(byte)) {
    throw new CodecError(
      "NCP-FRAME-FLAGS-INVALID",
      `Flags byte out of range: ${byte}`,
      { byte },
    );
  }
  if ((byte & RSV_MASK) !== 0) {
    throw new CodecError(
      "NCP-FRAME-FLAGS-INVALID",
      `Reserved flag bits (4-6) are non-zero: 0b${byte.toString(2).padStart(8, "0")}`,
      { byte },
    );
  }
  const tier = TIER_BY_BITS[byte & TIER_MASK];
  // TIER_MASK restricts to 2 bits (0-3), all of which are mapped above.
  /* c8 ignore next 3 */
  if (!tier) {
    throw new CodecError("NCP-FRAME-FLAGS-INVALID", "Unreachable tier bits", { byte });
  }
  return {
    encodingTier: tier,
    final: (byte & FINAL_BIT) !== 0,
    encrypted: (byte & ENC_BIT) !== 0,
    extended: (byte & EXT_BIT) !== 0,
  };
}

export const DEFAULT_TIER1_FLAGS: Flags = {
  encodingTier: "tier1-json",
  final: true,
  encrypted: false,
  extended: false,
};
