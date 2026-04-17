import { describe, expect, it } from "vitest";

import { CodecError } from "../src/errors.js";
import {
  DEFAULT_TIER1_FLAGS,
  decodeFlags,
  encodeFlags,
} from "../src/flags.js";

describe("flags", () => {
  it("default tier-1 flags round-trip to 0b00000100 (FINAL=1, tier-1 JSON)", () => {
    const byte = encodeFlags(DEFAULT_TIER1_FLAGS);
    expect(byte).toBe(0b0000_0100);
    expect(decodeFlags(byte)).toEqual(DEFAULT_TIER1_FLAGS);
  });

  it("decodes tier-2 msgpack bits", () => {
    const flags = decodeFlags(0b0000_0101);
    expect(flags.encodingTier).toBe("tier2-msgpack");
    expect(flags.final).toBe(true);
  });

  it("round-trips an extended + encrypted + non-final tier-2 flags byte", () => {
    const flags = {
      encodingTier: "tier2-msgpack" as const,
      final: false,
      encrypted: true,
      extended: true,
    };
    const byte = encodeFlags(flags);
    expect(decodeFlags(byte)).toEqual(flags);
  });

  it("rejects reserved bits 4-6 being non-zero", () => {
    expect(() => decodeFlags(0b0001_0100)).toThrow(CodecError);
    expect(() => decodeFlags(0b0010_0100)).toThrow(/Reserved flag bits/);
    expect(() => decodeFlags(0b0100_0100)).toThrow(/Reserved flag bits/);
  });

  it("rejects out-of-range bytes", () => {
    expect(() => decodeFlags(-1)).toThrow(/out of range/);
    expect(() => decodeFlags(256)).toThrow(/out of range/);
    expect(() => decodeFlags(1.5)).toThrow(/out of range/);
  });
});
