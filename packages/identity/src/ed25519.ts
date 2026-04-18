import {
  type KeyObject,
  createPublicKey,
  generateKeyPairSync,
  sign as nodeSign,
  verify as nodeVerify,
} from "node:crypto";

import { NipError } from "./errors.js";

/**
 * Ed25519 primitives wrapped around Node's `node:crypto` module.
 *
 * Primary algorithm per NPS-3 §4; ECDSA P-256 fallback is deferred to v0.2.0
 * since dev mode has no interop requirement with environments that reject
 * Ed25519 (which is rare).
 *
 * Public key wire format per NPS-3 §4:
 *
 *   {algorithm}:{base64url(DER SPKI)}
 *
 * where SPKI is X.509 SubjectPublicKeyInfo DER encoding, which Node emits
 * natively via `keyObject.export({ type: 'spki', format: 'der' })`.
 *
 * Signature wire format (same shape):
 *
 *   {algorithm}:{base64url(raw signature)}
 *
 * Ed25519 signatures are a fixed 64 bytes (R || S), raw.
 */

export interface Ed25519Keypair {
  readonly publicKey: KeyObject;
  readonly privateKey: KeyObject;
  /** `ed25519:<base64url(DER SPKI)>` — the form that ships in IdentFrame.pub_key. */
  readonly publicKeyWire: string;
}

export function generateEd25519Keypair(): Ed25519Keypair {
  let publicKey: KeyObject;
  let privateKey: KeyObject;
  try {
    const pair = generateKeyPairSync("ed25519");
    publicKey = pair.publicKey;
    privateKey = pair.privateKey;
  } catch (cause) {
    throw new NipError(
      "NIP-KEY-GENERATION-FAILED",
      "Node failed to generate an Ed25519 keypair",
      { cause: (cause as Error).message },
    );
  }
  return {
    publicKey,
    privateKey,
    publicKeyWire: encodePublicKey(publicKey),
  };
}

export function encodePublicKey(key: KeyObject): string {
  const der = key.export({ type: "spki", format: "der" });
  return `ed25519:${Buffer.from(der).toString("base64url")}`;
}

export function decodePublicKey(wire: string): KeyObject {
  const colonIndex = wire.indexOf(":");
  if (colonIndex === -1) {
    throw new NipError(
      "NIP-PUBLIC-KEY-FORMAT-INVALID",
      "Public key wire format must be '{algorithm}:{base64url}'",
      { wire },
    );
  }
  const algorithm = wire.slice(0, colonIndex);
  const encoded = wire.slice(colonIndex + 1);
  if (algorithm !== "ed25519") {
    throw new NipError(
      "NIP-PUBLIC-KEY-FORMAT-INVALID",
      `Only 'ed25519' public keys are supported in v0.1.0; got '${algorithm}'`,
      { algorithm },
    );
  }
  let der: Buffer;
  try {
    der = Buffer.from(encoded, "base64url");
  } catch (cause) {
    throw new NipError(
      "NIP-PUBLIC-KEY-FORMAT-INVALID",
      "Public key base64url decoding failed",
      { cause: (cause as Error).message },
    );
  }
  try {
    return createPublicKey({ key: der, format: "der", type: "spki" });
  } catch (cause) {
    throw new NipError(
      "NIP-KEY-IMPORT-FAILED",
      "Decoded bytes are not a valid Ed25519 SPKI public key",
      { cause: (cause as Error).message },
    );
  }
}

/**
 * Sign bytes with an Ed25519 private key, return `ed25519:{base64url(sig)}`
 * suitable for direct use as an NIP `signature` field value.
 */
export function signDetached(data: Uint8Array, privateKey: KeyObject): string {
  let sig: Buffer;
  try {
    // Ed25519 takes `null` for the algorithm parameter — it's implied by the key.
    sig = nodeSign(null, data, privateKey);
  } catch (cause) {
    throw new NipError(
      "NIP-SIGNATURE-FAILED",
      "Ed25519 signing failed",
      { cause: (cause as Error).message },
    );
  }
  return `ed25519:${sig.toString("base64url")}`;
}

/**
 * Verify a wire-format signature (`ed25519:{base64url}`) against bytes using
 * a public key. Returns true iff the signature is valid.
 */
export function verifyDetached(
  signatureWire: string,
  data: Uint8Array,
  publicKey: KeyObject,
): boolean {
  const colonIndex = signatureWire.indexOf(":");
  if (colonIndex === -1) {
    throw new NipError(
      "NIP-SIGNATURE-FORMAT-INVALID",
      "Signature wire format must be '{algorithm}:{base64url}'",
      { signatureWire },
    );
  }
  const algorithm = signatureWire.slice(0, colonIndex);
  if (algorithm !== "ed25519") {
    throw new NipError(
      "NIP-SIGNATURE-FORMAT-INVALID",
      `Only 'ed25519' signatures are supported in v0.1.0; got '${algorithm}'`,
      { algorithm },
    );
  }
  const sigBytes = Buffer.from(signatureWire.slice(colonIndex + 1), "base64url");
  return nodeVerify(null, data, publicKey, sigBytes);
}
