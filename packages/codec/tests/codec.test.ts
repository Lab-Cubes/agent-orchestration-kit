import { describe, expect, it } from "vitest";

import {
  type AnchorFramePayload,
  type CapsFramePayload,
  CodecError,
  type DiffFramePayload,
  type ErrorFramePayload,
  FIXED_HEADER_BYTES,
  FrameType,
  type HelloFramePayload,
  type IdentFramePayload,
  MAX_FIXED_PAYLOAD,
  type RevokeFramePayload,
  type StreamFramePayload,
  type TrustFramePayload,
  buildFrame,
  parseFrame,
} from "../src/index.js";

function assertRoundTrip<T>(type: number, payload: T): void {
  const bytes = buildFrame(type, payload);
  const parsed = parseFrame<T>(bytes);
  expect(parsed.type).toBe(type);
  expect(parsed.flags.encodingTier).toBe("tier1-json");
  expect(parsed.flags.final).toBe(true);
  expect(parsed.flags.encrypted).toBe(false);
  expect(parsed.flags.extended).toBe(false);
  expect(parsed.payload).toEqual(payload);
  expect(parsed.frameLength).toBe(bytes.length);
  expect(parsed.payloadBytes.length).toBe(bytes.length - FIXED_HEADER_BYTES);
}

describe("buildFrame / parseFrame round-trips", () => {
  it("AnchorFrame (0x01)", () => {
    const payload: AnchorFramePayload = {
      frame: "0x01",
      anchor_id: "sha256:a3f9b2c1d4e5f6789012345678901234567890abcdef1234567890abcdef12",
      schema: {
        fields: [
          { name: "id", type: "uint64", semantic: "entity.id" },
          { name: "name", type: "string", semantic: "entity.label" },
          { name: "price", type: "decimal", semantic: "commerce.price.usd" },
        ],
      },
      ttl: 3600,
    };
    assertRoundTrip(FrameType.AnchorFrame, payload);
  });

  it("DiffFrame (0x02) with json_patch", () => {
    const payload: DiffFramePayload = {
      frame: "0x02",
      anchor_ref: "sha256:a3f9b2c1",
      base_seq: 42,
      patch_format: "json_patch",
      entity_id: "product:1001",
      patch: [
        { op: "replace", path: "/price", value: 299 },
        { op: "replace", path: "/stock", value: 48 },
      ],
    };
    assertRoundTrip(FrameType.DiffFrame, payload);
  });

  it("StreamFrame (0x03) with window_size", () => {
    const payload: StreamFramePayload = {
      frame: "0x03",
      stream_id: "550e8400-e29b-41d4-a716-446655440000",
      seq: 0,
      is_last: false,
      anchor_ref: "sha256:a3f9b2c1",
      data: [{ id: 1001 }, { id: 1002 }],
      window_size: 32,
    };
    assertRoundTrip(FrameType.StreamFrame, payload);
  });

  it("CapsFrame (0x04) with pagination and inline_anchor", () => {
    const payload: CapsFramePayload = {
      frame: "0x04",
      anchor_ref: "sha256:a3f9b2c1",
      count: 2,
      data: [
        { id: 1001, name: "iPhone 15 Pro", price: 999, stock: 42 },
        { id: 1002, name: "MacBook Air M3", price: 1299, stock: 15 },
      ],
      next_cursor: "eyJpZCI6MTAwM30",
      token_est: 180,
      cached: false,
    };
    assertRoundTrip(FrameType.CapsFrame, payload);
  });

  it("HelloFrame (0x06)", () => {
    const payload: HelloFramePayload = {
      frame: "0x06",
      nps_version: "0.4",
      min_version: "0.3",
      supported_encodings: ["json", "msgpack"],
      supported_protocols: ["ncp", "nwp", "nip"],
      agent_id: "urn:nps:agent:ca.innolotus.com:550e8400",
      max_frame_payload: 65535,
      ext_support: false,
      max_concurrent_streams: 16,
      e2e_enc_algorithms: ["aes-256-gcm", "chacha20-poly1305"],
    };
    assertRoundTrip(FrameType.HelloFrame, payload);
  });

  it("IdentFrame (0x20)", () => {
    const payload: IdentFramePayload = {
      frame: "0x20",
      nid: "urn:nps:agent:ca.innolotus.com:550e8400-e29b-41d4",
      pub_key: "ed25519:MCowBQYDK2VwAyEA1234567890abcdef",
      capabilities: ["nwp:query", "nwp:action", "ncp:stream"],
      scope: {
        nodes: ["nwp://api.myapp.com/*"],
        actions: ["orders:read", "orders:create"],
        max_token_budget: 50000,
      },
      issued_by: "urn:nps:org:mycompany.com",
      issued_at: "2026-04-10T00:00:00Z",
      expires_at: "2026-05-10T00:00:00Z",
      serial: "0x0A3F9C",
      signature: "ed25519:3045022100abcdef",
      metadata: {
        model_family: "anthropic/claude-4",
        tokenizer: "cl100k_base",
      },
    };
    assertRoundTrip(FrameType.IdentFrame, payload);
  });

  it("TrustFrame (0x21)", () => {
    const payload: TrustFramePayload = {
      frame: "0x21",
      grantor_nid: "urn:nps:org:org-a.com",
      grantee_ca: "urn:nps:org:org-b.com",
      trust_scope: ["nwp:query"],
      nodes: ["nwp://api.org-a.com/public/*"],
      expires_at: "2026-12-31T00:00:00Z",
      signature: "ed25519:abcdef",
    };
    assertRoundTrip(FrameType.TrustFrame, payload);
  });

  it("RevokeFrame (0x22)", () => {
    const payload: RevokeFramePayload = {
      frame: "0x22",
      target_nid: "urn:nps:agent:ca.innolotus.com:550e8400-e29b-41d4",
      serial: "0x0A3F9C",
      reason: "key_compromise",
      revoked_at: "2026-04-10T12:00:00Z",
      signature: "ed25519:abcdef",
    };
    assertRoundTrip(FrameType.RevokeFrame, payload);
  });

  it("ErrorFrame (0xFE)", () => {
    const payload: ErrorFramePayload = {
      frame: "0xFE",
      status: "NPS-CLIENT-NOT-FOUND",
      error: "NCP-ANCHOR-NOT-FOUND",
      message: "Schema anchor not found in cache, please resend AnchorFrame",
      details: { anchor_ref: "sha256:a3f9b2c1" },
    };
    assertRoundTrip(FrameType.ErrorFrame, payload);
  });

  it("exposes payloadBytes as the raw UTF-8 JSON slice", () => {
    const bytes = buildFrame(FrameType.ErrorFrame, {
      frame: "0xFE",
      status: "ok",
      error: "ok",
    });
    const parsed = parseFrame(bytes);
    expect(new TextDecoder().decode(parsed.payloadBytes)).toBe(
      JSON.stringify({ frame: "0xFE", status: "ok", error: "ok" }),
    );
  });

  it("accepts a trailing suffix in the input buffer and parses the frame prefix", () => {
    const frame = buildFrame(FrameType.ErrorFrame, {
      frame: "0xFE",
      status: "s",
      error: "e",
    });
    const padded = new Uint8Array(frame.length + 8);
    padded.set(frame, 0);
    padded.fill(0xaa, frame.length);
    const parsed = parseFrame(padded);
    expect(parsed.payload).toEqual({ frame: "0xFE", status: "s", error: "e" });
    expect(parsed.frameLength).toBe(frame.length);
  });

  it("parses a frame carved as a subarray of a larger buffer", () => {
    const frame = buildFrame(FrameType.ErrorFrame, {
      frame: "0xFE",
      status: "s",
      error: "e",
    });
    const surrounding = new Uint8Array(frame.length + 16);
    surrounding.set(frame, 8);
    const parsed = parseFrame(surrounding.subarray(8, 8 + frame.length));
    expect(parsed.payload).toEqual({ frame: "0xFE", status: "s", error: "e" });
  });

  it("round-trips root-level JSON primitives (null, number, array, string)", () => {
    for (const value of [null, 42, 0, -1.5, "hello", [1, 2, 3], []] as const) {
      const bytes = buildFrame(FrameType.ErrorFrame, value);
      const parsed = parseFrame(bytes);
      expect(parsed.payload).toEqual(value);
      expect(parsed.frameLength).toBe(bytes.length);
    }
  });
});

