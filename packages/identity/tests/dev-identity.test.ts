import { canonicalizeToBytes } from "@nps-kit/codec";
import { describe, expect, it } from "vitest";

import {
  DEFAULT_DEV_SCOPE,
  DEV_ORG_NID,
  DevCA,
  DevIdentityProvider,
  NipError,
  verifyDetached,
} from "../src/index.js";

describe("DevIdentityProvider", () => {
  it("issues an IdentFrame whose NID follows the dev-localhost pattern", () => {
    const ca = new DevCA();
    const provider = new DevIdentityProvider(ca, { agentId: "worker-01" });
    expect(provider.identFrame.nid).toBe("urn:nps:agent:dev.localhost:worker-01");
    expect(provider.identFrame.issued_by).toBe(DEV_ORG_NID);
  });

  it("publishes the agent's public key distinct from the CA's", () => {
    const ca = new DevCA();
    const provider = new DevIdentityProvider(ca, { agentId: "alice" });
    expect(provider.publicKeyWire).not.toBe(ca.publicKeyWire);
    expect(provider.identFrame.pub_key).toBe(provider.publicKeyWire);
  });

  it("two providers sharing one CA both verify under that CA's key", () => {
    const ca = new DevCA();
    const a = new DevIdentityProvider(ca, { agentId: "a" });
    const b = new DevIdentityProvider(ca, { agentId: "b" });
    for (const provider of [a, b]) {
      const { signature, metadata: _omit, ...signable } = provider.identFrame;
      void _omit;
      const canonical = canonicalizeToBytes(signable);
      expect(verifyDetached(signature, canonical, ca.publicKey)).toBe(true);
    }
  });

  it("provider.sign() produces a signature verifiable with the agent's public key (not CA's)", () => {
    const ca = new DevCA();
    const provider = new DevIdentityProvider(ca, { agentId: "signer" });
    const message = new TextEncoder().encode("delegated subtask payload");
    const sig = provider.sign(message);
    expect(verifyDetached(sig, message, provider.publicKey)).toBe(true);
    expect(verifyDetached(sig, message, ca.publicKey)).toBe(false);
  });

  it("applies default capabilities and scope when not overridden", () => {
    const ca = new DevCA();
    const provider = new DevIdentityProvider(ca, { agentId: "defaults" });
    expect(provider.identFrame.capabilities).toEqual(["nop:delegate"]);
    expect(provider.identFrame.scope).toEqual(DEFAULT_DEV_SCOPE);
  });

  it("threads through metadata without signing it", () => {
    const ca = new DevCA();
    const provider = new DevIdentityProvider(ca, {
      agentId: "meta",
      metadata: { model_family: "anthropic/claude-4" },
    });
    expect(provider.identFrame.metadata).toEqual({ model_family: "anthropic/claude-4" });
  });

  it("rejects agent IDs with illegal characters", () => {
    const ca = new DevCA();
    expect(() => new DevIdentityProvider(ca, { agentId: "has spaces" })).toThrow(NipError);
    expect(() => new DevIdentityProvider(ca, { agentId: "slash/here" })).toThrow(NipError);
  });
});
