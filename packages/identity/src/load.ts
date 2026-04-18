import { type IdentFrameMetadata, type IdentFramePayload, type NipScope } from "@nps-kit/codec";

import { DevCA } from "./dev-ca.js";
import {
  DEFAULT_DEV_CAPABILITIES,
  DEFAULT_DEV_SCOPE,
  DevIdentityProvider,
} from "./dev-identity.js";

export interface LoadIdentityDevConfig {
  readonly mode: "dev";
  readonly agentId: string;
  readonly ca?: DevCA;
  readonly capabilities?: readonly string[];
  readonly scope?: NipScope;
  readonly metadata?: IdentFrameMetadata;
  readonly validityDays?: number;
  /** Suppress the startup warning (useful in test suites). Default: false. */
  readonly silent?: boolean;
}

export type LoadIdentityConfig = LoadIdentityDevConfig;

export interface Identity {
  readonly identFrame: IdentFramePayload;
  readonly provider: DevIdentityProvider;
  sign(data: Uint8Array): string;
}

let devModeWarningEmitted = false;

/**
 * Emit a single loud warning the first time a dev-mode identity is loaded in
 * this process. Subsequent calls are silent so large test suites don't spam.
 * Can be suppressed entirely with `silent: true`.
 */
function emitDevModeWarning(ca: DevCA): void {
  if (devModeWarningEmitted) return;
  devModeWarningEmitted = true;
  const lines = [
    "[NIP-DEV-MODE] Identity verification uses a per-process DevCA — NOT FOR PRODUCTION.",
    `[NIP-DEV-MODE] Trusted issuer: ${ca.nid}`,
    "[NIP-DEV-MODE] Signatures produced here will not verify outside this process.",
  ];
  for (const line of lines) {
    // eslint-disable-next-line no-console
    console.warn(line);
  }
}

/** Test-only escape hatch to reset the warning latch. Not exported from the package. */
export function __resetDevWarningForTests(): void {
  devModeWarningEmitted = false;
}

/**
 * Public entry point for loading an identity. Dispatches by `config.mode`.
 *
 * In v0.1.0, only `mode: "dev"` is supported. Production mode (CA endpoint
 * integration per NPS-3 §8) is planned for v0.2.0.
 */
export function loadIdentity(config: LoadIdentityConfig): Identity {
  // Only dev mode in v0.1.0; switch expanded in v0.2.0 when production lands.
  const ca = config.ca ?? new DevCA();
  if (!config.silent) {
    emitDevModeWarning(ca);
  }
  const provider = new DevIdentityProvider(ca, {
    agentId: config.agentId,
    ...(config.capabilities !== undefined ? { capabilities: config.capabilities } : {}),
    ...(config.scope !== undefined ? { scope: config.scope } : {}),
    ...(config.metadata !== undefined ? { metadata: config.metadata } : {}),
    ...(config.validityDays !== undefined ? { validityDays: config.validityDays } : {}),
  });
  return {
    identFrame: provider.identFrame,
    provider,
    sign: (data) => provider.sign(data),
  };
}

export { DEFAULT_DEV_CAPABILITIES, DEFAULT_DEV_SCOPE };
