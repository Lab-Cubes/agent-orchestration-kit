import { describe, expect, it } from "vitest";

import {
  NipError,
  decodePublicKey,
  encodePublicKey,
  generateEd25519Keypair,
  signDetached,
  verifyDetached,
} from "../src/index.js";

describe("ed25519 — keypair generation", () => {
  it("produces a public key in ed25519:{base64url} format", () => {
    const pair = generateEd25519Keypair();
    expect(pair.publicKeyWire).toMatch(/^ed25519:[A-Za-z0-9_-]+$/);
  });

  it("produces distinct keypairs on repeated calls", () => {
    const a = generateEd25519Keypair();
    const b = generateEd25519Keypair();
    expect(a.publicKeyWire).not.toBe(b.publicKeyWire);
  });
});

describe("ed25519 — sign / verify round-trip", () => {
  it("signs and verifies bytes", () => {
    const { publicKey, privateKey } = generateEd25519Keypair();
    const data = new TextEncoder().encode("hello world");
    const sig = signDetached(data, privateKey);
    expect(sig).toMatch(/^ed25519:[A-Za-z0-9_-]+$/);
    expect(verifyDetached(sig, data, publicKey)).toBe(true);
  });

  it("rejects a tampered message", () => {
    const { publicKey, privateKey } = generateEd25519Keypair();
    const data = new TextEncoder().encode("hello");
    const sig = signDetached(data, privateKey);
    const tampered = new TextEncoder().encode("hellp");
    expect(verifyDetached(sig, tampered, publicKey)).toBe(false);
  });

  it("rejects a signature from a different key", () => {
    const a = generateEd25519Keypair();
    const b = generateEd25519Keypair();
    const data = new TextEncoder().encode("hello");
    const sig = signDetached(data, a.privateKey);
    expect(verifyDetached(sig, data, b.publicKey)).toBe(false);
  });
});

describe("ed25519 — public key encode / decode round-trip", () => {
  it("encodes then decodes to an equivalent key that verifies signatures", () => {
    const { privateKey, publicKey, publicKeyWire } = generateEd25519Keypair();
    const decoded = decodePublicKey(publicKeyWire);
    expect(encodePublicKey(decoded)).toBe(publicKeyWire);
    const data = new TextEncoder().encode("test");
    const sig = signDetached(data, privateKey);
    expect(verifyDetached(sig, data, decoded)).toBe(true);
    // And sanity: original publicKey still works.
    expect(verifyDetached(sig, data, publicKey)).toBe(true);
  });
});

describe("ed25519 — format rejections", () => {
  it("rejects public key without colon", () => {
    expect(() => decodePublicKey("bogus")).toThrow(NipError);
    expect(() => decodePublicKey("bogus")).toThrow(/wire format/);
  });

  it("rejects unsupported algorithm prefix", () => {
    expect(() => decodePublicKey("rsa:AAAA")).toThrow(/ed25519/);
  });

  it("rejects signature without colon", () => {
    const { publicKey } = generateEd25519Keypair();
    expect(() =>
      verifyDetached("bogus", new TextEncoder().encode("x"), publicKey),
    ).toThrow(NipError);
  });

  it("rejects signature with unsupported algorithm", () => {
    const { publicKey } = generateEd25519Keypair();
    expect(() =>
      verifyDetached("rsa:AAAA", new TextEncoder().encode("x"), publicKey),
    ).toThrow(/ed25519/);
  });
});
