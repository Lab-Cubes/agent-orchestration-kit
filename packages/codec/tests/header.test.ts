import { describe, expect, it } from "vitest";

import { CodecError } from "../src/errors.js";
import { DEFAULT_TIER1_FLAGS } from "../src/flags.js";
import {
  FIXED_HEADER_BYTES,
  MAX_FIXED_PAYLOAD,
  decodeFixedHeader,
  encodeFixedHeader,
} from "../src/header.js";

describe("header", () => {
  it("encodes a 4-byte fixed header with big-endian length", () => {
    const bytes = encodeFixedHeader({
      type: 0x04,
      flags: DEFAULT_TIER1_FLAGS,
      payloadLength: 0x1234,
    });
    expect(bytes.length).toBe(FIXED_HEADER_BYTES);
    expect(bytes[0]).toBe(0x04);
    expect(bytes[1]).toBe(0b0000_0100);
    expect(bytes[2]).toBe(0x12);
    expect(bytes[3]).toBe(0x34);
  });

  it("round-trips encode → decode", () => {
    const header = {
      type: 0xfe,
      flags: DEFAULT_TIER1_FLAGS,
      payloadLength: 42,
    };
    const bytes = encodeFixedHeader(header);
    expect(decodeFixedHeader(bytes)).toEqual(header);
  });

  it("decodes the max fixed-header payload length (65,535)", () => {
    const bytes = new Uint8Array([0x01, 0b0000_0100, 0xff, 0xff]);
    const header = decodeFixedHeader(bytes);
    expect(header.payloadLength).toBe(MAX_FIXED_PAYLOAD);
  });

  it("rejects truncated input", () => {
    expect(() => decodeFixedHeader(new Uint8Array([0x01, 0x04, 0x00]))).toThrow(
      CodecError,
    );
  });

  it("rejects payload lengths > 65,535 at encode time", () => {
    expect(() =>
      encodeFixedHeader({
        type: 0x04,
        flags: DEFAULT_TIER1_FLAGS,
        payloadLength: MAX_FIXED_PAYLOAD + 1,
      }),
    ).toThrow(/exceeds fixed-header max/);
  });

  it("rejects EXT=1 flags at encode time (deferred to v0.2.0)", () => {
    expect(() =>
      encodeFixedHeader({
        type: 0x04,
        flags: { ...DEFAULT_TIER1_FLAGS, extended: true },
        payloadLength: 0,
      }),
    ).toThrow(/Extended header/);
  });

  it("rejects EXT=1 flags at decode time", () => {
    const bytes = new Uint8Array([0x04, 0b1000_0100, 0x00, 0x00]);
    expect(() => decodeFixedHeader(bytes)).toThrow(/Extended header/);
  });

  it("decodes a 4-byte subarray from within a larger buffer", () => {
    const buffer = new Uint8Array(16);
    buffer.set([0xde, 0xad, 0xbe, 0xef], 0);
    buffer.set([0x01, 0b0000_0100, 0x00, 0x05], 4);
    const header = decodeFixedHeader(buffer.subarray(4, 8));
    expect(header.type).toBe(0x01);
    expect(header.payloadLength).toBe(5);
  });
});
