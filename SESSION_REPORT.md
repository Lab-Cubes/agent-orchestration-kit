# nps-kit — Session Report

**Session:** `2026-04-18-001` (autonomous build, pre-approved)
**Operator:** Teddy
**Agent:** Sage (Claude Opus 4.7)
**Date:** 2026-04-18
**Status:** ✅ Codec shipped. Clean working tree. Ready for review.

---

## What shipped

### Repo scaffold

- Local git repo at `/Users/clover/.openclaw/nps-kit-scaffold/` (main branch, no remote — remote deferred pending Lab-Cubes repo permission).
- Apache 2.0 LICENSE + NOTICE at the root. Copyright attributed to Lab-Cubes.
- pnpm workspace (`pnpm-workspace.yaml`) with `packages/*` glob.
- Root `package.json` declaring `engines.node: ">=22"` and `packageManager: "pnpm@10.33.0"`.
- Shared `tsconfig.base.json` with strict mode (`noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`, etc.).
- `.gitignore` for `node_modules`, `dist`, `coverage`, `.turbo`, `.DS_Store`.
- `prepare-commit-msg` hook copied from workspace so Sage + Opus trailers land from day one.

### `@nps-kit/codec@0.1.0`

Spec-derived, dependency-free Tier-1 JSON NCP frame codec.

**Modules (`packages/codec/src/`):**

| File | Purpose |
|---|---|
| `errors.ts` | `CodecError` class with stable `NcpErrorCode` union |
| `flags.ts` | Flags byte encode/decode per NPS-1 §3.2 (T0/T1/FINAL/ENC/RSV/EXT) |
| `header.ts` | 4-byte fixed header encode/decode per NPS-1 §3.1 (big-endian) |
| `frame-types.ts` | `FrameType` const map + NCP range / ErrorFrame routing helpers |
| `payloads.ts` | Advisory TypeScript types for all six built frame shapes |
| `codec.ts` | `buildFrame` / `parseFrame` public API |
| `index.ts` | Public surface — types + functions + constants |

**Frame types covered:**

- **Built + parsed:** AnchorFrame (0x01), DiffFrame (0x02), StreamFrame (0x03), CapsFrame (0x04), HelloFrame (0x06), ErrorFrame (0xFE).
- **Parsed only (legacy receive):** AlignFrame (0x05) — deprecated per NPS-1 §4.5, `buildFrame` rejects it; `parseFrame` accepts it for receive-side compatibility with older peers.
- **Rejected:** anything outside `0x01-0x0F` or the shared `0xFE` — throws `NCP-FRAME-UNKNOWN-TYPE`.

**Build:** tsup emits ESM + CJS + `.d.ts` + `.d.cts`. Output sizes ~9 KB per format.

**Tests:** 35 passing across `flags.test.ts` (5), `header.test.ts` (8), `codec.test.ts` (22). Covers round-trips for every supported frame type, build-side rejections (unknown type, deprecated AlignFrame, tier-2, ENC=1, EXT=1, oversize payload, non-JSON payload), and parse-side rejections (out-of-range type, truncated, tier-2, ENC=1, non-UTF-8, non-JSON, legacy AlignFrame allowed).

**Gates:**

- `pnpm typecheck` — clean
- `pnpm test` — 35/35 pass
- `pnpm build` — ESM + CJS + DTS emitted

---

## Decisions made during the build

### SDK dependency — path (b) selected

Per active-session guardrails, went with **path (b): spec-derived types, no SDK dep**. The codec defines its own `FrameType` map, flag layout, and payload type interfaces directly from NPS-1 spec sections. No `file:` link to `@labacacia/nps-sdk-ts`, no `@labacacia/*` imports.

**Why (recorded for identity/topology/orchestrator modules to revisit):**

- Codec's surface is spec-defined and small (6 frame types, one header format, one flags byte). Duplicating spec types is cheaper than managing a private file-link during active SDK development.
- Keeps the package install-free for external reviewers who want to inspect the code without touching a private clone.
- Identity/orchestrator modules may want different trade-offs (their types are larger and more closely tied to SDK internals like CA client behaviour). Revisit per-module.

