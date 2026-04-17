# @nps-kit/codec — NPS-1 (NCP) Conformance Matrix

Spec target: **NPS-1 v0.4** (dated 2026-04-14, per local clone at `labacacia/nps`).
Package version: **@nps-kit/codec@0.1.0**.

This document maps every NCP spec clause to the codec's v0.1.0 coverage. Use it to
decide whether this codec is safe for your use case.

| Status | Meaning |
|---|---|
| ✅ **Covered** | Spec clause implemented and tested |
| ⚠ **Partial** | Wire format covered; semantic enforcement belongs to a higher layer |
| 🔸 **Deferred** | Out of v0.1.0 scope; planned for v0.2.0 or later |
| ➖ **N/A** | Outside codec responsibility (runtime, transport, or caching concern) |

---

## §2 Protocol Overview

| Clause | Requirement | Status | Notes |
|---|---|---|---|
| §2.1 | Sender / Receiver / Relay roles | ➖ N/A | Runtime roles; codec is role-neutral |
| §2.2 | HTTP mode vs native mode | ➖ N/A | Codec produces wire bytes; transport is separate |
| §2.3 | Unified port 17433, frame-type routing ranges | ✅ | `isNcpRangeOrError` gates 0x01–0x0F + 0xFE |
| §2.4 | Frame exchange patterns (req/resp, stream, etc.) | ➖ N/A | Exchange choreography is a runtime concern |
| §2.5 | Connection state machine | ➖ N/A | Transport-layer concern |
| §2.6 | Native handshake sequence + version negotiation | ⚠ Partial | HelloFrame / CapsFrame **build + parse** covered; 5-second timeout and `min(version)` selection belong to the transport layer |

## §3 Frame Format

| Clause | Requirement | Status | Notes |
|---|---|---|---|
| §3.1 | **4-byte fixed header** — 1B type, 1B flags, 2B length (big-endian) | ✅ | [`encodeFixedHeader`](src/header.ts) / [`decodeFixedHeader`](src/header.ts) + 3 tests including BE correctness and max-65535 boundary |
| §3.1 | **8-byte extended header** when EXT=1 | 🔸 Deferred | Rejected on both sides with `NCP-FRAME-FLAGS-INVALID`. v0.2.0 when payloads > 64 KiB are needed |
| §3.2 | Flags byte layout (T0/T1/FINAL/ENC/RSV/EXT) | ✅ | [`encodeFlags`](src/flags.ts) / [`decodeFlags`](src/flags.ts); RSV bits rejected at decode |
| §3.2 | RSV bits 4–6 **MUST** be zero; receiver **MUST** ignore | ✅ | Throws `NCP-FRAME-FLAGS-INVALID` rather than silently ignoring — stricter than spec, safer default |
| §3.3 | `max_frame_payload` default 65,535 | ✅ | `MAX_FIXED_PAYLOAD = 0xFFFF` enforced at build |
| §3.3 | Payload > limit **MUST** use StreamFrame fragmentation | ⚠ Partial | Codec throws `NCP-FRAME-PAYLOAD-TOO-LARGE` with a pointer to StreamFrame; fragmentation decision is the caller's |

## §4 Frame Types

