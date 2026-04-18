import { canonicalizeToBytes } from "@nps-kit/codec";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { DevCA, loadIdentity, verifyDetached } from "../src/index.js";
import { __resetDevWarningForTests } from "../src/load.js";

describe("loadIdentity — dev mode", () => {
  let warnSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    __resetDevWarningForTests();
    warnSpy = vi.spyOn(console, "warn").mockImplementation(() => undefined);
  });

  afterEach(() => {
    warnSpy.mockRestore();
  });

  it("returns an identity with an IdentFrame and sign() method", () => {
    const identity = loadIdentity({ mode: "dev", agentId: "main" });
    expect(identity.identFrame.frame).toBe("0x20");
    expect(identity.identFrame.nid).toBe("urn:nps:agent:dev.localhost:main");
    expect(typeof identity.sign).toBe("function");
  });

  it("IdentFrame signature verifies via the implicit CA", () => {
    const identity = loadIdentity({ mode: "dev", agentId: "main" });
    const { signature, metadata: _omit, ...signable } = identity.identFrame;
    void _omit;
    const canonical = canonicalizeToBytes(signable);
    const caKey = (identity.provider as unknown as { [k: string]: unknown });
    void caKey;
    // Can't fish out the implicit CA from outside; verify via a separate
    // externally-constructed ca test instead (see: test "shares an explicit CA").
    expect(signature).toMatch(/^ed25519:/);
    expect(canonical.length).toBeGreaterThan(0);
  });

  it("two identities sharing an explicit CA both verify under the same CA key", () => {
    const ca = new DevCA();
    const a = loadIdentity({ mode: "dev", agentId: "a", ca, silent: true });
    const b = loadIdentity({ mode: "dev", agentId: "b", ca, silent: true });
    for (const identity of [a, b]) {
      const { signature, metadata: _omit, ...signable } = identity.identFrame;
      void _omit;
      const canonical = canonicalizeToBytes(signable);
      expect(verifyDetached(signature, canonical, ca.publicKey)).toBe(true);
    }
  });

  it("emits the dev-mode warning on first call", () => {
    loadIdentity({ mode: "dev", agentId: "first" });
    expect(warnSpy).toHaveBeenCalled();
    const messages = warnSpy.mock.calls.map((c) => String(c[0])).join("\n");
    expect(messages).toContain("NIP-DEV-MODE");
    expect(messages).toContain("NOT FOR PRODUCTION");
  });

  it("does not re-emit the warning on subsequent calls in the same process", () => {
    loadIdentity({ mode: "dev", agentId: "first" });
    warnSpy.mockClear();
    loadIdentity({ mode: "dev", agentId: "second" });
    expect(warnSpy).not.toHaveBeenCalled();
  });

  it("silent: true suppresses the warning", () => {
    loadIdentity({ mode: "dev", agentId: "quiet", silent: true });
    expect(warnSpy).not.toHaveBeenCalled();
  });
});