### Uint8Array, not Buffer

Architect notes say "`buildFrame(type, payload) → Buffer`". Implementation returns `Uint8Array` for runtime portability (Deno, browsers, edge workers). Node's `Buffer` is a `Uint8Array` subclass, so `Buffer.from(result)` works if a caller specifically needs Buffer semantics. Typings stay portable.

### Legacy AlignFrame (0x05): reject build, accept parse

NPS-1 §4.5 marks AlignFrame deprecated and slated for removal in v1.0. `buildFrame` refuses to emit one (`NCP-FRAME-UNKNOWN-TYPE` with the reason in the message). `parseFrame` accepts it so that v0.1.0 adopters can interop with peers that still send legacy frames. Matches the spec's "accept legacy, don't propagate" posture.

### Extended header (EXT=1) and encryption (ENC=1) — both deferred

Architect notes scope v0.1.0 to Tier-1 JSON with the 4-byte fixed header. EXT=1 and ENC=1 are spec-defined but v0.2.0+ concerns. Both are **explicitly rejected** at build and parse time with `NCP-FRAME-FLAGS-INVALID` — not silently accepted-then-misparsed. Guards against an adopter wiring up a production stream that "looks like it works" against the dev codec.

### Payload size cap is spec-strict

Single-frame payloads > 64 KiB throw `NCP-FRAME-PAYLOAD-TOO-LARGE` with a pointer to StreamFrame (NPS-1 §3.3) rather than silently switching to the extended header. Forces the caller to make an explicit sizing decision.

### Commit attribution

Workspace `prepare-commit-msg` hook was copied into `nps-kit-scaffold/.git/hooks/` at init. Every commit in the scaffold carries `Author: Teddy` + `Co-Authored-By: Sage` + `Co-Authored-By: Claude Opus 4.7 (1M context)` trailers, identical to the workspace.

---

## Out of scope — as agreed

Not touched (stop at codec boundary):

- `@nps-kit/identity`
- `@nps-kit/topology`
- `@nps-kit/orchestrator`
- Reference example topologies (hierarchical-with-peer, pure peer swarm, pure hierarchy)
- DevCA CLI
- CONFORMANCE.md
- Benchmark mode

---

## Open questions for Teddy

1. **Package scope (`@nps-kit/*`).** Placeholder pending Ori's sign-off on the `nps-kit` name and Lab-Cubes npm scope availability. README and all `package.json` files use `@nps-kit/*`. Rename is a find-and-replace across 3 files if the scope lands differently.

2. **Repo migration.** Local-only git repo for now. When Lab-Cubes permission lands, push history to `Lab-Cubes/nps-kit` with `git push -u origin main` — commits will carry attribution and atomic structure from day one. Do you want me to wait for your go-ahead before pushing, or push as soon as the remote exists?

3. **Tier-2 MsgPack.** Architect notes explicitly defer to v0.2.0. The codec currently rejects tier-2 frames on both sides. Next-up work will mean adding a peer dependency (likely `@msgpack/msgpack`) and a second encode/decode path. Not urgent but worth flagging the first external dep the codec will need.

4. **`inline_anchor` semantics.** `CapsFramePayload` types `inline_anchor?: AnchorFramePayload`. The codec does not crack open `CapsFrame.data[].inline_anchor` to validate the nested `anchor_id` (which NPS-1 §9 says the Agent MUST verify). That belongs to a higher-layer schema validator. Flagging because an adopter might expect the codec to do this. Should this be called out in the README more loudly?

---

## Cost

No external API calls beyond QMD (local). Build + test + typecheck ran locally. Well under the $10 budget cap.

---

## Next session

When you're ready: move to `@nps-kit/identity` per architect Q3 executor notes (Ed25519 keypair, DevIdentityProvider, CaIdentityProvider, DevCA CLI). Or iterate on codec based on your review — happy to adjust the AlignFrame posture, the legacy-receive decision, or the error codes if they're wrong.
