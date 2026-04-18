import { canonicalizeToBytes } from "@nps-kit/codec";
import { describe, expect, it } from "vitest";

import {
  DEV_ORG_NID,
  DevCA,
  NipError,
  buildNid,
  generateEd25519Keypair,
  verifyDetached,
} from "../src/index.js";

describe("DevCA", () => {
  it("has the dev-localhost NID", () => {
    const ca = new DevCA();
    expect(ca.nid).toBe(DEV_ORG_NID);
  });

  it("exposes its public key in wire format", () => {
    const ca = new DevCA();
    expect(ca.publicKeyWire).toMatch(/^ed25519:[A-Za-z0-9_-]+$/);
  });

  it("issues an IdentFrame with expected fields + monotonic serials", () => {
    const ca = new DevCA();
    const { publicKeyWire } = generateEd25519Keypair();
    const scope = { nodes: ["nwp://*"], actions: [], max_token_budget: 1000 };
    const frame1 = ca.issueIdentFrame({
      agentNid: buildNid("agent", ca.issuerDomain, "a1"),
      agentPublicKey: publicKeyWire,
      capabilities: ["nop:delegate"],
      scope,
    });
    const frame2 = ca.issueIdentFrame({
      agentNid: buildNid("agent", ca.issuerDomain, "a2"),
      agentPublicKey: publicKeyWire,
      capabilities: ["nop:delegate"],
      scope,
    });
    expect(frame1.frame).toBe("0x20");
    expect(frame1.issued_by).toBe(DEV_ORG_NID);
    expect(frame1.serial).toBe("0x0001");
    expect(frame2.serial).toBe("0x0002");
    expect(new Date(frame1.expires_at).getTime()).toBeGreaterThan(
      new Date(frame1.issued_at).getTime(),
    );
  });

  it("IdentFrame signature verifies under the CA's public key", () => {
    const ca = new DevCA();
    const { publicKeyWire } = generateEd25519Keypair();
    const frame = ca.issueIdentFrame({
      agentNid: buildNid("agent", ca.issuerDomain, "worker-01"),
      agentPublicKey: publicKeyWire,
      capabilities: ["nop:delegate", "nwp:query"],
      scope: { nodes: ["nwp://api/*"], actions: ["read"], max_token_budget: 5000 },
    });
    // Recreate the signable form per NPS-3 §5.1 — drop signature and metadata.
    const { signature, metadata: _omit, ...signable } = frame;
    void _omit;
    const canonical = canonicalizeToBytes(signable);
    expect(verifyDetached(signature, canonical, ca.publicKey)).toBe(true);
  });

  it("signature does not cover metadata (metadata can change without resigning)", () => {
    const ca = new DevCA();
    const { publicKeyWire } = generateEd25519Keypair();
    const frame = ca.issueIdentFrame({
      agentNid: buildNid("agent", ca.issuerDomain, "m1"),
      agentPublicKey: publicKeyWire,
      capabilities: ["nop:delegate"],
      scope: { nodes: [], actions: [], max_token_budget: 1 },
      metadata: { tokenizer: "cl100k_base" },
    });
    // Mutate the local frame copy's metadata (allowed by spec since it's not signed).
    const withDifferentMetadata = { ...frame, metadata: { tokenizer: "o200k_base" } };
    const { signature, metadata: _omit, ...signable } = withDifferentMetadata;
    void _omit;
    const canonical = canonicalizeToBytes(signable);
    expect(verifyDetached(signature, canonical, ca.publicKey)).toBe(true);
  });

  it("rejects an invalid agent NID", () => {
    const ca = new DevCA();
    const { publicKeyWire } = generateEd25519Keypair();
    expect(() =>
      ca.issueIdentFrame({
        agentNid: "not-a-urn",
        agentPublicKey: publicKeyWire,
        capabilities: ["nop:delegate"],
        scope: { nodes: [], actions: [], max_token_budget: 1 },
      }),
    ).toThrow(NipError);
  });

  it("honors custom validityDays", () => {
    const ca = new DevCA();
    const { publicKeyWire } = generateEd25519Keypair();
    const issuedAt = new Date("2026-01-01T00:00:00Z");
    const frame = ca.issueIdentFrame({
      agentNid: buildNid("agent", ca.issuerDomain, "custom"),
      agentPublicKey: publicKeyWire,
      capabilities: [],
      scope: { nodes: [], actions: [], max_token_budget: 0 },
      validityDays: 7,
      issuedAt,
    });
    expect(frame.issued_at).toBe("2026-01-01T00:00:00.000Z");
    expect(frame.expires_at).toBe("2026-01-08T00:00:00.000Z");
  });
});
