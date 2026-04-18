import {
  type IdentFrameMetadata,
  type IdentFramePayload,
  type NipScope,
  canonicalizeToBytes,
} from "@nps-kit/codec";

import {
  type Ed25519Keypair,
  generateEd25519Keypair,
  signDetached,
} from "./ed25519.js";
import { NipError } from "./errors.js";
import { DEV_ORG_DOMAIN, DEV_ORG_NID, isValidNid } from "./nid.js";

/**
 * DevCA — a self-contained, in-memory Certificate Authority for NPS dev mode.
 *
 * Architectural choice (session 2026-04-18): the kit implements option B from
 * the identity-mode fork — a "Shared DevCA per process" rather than an
 * Agent-self-signs-own-frame shortcut or a skip-signature stub. This exercises
 * the same code path production uses (CA signs Agent IdentFrame; Agent
 * carries the signed cert) so that the dev→prod migration is swapping which
 * CA signs, not rewriting the signing model.
 *
 * The DevCA:
 *
 * - Generates a fresh Ed25519 keypair on construction (per process).
 * - Uses the hardcoded NID `urn:nps:org:dev:localhost` so a dev-mode verifier
 *   can trust a single well-known issuer.
 * - Signs IdentFrames via `issueIdentFrame()`. Signatures are computed over
 *   the canonical JSON of the frame minus `signature` and `metadata`
 *   (NPS-3 §5.1: metadata does not participate in signature calculation).
 * - Maintains a monotonic serial counter so each issued cert has a unique
 *   `serial`.
 *
 * Security posture: keypair never leaves the DevCA instance. Private key is
 * held as a Node `KeyObject`, not exported. A process that loses the DevCA
 * instance cannot verify signatures it issued, which is intentional — dev
 * mode is not expected to survive process restarts.
 */
export class DevCA {
  /** DevCA's NID. Always `urn:nps:org:dev:localhost` — dev verifiers trust this literal. */
  readonly nid = DEV_ORG_NID;
  /** Short domain fragment used inside agent NIDs issued by this CA. */
  readonly issuerDomain = DEV_ORG_DOMAIN;

  readonly #keypair: Ed25519Keypair;
  #serialCounter = 0;

  constructor() {
    this.#keypair = generateEd25519Keypair();
  }

  /** Wire-format public key (`ed25519:{base64url(DER SPKI)}`) — for verifier trust configuration. */
  get publicKeyWire(): string {
    return this.#keypair.publicKeyWire;
  }

  /** DevCA's public key as a Node KeyObject — used by verifiers to check signatures. */
  get publicKey() {
    return this.#keypair.publicKey;
  }

  /**
   * Issue a signed IdentFrame to an agent.
   *
   * The caller generates the agent's keypair and passes the wire-format
   * public key plus scope parameters. The DevCA stamps the frame with an
   * auto-incremented serial, 30-day validity (NPS-3 §2.2 default agent
   * cert lifetime), and a signature over the canonical form of everything
   * except `signature` and `metadata`.
   */
  issueIdentFrame(config: {
    agentNid: string;
    agentPublicKey: string;
    capabilities: readonly string[];
    scope: NipScope;
    validityDays?: number;
    metadata?: IdentFrameMetadata;
    issuedAt?: Date;
  }): IdentFramePayload {
    if (!isValidNid(config.agentNid)) {
      throw new NipError(
        "NIP-NID-FORMAT-INVALID",
        `'${config.agentNid}' is not a valid agent NID`,
        { agentNid: config.agentNid },
      );
    }

    const issuedAt = config.issuedAt ?? new Date();
    const validityMs = (config.validityDays ?? 30) * 24 * 60 * 60 * 1000;
    const expiresAt = new Date(issuedAt.getTime() + validityMs);
    this.#serialCounter += 1;
    const serial = `0x${this.#serialCounter.toString(16).toUpperCase().padStart(4, "0")}`;

    // Build the signable object — everything except `signature` and `metadata`.
    // NPS-3 §5.1: metadata does not participate in signature computation.
    const signable = {
      frame: "0x20" as const,
      nid: config.agentNid,
      pub_key: config.agentPublicKey,
      capabilities: [...config.capabilities],
      scope: {
        nodes: [...config.scope.nodes],
        actions: [...config.scope.actions],
        max_token_budget: config.scope.max_token_budget,
      },
      issued_by: this.nid,
      issued_at: issuedAt.toISOString(),
      expires_at: expiresAt.toISOString(),
      serial,
    };
    const canonicalBytes = canonicalizeToBytes(signable);
    const signature = signDetached(canonicalBytes, this.#keypair.privateKey);

    const frame: IdentFramePayload = {
      ...signable,
      signature,
      ...(config.metadata ? { metadata: config.metadata } : {}),
    };
    return frame;
  }
}