| Code | Frame | Status | Notes |
|---|---|---|---|
| **0x01** | AnchorFrame | ⚠ Partial | Build + parse of the frame shape covered. **`anchor_id` JCS+SHA-256 computation is NOT in scope** — belongs to a separate `@nps-kit/anchor-id` helper (or can live in identity/topology). Callers MUST compute `anchor_id` per §4.1 (RFC 8785 JCS over `schema`, then SHA-256) before passing into `buildFrame` |
| **0x02** | DiffFrame | ✅ with caveat | `patch_format: "json_patch"` round-trips cleanly. `patch_format: "binary_bitset"` requires Tier-2 MsgPack and is therefore 🔸 deferred |
| **0x03** | StreamFrame | ⚠ Partial | Build + parse covered, including `window_size` and `error_code` fields. Flow-control **semantics** (window depletion, reverse-direction window updates, `NCP-STREAM-WINDOW-OVERFLOW`) are a runtime concern — codec only wires the bytes |
| **0x04** | CapsFrame | ⚠ Partial | Build + parse covered (`anchor_ref`, `count`, `data`, `next_cursor`, `token_est`, `cached`, `inline_anchor`). The invariant `count === data.length` is the caller's responsibility; codec does not enforce. `inline_anchor` nested-verify (§5.4.1) is also caller's job |
| **0x05** | AlignFrame (deprecated per §4.5) | ✅ | `buildFrame` rejects with `NCP-FRAME-UNKNOWN-TYPE` and points to NOP AlignStream (0x43). `parseFrame` accepts for receive-side compatibility with legacy peers |
| **0x06** | HelloFrame | ✅ | Build + parse covered including `nps_version`, `min_version`, `supported_encodings`, `supported_protocols`, `agent_id`, `max_frame_payload`, `ext_support`, `max_concurrent_streams`, `e2e_enc_algorithms`. First-frame ordering (§4.6) is a transport concern |
| **0xFE** | ErrorFrame | ✅ | Build + parse covered |

## §5 Schema Anchoring

| Clause | Requirement | Status | Notes |
|---|---|---|---|
| §5.1 | AnchorFrame published by Node; Agent reads + caches | ➖ N/A | Caching is a runtime concern, not codec |
| §5.2 | Standard flow (GET /.nwm → /.schema → QueryFrame) | ➖ N/A | HTTP endpoint contracts, not codec |
| §5.3 | Cache semantics (key=`anchor_id`, TTL from frame) | ➖ N/A | Cache lives in a higher layer |
| §5.4 | Cache-miss handling (`inline_anchor`, `NCP-ANCHOR-STALE`, `NCP-ANCHOR-NOT-FOUND`) | ⚠ Partial | Codec passes `inline_anchor` through the wire round-trip. Cache update logic + stale detection are not codec's job |

## §6 Error Codes

NPS-1 §6 defines 14 `NCP-*` error codes. This codec surfaces a subset matching the problems it can detect at the wire layer; the rest are runtime / higher-layer signals.

| Spec error code | Surfaced by codec | Our code |
|---|---|---|
| `NCP-FRAME-UNKNOWN-TYPE` | ✅ | `NCP-FRAME-UNKNOWN-TYPE` (identical) |
| `NCP-FRAME-PAYLOAD-TOO-LARGE` | ✅ | `NCP-FRAME-PAYLOAD-TOO-LARGE` (identical) |
| `NCP-FRAME-FLAGS-INVALID` | ✅ | `NCP-FRAME-FLAGS-INVALID` (identical) |
| `NCP-ENCODING-UNSUPPORTED` | ✅ | `NCP-ENCODING-UNSUPPORTED` (identical) |
| `NCP-ANCHOR-NOT-FOUND` | ➖ N/A | Cache-layer signal |
| `NCP-ANCHOR-SCHEMA-INVALID` | ➖ N/A | Schema-validator signal |
| `NCP-ANCHOR-ID-MISMATCH` | ➖ N/A | Anchor-integrity signal (caller) |
| `NCP-ANCHOR-STALE` | ➖ N/A | Cache-layer signal |
| `NCP-STREAM-SEQ-GAP` | ➖ N/A | Stream-runtime signal |
| `NCP-STREAM-NOT-FOUND` | ➖ N/A | Stream-runtime signal |
| `NCP-STREAM-LIMIT-EXCEEDED` | ➖ N/A | Connection-runtime signal |
| `NCP-STREAM-WINDOW-OVERFLOW` | ➖ N/A | Flow-control runtime signal |
| `NCP-DIFF-FORMAT-UNSUPPORTED` | ➖ N/A | Capability-negotiation signal |
| `NCP-VERSION-INCOMPATIBLE` | ➖ N/A | Handshake-layer signal |
| `NCP-ENC-NOT-NEGOTIATED` | ➖ N/A | E2E-encryption layer |
| `NCP-ENC-AUTH-FAILED` | ➖ N/A | E2E-encryption layer |

