import { type IdentFrameMetadata, type IdentFramePayload, type NipScope } from "@nps-kit/codec";

import { type DevCA } from "./dev-ca.js";
import { type Ed25519Keypair, generateEd25519Keypair, signDetached } from "./ed25519.js";
import { NipError } from "./errors.js";
import { buildNid } from "./nid.js";

const DEV_AGENT_ID_PATTERN = /^[A-Za-z0-9._-]+$/;

/**
 * Default permissive scope for dev-mode agents. Agents that need narrower
 * scope (testing scope-carving logic, for example) pass an explicit scope
 * to the provider.
 */
export const DEFAULT_DEV_SCOPE: NipScope = {
  nodes: ["nwp://*"],
  actions: [],
  max_token_budget: 10_000,
};

export const DEFAULT_DEV_CAPABILITIES: readonly string[] = ["nop:delegate"];

export interface DevIdentityProviderConfig {
  readonly agentId: string;
  readonly capabilities?: readonly string[];
  readonly scope?: NipScope;
  readonly metadata?: IdentFrameMetadata;
  readonly validityDays?: number;
}

/**
 * DevIdentityProvider — an agent-side handle that holds:
 *
 * - the agent's Ed25519 keypair (private key never leaves the provider);
 * - the IdentFrame issued to this agent by a shared DevCA;
 * - a `sign()` method for signing downstream NPS messages with the agent's
 *   private key (distinct from the CA's signing of the IdentFrame itself).
 *
 * Usage:
 *
 *   const ca = new DevCA();
 *   const alice = new DevIdentityProvider(ca, { agentId: "alice" });
 *   const bob   = new DevIdentityProvider(ca, { agentId: "bob" });
 *
 *   alice.identFrame;     // signed by ca
 *   alice.sign(bytes);    // signed by alice's private key, verifiable with alice.publicKey
 */
export class DevIdentityProvider {
  readonly identFrame: IdentFramePayload;
  readonly #keypair: Ed25519Keypair;

  constructor(ca: DevCA, config: DevIdentityProviderConfig) {
    if (!DEV_AGENT_ID_PATTERN.test(config.agentId)) {
      throw new NipError(
        "NIP-DEV-MODE-AGENT-ID-INVALID",
        "Dev-mode agentId must match [A-Za-z0-9._-]+",
        { agentId: config.agentId },
      );
    }
    const agentNid = buildNid("agent", ca.issuerDomain, config.agentId);
    this.#keypair = generateEd25519Keypair();

    this.identFrame = ca.issueIdentFrame({
      agentNid,
      agentPublicKey: this.#keypair.publicKeyWire,
      capabilities: config.capabilities ?? DEFAULT_DEV_CAPABILITIES,
      scope: config.scope ?? DEFAULT_DEV_SCOPE,
      ...(config.metadata !== undefined ? { metadata: config.metadata } : {}),
      ...(config.validityDays !== undefined ? { validityDays: config.validityDays } : {}),
    });
  }

  /** Agent's wire-format public key — exposed so peers can verify agent-signed payloads. */
  get publicKeyWire(): string {
    return this.#keypair.publicKeyWire;
  }

  /** Agent's public key as a Node KeyObject. */
  get publicKey() {
    return this.#keypair.publicKey;
  }

  /**
   * Sign arbitrary bytes with the agent's private key. Returns wire-format
   * `ed25519:{base64url}` suitable for embedding in downstream frames.
   *
   * This is for Agent-level signing (e.g. NOP DelegateFrame signatures).
   * The IdentFrame itself was signed by the CA, not this method.
   */
  sign(data: Uint8Array): string {
    return signDetached(data, this.#keypair.privateKey);
  }
}
