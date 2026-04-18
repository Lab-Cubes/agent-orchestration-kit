export { NipError, type NipErrorCode } from "./errors.js";

export {
  type Ed25519Keypair,
  decodePublicKey,
  encodePublicKey,
  generateEd25519Keypair,
  signDetached,
  verifyDetached,
} from "./ed25519.js";

export {
  DEV_ORG_DOMAIN,
  DEV_ORG_NID,
  type NidEntityType,
  type ParsedNid,
  buildNid,
  isValidNid,
  parseNid,
} from "./nid.js";

export { DevCA } from "./dev-ca.js";

export {
  DEFAULT_DEV_CAPABILITIES,
  DEFAULT_DEV_SCOPE,
  DevIdentityProvider,
  type DevIdentityProviderConfig,
} from "./dev-identity.js";

export {
  type Identity,
  type LoadIdentityConfig,
  type LoadIdentityDevConfig,
  loadIdentity,
} from "./load.js";