Codec-only additions (not in spec, used for local diagnostic precision). These
use the `CODEC-*` prefix to keep the `NCP-*` namespace clean of non-spec codes:

- `CODEC-FRAME-TRUNCATED` — input buffer ended before the declared payload length
- `CODEC-PAYLOAD-NOT-JSON` — payload bytes failed UTF-8 decode, JSON parse, or JSON stringify on the build side

## §7 Security Considerations

| Clause | Requirement | Status | Notes |
|---|---|---|---|
| §7.1 | Replay defence via TLS or `nonce` | ➖ N/A | Transport / application concern |
| §7.2 | Anchor poisoning defence (same `anchor_id` → same schema) | ➖ N/A | Cache-layer integrity check |
| §7.3 | Stream flooding (`max_concurrent_streams`) | ➖ N/A | Connection-layer concern |
| §7.4 | E2E encryption (ENC=1, AES-256-GCM / ChaCha20-Poly1305) | 🔸 Deferred | Codec rejects ENC=1 on both sides. v0.2.0+ feature |

## §8 Encoding Tiers

| Tier | Flags T1T0 | Format | Status |
|---|---|---|---|
| Tier-1 | `00` | JSON | ✅ Covered — the exclusive v0.1.0 codec mode |
| Tier-2 | `01` | MsgPack | 🔸 Deferred — v0.2.0, brings first runtime dep (`@msgpack/msgpack`) |
| Reserved | `10` / `11` | — | ➖ Reserved in spec; codec rejects via tier round-trip |

## §9 Implementation Notes

Applicable items and our posture:

- **AnchorFrame LRU cache** (1000/connection) — ➖ N/A (runtime).
- **MsgPack library use** — 🔸 Deferred.
- **StreamFrame seq overflow** — ➖ N/A (stream-runtime responsibility; codec handles up to `uint32` in the wire field).
- **EXT support advertisement via CapsFrame** — ⚠ Partial (codec builds CapsFrame with `ext_support` field; advertising during negotiation is a transport concern).
- **`anchor_id` via RFC 8785 JCS standard library** — ⚠ Partial (codec passes `anchor_id` through; computation is deferred to a future `@nps-kit/anchor-id` helper per §4.1 note above).
- **HelloFrame 5-second timeout** — ➖ N/A (transport).
- **DiffFrame binary_bitset Tier-2-only** — 🔸 Deferred.
- **E2E encryption Nonce** — 🔸 Deferred.
- **`inline_anchor` anchor_id verification** — ⚠ Partial (caller's responsibility; codec parses the shape).

---

## Summary

**What v0.1.0 guarantees:**

- Wire-format correctness for NCP frames 0x01–0x04, 0x06, 0xFE — you can trust the bytes on disk or on the wire to match NPS-1 §3.1.
- Strict rejection (not silent pass-through) of EXT=1, ENC=1, Tier-2, RSV-non-zero, and out-of-range frame types. A codec that "looks like it works" against Tier-2 traffic is dangerous; this codec fails loudly instead.
- Error codes aligned with NPS-1 §6 where codec-surfaceable; local diagnostic codes clearly namespaced (`CODEC-FRAME-TRUNCATED`, `CODEC-PAYLOAD-NOT-JSON`).
- Typed payload interfaces for every built frame, derived directly from §4 field tables.

**What v0.1.0 does NOT guarantee:**

- `anchor_id` correctness — caller's job (RFC 8785 JCS + SHA-256).
- `count === data.length` for CapsFrame — caller's job.
- StreamFrame flow control, seq monotonicity, `stream_id` uniqueness — runtime's job.
- Anchor cache integrity (poisoning defence per §7.2) — cache layer's job.
- Schema anchor liveness / TTL / cache-miss handling — cache layer's job.
- Transport-layer concerns (HTTP vs native, handshake ordering, TLS, 5s timeouts) — transport's job.

**When a higher NPS layer (identity / topology / orchestrator) is built on this codec, it MUST layer these semantic checks on top.** The codec is intentionally a thin wire codec, not a full protocol stack.