describe("buildFrame — rejects", () => {
  it("AlignFrame (0x05, deprecated)", () => {
    expect(() => buildFrame(FrameType.AlignFrame, { frame: "0x05" })).toThrow(
      /deprecated/,
    );
  });

  it("out-of-NPS-range frame types (0x50+)", () => {
    const err = getError(() => buildFrame(0x50, {}));
    expect(err).toBeInstanceOf(CodecError);
    expect(err.code).toBe("NCP-FRAME-UNKNOWN-TYPE");
  });

  it("still accepts NWP range (0x10) now that widening covers all NPS frames", () => {
    // Codec builds any in-range frame as Tier-1 JSON; sub-protocol semantics
    // are the caller's responsibility.
    const bytes = buildFrame(0x10, { frame: "0x10", query: "products" });
    const parsed = parseFrame(bytes);
    expect(parsed.type).toBe(0x10);
  });

  it("Tier-2 MsgPack requests (v0.1.0 tier-1 only)", () => {
    const err = getError(() =>
      buildFrame(FrameType.CapsFrame, {}, { flags: { encodingTier: "tier2-msgpack" } }),
    );
    expect(err).toBeInstanceOf(CodecError);
    expect(err.code).toBe("NCP-ENCODING-UNSUPPORTED");
  });

  it("ENC=1 requests", () => {
    const err = getError(() =>
      buildFrame(FrameType.CapsFrame, {}, { flags: { encrypted: true } }),
    );
    expect(err.code).toBe("NCP-FRAME-FLAGS-INVALID");
  });

  it("EXT=1 requests", () => {
    const err = getError(() =>
      buildFrame(FrameType.CapsFrame, {}, { flags: { extended: true } }),
    );
    expect(err.code).toBe("NCP-FRAME-FLAGS-INVALID");
  });

  it("non-JSON-serializable payloads (root undefined)", () => {
    const err = getError(() => buildFrame(FrameType.CapsFrame, undefined));
    expect(err.code).toBe("CODEC-PAYLOAD-NOT-JSON");
  });

  it("BigInt payloads (JSON.stringify throws TypeError)", () => {
    const err = getError(() => buildFrame(FrameType.CapsFrame, { n: 1n }));
    expect(err.code).toBe("CODEC-PAYLOAD-NOT-JSON");
  });

  it("circular-reference payloads", () => {
    const obj: { self?: unknown } = {};
    obj.self = obj;
    const err = getError(() => buildFrame(FrameType.CapsFrame, obj));
    expect(err.code).toBe("CODEC-PAYLOAD-NOT-JSON");
  });

  it("payloads exceeding the 64 KiB fixed-header max", () => {
    // Build a value whose JSON encoding exceeds 64 KiB.
    const big = "x".repeat(MAX_FIXED_PAYLOAD);
    const err = getError(() => buildFrame(FrameType.CapsFrame, { s: big }));
    expect(err.code).toBe("NCP-FRAME-PAYLOAD-TOO-LARGE");
  });
});

