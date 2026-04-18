import { CodecError } from "./errors.js";

/**
 * Produce a canonical JSON string representation of a value.
 *
 * **Determinism contract**
 * - Object keys are emitted in lexicographic order (UTF-16 code-unit comparison,
 *   which is what `Array.prototype.sort()` does by default for strings).
 * - Arrays preserve input order; each element is canonicalized recursively.
 * - Primitives are serialized via `JSON.stringify`.
 * - No whitespace is emitted between tokens.
 *
 * **Use case**
 * This utility exists because multiple NPS sub-protocols need byte-exact
 * serialization for signing or hashing:
 *
 * - **NPS-1 §4.1** — AnchorFrame `anchor_id` = SHA-256 over the canonical JSON
 *   of the schema object.
 * - **NPS-3 §5.1** — IdentFrame signature is computed over the canonical JSON
 *   of the frame minus the `signature` field.
 * - **NPS-3 §5.2–5.3** — TrustFrame and RevokeFrame signatures use the same
 *   pattern.
 *
 * Two callers that canonicalize the same logical value with this function will
 * produce identical bytes, regardless of property-insertion order. That property
 * is what makes signatures round-trip across producers and verifiers in the
 * same codec version.
 *
 * **Compliance with RFC 8785 (JCS)**
 *
 * This implementation is RFC 8785–**inspired**, not strictly compliant. It
 * matches the spec's object-key-sort and whitespace rules but defers number
 * serialization to JavaScript's `JSON.stringify`, which differs from the RFC's
 * ECMA-262 §6.1.6.1.20-driven form on edge cases (very large integers near
 * `Number.MAX_SAFE_INTEGER`, fractions with many repeated digits). For the
 * codec's v0.1.0 dev-mode use case — a single process signing and verifying
 * with the same function — this is safe. Cross-SDK interoperability (talking
 * to Ori's TypeScript SDK or other-language NPS implementations) requires
 * upgrading to a full RFC 8785 library; v0.2.0 scope.
 *
 * **Throws**
 * - `CODEC-PAYLOAD-NOT-JSON` for `undefined`, functions, symbols, BigInt,
 *   `NaN`, `Infinity`, or any value that would otherwise silently corrupt the
 *   output under native `JSON.stringify`.
 */
export function canonicalize(value: unknown): string {
  if (value === null) return "null";

  if (typeof value === "boolean") return value ? "true" : "false";

  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      throw new CodecError(
        "CODEC-PAYLOAD-NOT-JSON",
        `Cannot canonicalize non-finite number: ${value}`,
      );
    }
    // JSON.stringify on finite numbers produces the minimal IEEE-754 form,
    // which matches RFC 8785 for all values below MAX_SAFE_INTEGER. Edge
    // cases for very large integers or repeating fractions diverge from RFC
    // 8785 — see the function-level doc.
    return JSON.stringify(value);
  }

  if (typeof value === "string") return JSON.stringify(value);

  if (typeof value === "bigint") {
    throw new CodecError(
      "CODEC-PAYLOAD-NOT-JSON",
      "Cannot canonicalize BigInt — JSON has no native representation",
    );
  }

  if (Array.isArray(value)) {
    const parts = value.map((item) => canonicalize(item));
    return `[${parts.join(",")}]`;
  }

  if (typeof value === "object") {
    // Narrowed by elimination of null above.
    const obj = value as Record<string, unknown>;
    const keys = Object.keys(obj).sort();
    const parts: string[] = [];
    for (const key of keys) {
      const v = obj[key];
      if (v === undefined) {
        // Omit undefined — matches JSON.stringify's own elision and
        // RFC 8785's position that undefined has no JSON form.
        continue;
      }
      parts.push(`${JSON.stringify(key)}:${canonicalize(v)}`);
    }
    return `{${parts.join(",")}}`;
  }

  // undefined / function / symbol
  throw new CodecError(
    "CODEC-PAYLOAD-NOT-JSON",
    `Cannot canonicalize value of type ${typeof value}`,
  );
}

/**
 * Convenience wrapper — canonicalize and encode to UTF-8 bytes, ready for
 * hashing (SHA-256 for anchor_id) or signing (Ed25519 for IdentFrame signature).
 */
export function canonicalizeToBytes(value: unknown): Uint8Array {
  return new TextEncoder().encode(canonicalize(value));
}
