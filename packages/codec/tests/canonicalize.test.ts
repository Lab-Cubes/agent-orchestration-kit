import { describe, expect, it } from "vitest";

import { CodecError, canonicalize, canonicalizeToBytes } from "../src/index.js";

describe("canonicalize — primitives", () => {
  it("null", () => {
    expect(canonicalize(null)).toBe("null");
  });

  it("booleans", () => {
    expect(canonicalize(true)).toBe("true");
    expect(canonicalize(false)).toBe("false");
  });

  it("integers", () => {
    expect(canonicalize(0)).toBe("0");
    expect(canonicalize(42)).toBe("42");
    expect(canonicalize(-1)).toBe("-1");
  });

  it("floats", () => {
    expect(canonicalize(1.5)).toBe("1.5");
    expect(canonicalize(-3.14)).toBe("-3.14");
  });

  it("strings", () => {
    expect(canonicalize("hello")).toBe('"hello"');
    expect(canonicalize("")).toBe('""');
    expect(canonicalize('she said "hi"')).toBe('"she said \\"hi\\""');
  });
});

describe("canonicalize — rejections", () => {
  it("undefined at root", () => {
    expect(() => canonicalize(undefined)).toThrow(CodecError);
    expect(() => canonicalize(undefined)).toThrow(/type undefined/);
  });

  it("NaN and Infinity", () => {
    expect(() => canonicalize(Number.NaN)).toThrow(/non-finite/);
    expect(() => canonicalize(Number.POSITIVE_INFINITY)).toThrow(/non-finite/);
    expect(() => canonicalize(Number.NEGATIVE_INFINITY)).toThrow(/non-finite/);
  });

  it("BigInt", () => {
    expect(() => canonicalize(1n)).toThrow(/BigInt/);
  });

  it("function", () => {
    expect(() => canonicalize(() => 0)).toThrow(/type function/);
  });

  it("symbol", () => {
    expect(() => canonicalize(Symbol("x"))).toThrow(/type symbol/);
  });
});

describe("canonicalize — arrays", () => {
  it("empty", () => {
    expect(canonicalize([])).toBe("[]");
  });

  it("preserves element order", () => {
    expect(canonicalize([3, 1, 2])).toBe("[3,1,2]");
  });

  it("nested", () => {
    expect(canonicalize([[1, 2], [3, 4]])).toBe("[[1,2],[3,4]]");
  });

  it("mixed types", () => {
    expect(canonicalize([1, "two", null, true])).toBe('[1,"two",null,true]');
  });
});

describe("canonicalize — objects", () => {
  it("empty", () => {
    expect(canonicalize({})).toBe("{}");
  });

  it("sorts keys lexicographically", () => {
    expect(canonicalize({ b: 2, a: 1 })).toBe('{"a":1,"b":2}');
  });

  it("produces identical output regardless of insertion order", () => {
    const a = canonicalize({ nid: "x", pub_key: "y", issued_at: "z" });
    const b = canonicalize({ issued_at: "z", pub_key: "y", nid: "x" });
    const c = canonicalize({ pub_key: "y", nid: "x", issued_at: "z" });
    expect(a).toBe(b);
    expect(b).toBe(c);
  });

  it("omits undefined values (consistent with JSON.stringify)", () => {
    expect(canonicalize({ a: 1, b: undefined, c: 2 })).toBe('{"a":1,"c":2}');
  });

  it("nested objects sort recursively", () => {
    expect(canonicalize({ outer: { z: 1, a: 2 } })).toBe('{"outer":{"a":2,"z":1}}');
  });

  it("lexicographic sort uses UTF-16 code-unit order (ASCII is preserved)", () => {
    // Capital letters (0x41-0x5A) sort before lowercase (0x61-0x7A).
    expect(canonicalize({ b: 1, A: 2 })).toBe('{"A":2,"b":1}');
  });

  it("key with quote escapes correctly", () => {
    expect(canonicalize({ 'a"b': 1 })).toBe('{"a\\"b":1}');
  });
});

describe("canonicalize — realistic IdentFrame-shaped input", () => {
  it("is stable and insertion-order-independent", () => {
    const ident = {
      frame: "0x20",
      nid: "urn:nps:agent:dev:localhost:agent-01",
      pub_key: "ed25519:MCowBQYDK2VwAyEA1234",
      capabilities: ["nop:delegate", "nwp:query"],
      scope: {
        nodes: ["nwp://*"],
        actions: [],
        max_token_budget: 10000,
      },
      issued_by: "urn:nps:org:dev:localhost",
      issued_at: "2026-04-18T14:00:00Z",
      expires_at: "2026-05-18T14:00:00Z",
      serial: "0x0001",
    };
    // Build a reordered clone.
    const reordered = {
      issued_at: ident.issued_at,
      scope: { max_token_budget: 10000, actions: [], nodes: ["nwp://*"] },
      serial: ident.serial,
      frame: ident.frame,
      pub_key: ident.pub_key,
      expires_at: ident.expires_at,
      nid: ident.nid,
      issued_by: ident.issued_by,
      capabilities: ident.capabilities,
    };
    expect(canonicalize(ident)).toBe(canonicalize(reordered));
  });
});

describe("canonicalizeToBytes", () => {
  it("returns UTF-8 bytes of canonical form", () => {
    const bytes = canonicalizeToBytes({ b: 2, a: 1 });
    expect(new TextDecoder().decode(bytes)).toBe('{"a":1,"b":2}');
  });
});