describe("parseFrame — rejects", () => {
  it("frames with a type outside the NPS range (0x50+) and not 0xFE", () => {
    // 0x50 falls outside all NPS sub-protocol ranges (highest is NOP 0x40-0x4F).
    const payload = new TextEncoder().encode("{}");
    const buf = new Uint8Array(FIXED_HEADER_BYTES + payload.length);
    buf[0] = 0x50;
    buf[1] = 0b0000_0100;
    buf[2] = 0x00;
    buf[3] = payload.length;
    buf.set(payload, FIXED_HEADER_BYTES);
    const err = getError(() => parseFrame(buf));
    expect(err.code).toBe("NCP-FRAME-UNKNOWN-TYPE");
  });

  it("truncated payloads", () => {
    const payload = new TextEncoder().encode('{"frame":"0xFE"}');
    const buf = new Uint8Array(FIXED_HEADER_BYTES + 3);
    buf[0] = 0xfe;
    buf[1] = 0b0000_0100;
    buf[2] = 0x00;
    buf[3] = payload.length; // claims more than we actually include
    buf.set(payload.subarray(0, 3), FIXED_HEADER_BYTES);
    const err = getError(() => parseFrame(buf));
    expect(err.code).toBe("CODEC-FRAME-TRUNCATED");
  });

  it("Tier-2 MsgPack frames", () => {
    const buf = new Uint8Array(FIXED_HEADER_BYTES);
    buf[0] = 0x04;
    buf[1] = 0b0000_0101; // tier-2 msgpack
    const err = getError(() => parseFrame(buf));
    expect(err.code).toBe("NCP-ENCODING-UNSUPPORTED");
  });

  it("zero-length payload frames (symmetric with build-side reject of undefined)", () => {
    const buf = new Uint8Array(FIXED_HEADER_BYTES);
    buf[0] = FrameType.ErrorFrame;
    buf[1] = 0b0000_0100;
    buf[2] = 0x00;
    buf[3] = 0x00;
    const err = getError(() => parseFrame(buf));
    expect(err.code).toBe("CODEC-PAYLOAD-NOT-JSON");
  });

  it("ENC=1 frames", () => {
    const buf = new Uint8Array(FIXED_HEADER_BYTES);
    buf[0] = 0x04;
    buf[1] = 0b0000_1100; // FINAL | ENC
    const err = getError(() => parseFrame(buf));
    expect(err.code).toBe("NCP-FRAME-FLAGS-INVALID");
  });

  it("non-UTF-8 payload bytes", () => {
    // Build header manually with a 1-byte payload that is invalid UTF-8 (0xff on its own).
    const buf = new Uint8Array(FIXED_HEADER_BYTES + 1);
    buf[0] = FrameType.ErrorFrame;
    buf[1] = 0b0000_0100;
    buf[2] = 0x00;
    buf[3] = 0x01;
    buf[4] = 0xff;
    const err = getError(() => parseFrame(buf));
    expect(err.code).toBe("CODEC-PAYLOAD-NOT-JSON");
  });

  it("non-JSON payload bytes", () => {
    const payload = new TextEncoder().encode("not json");
    const buf = new Uint8Array(FIXED_HEADER_BYTES + payload.length);
    buf[0] = FrameType.ErrorFrame;
    buf[1] = 0b0000_0100;
    buf[2] = 0x00;
    buf[3] = payload.length;
    buf.set(payload, FIXED_HEADER_BYTES);
    const err = getError(() => parseFrame(buf));
    expect(err.code).toBe("CODEC-PAYLOAD-NOT-JSON");
  });

  it("deprecated AlignFrame (0x05) parses for receive-side compatibility", () => {
    // Built manually since buildFrame rejects 0x05.
    const payload = new TextEncoder().encode('{"frame":"0x05"}');
    const buf = new Uint8Array(FIXED_HEADER_BYTES + payload.length);
    buf[0] = 0x05;
    buf[1] = 0b0000_0100;
    buf[2] = 0x00;
    buf[3] = payload.length;
    buf.set(payload, FIXED_HEADER_BYTES);
    const parsed = parseFrame(buf);
    expect(parsed.type).toBe(0x05);
    expect(parsed.payload).toEqual({ frame: "0x05" });
  });
});

function getError(fn: () => unknown): CodecError {
  try {
    fn();
  } catch (err) {
    if (err instanceof CodecError) return err;
    throw err;
  }
  throw new Error("Expected function to throw a CodecError, but it returned normally.");
}
