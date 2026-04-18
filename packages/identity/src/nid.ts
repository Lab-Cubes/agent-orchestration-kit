import { NipError } from "./errors.js";

/**
 * NID format per NPS-0 §5.2 / NPS-3 §3:
 *
 *   urn:nps:<entity-type>:<issuer-domain>:<identifier>
 *
 *   entity-type  = "agent" | "node" | "org"
 *   issuer-domain = RFC 1034 domain
 *   identifier   = 1*(ALPHA / DIGIT / "-" / "_" / ".")
 */

export type NidEntityType = "agent" | "node" | "org";

export interface ParsedNid {
  readonly entityType: NidEntityType;
  readonly issuerDomain: string;
  readonly identifier: string;
}

const NID_PATTERN = /^urn:nps:(agent|node|org):([A-Za-z0-9.-]+):([A-Za-z0-9._-]+)$/;
const ORG_PATTERN = /^urn:nps:org:([A-Za-z0-9.-]+)$/;

export function buildNid(
  entityType: NidEntityType,
  issuerDomain: string,
  identifier?: string,
): string {
  if (entityType === "org") {
    if (identifier !== undefined) {
      throw new NipError(
        "NIP-NID-FORMAT-INVALID",
        "Org NIDs do not take an identifier — the domain itself is the org identity",
        { issuerDomain, identifier },
      );
    }
    const nid = `urn:nps:org:${issuerDomain}`;
    if (!ORG_PATTERN.test(nid)) {
      throw new NipError(
        "NIP-NID-FORMAT-INVALID",
        `Constructed org NID '${nid}' fails format validation`,
        { nid },
      );
    }
    return nid;
  }
  if (identifier === undefined || identifier.length === 0) {
    throw new NipError(
      "NIP-NID-FORMAT-INVALID",
      `${entityType} NIDs require a non-empty identifier`,
      { entityType, issuerDomain },
    );
  }
  const nid = `urn:nps:${entityType}:${issuerDomain}:${identifier}`;
  if (!NID_PATTERN.test(nid)) {
    throw new NipError(
      "NIP-NID-FORMAT-INVALID",
      `Constructed NID '${nid}' fails format validation`,
      { nid },
    );
  }
  return nid;
}

export function parseNid(nid: string): ParsedNid {
  const orgMatch = ORG_PATTERN.exec(nid);
  if (orgMatch && orgMatch[1] !== undefined) {
    return { entityType: "org", issuerDomain: orgMatch[1], identifier: "" };
  }
  const match = NID_PATTERN.exec(nid);
  if (!match || match[1] === undefined || match[2] === undefined || match[3] === undefined) {
    throw new NipError(
      "NIP-NID-FORMAT-INVALID",
      `'${nid}' is not a valid NID`,
      { nid },
    );
  }
  return {
    entityType: match[1] as NidEntityType,
    issuerDomain: match[2],
    identifier: match[3],
  };
}

export function isValidNid(nid: string): boolean {
  return NID_PATTERN.test(nid) || ORG_PATTERN.test(nid);
}

export const DEV_ORG_DOMAIN = "dev.localhost";
export const DEV_ORG_NID = `urn:nps:org:${DEV_ORG_DOMAIN}` as const;
