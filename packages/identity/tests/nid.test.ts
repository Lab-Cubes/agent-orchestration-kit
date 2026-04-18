import { describe, expect, it } from "vitest";

import {
  DEV_ORG_DOMAIN,
  DEV_ORG_NID,
  NipError,
  buildNid,
  isValidNid,
  parseNid,
} from "../src/index.js";

describe("nid — build", () => {
  it("builds an agent NID", () => {
    expect(buildNid("agent", "ca.innolotus.com", "550e8400")).toBe(
      "urn:nps:agent:ca.innolotus.com:550e8400",
    );
  });

  it("builds a node NID", () => {
    expect(buildNid("node", "api.myapp.com", "products")).toBe(
      "urn:nps:node:api.myapp.com:products",
    );
  });

  it("builds an org NID without identifier", () => {
    expect(buildNid("org", "mycompany.com")).toBe("urn:nps:org:mycompany.com");
  });

  it("rejects org NID with identifier", () => {
    expect(() => buildNid("org", "example.com", "extra")).toThrow(NipError);
  });

  it("rejects agent/node NID without identifier", () => {
    expect(() => buildNid("agent", "example.com")).toThrow(/identifier/);
    expect(() => buildNid("node", "example.com", "")).toThrow(/identifier/);
  });
});

describe("nid — parse", () => {
  it("parses an agent NID", () => {
    expect(parseNid("urn:nps:agent:ca.innolotus.com:550e8400")).toEqual({
      entityType: "agent",
      issuerDomain: "ca.innolotus.com",
      identifier: "550e8400",
    });
  });

  it("parses a node NID", () => {
    expect(parseNid("urn:nps:node:api.myapp.com:products")).toEqual({
      entityType: "node",
      issuerDomain: "api.myapp.com",
      identifier: "products",
    });
  });

  it("parses an org NID", () => {
    expect(parseNid("urn:nps:org:mycompany.com")).toEqual({
      entityType: "org",
      issuerDomain: "mycompany.com",
      identifier: "",
    });
  });

  it("rejects malformed NIDs", () => {
    expect(() => parseNid("urn:nps:robot:x:y")).toThrow(NipError);
    expect(() => parseNid("not-a-urn")).toThrow(NipError);
    expect(() => parseNid("urn:nps:agent")).toThrow(NipError);
  });
});

describe("nid — validation", () => {
  it("accepts well-formed NIDs", () => {
    expect(isValidNid("urn:nps:agent:ca.innolotus.com:550e8400")).toBe(true);
    expect(isValidNid("urn:nps:org:mycompany.com")).toBe(true);
  });

  it("rejects malformed NIDs", () => {
    expect(isValidNid("bogus")).toBe(false);
    expect(isValidNid("urn:nps:robot:x:y")).toBe(false);
  });
});

describe("nid — dev constants", () => {
  it("DEV_ORG_NID equals the constructed form", () => {
    expect(DEV_ORG_NID).toBe(`urn:nps:org:${DEV_ORG_DOMAIN}`);
  });
});
