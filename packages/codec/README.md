# @nps-kit/codec

NPS wire codec — frame builder/parser for the full [NPS (Neural Protocol Suite)](https://github.com/labacacia/NPS-Release) frame range.

Implements the 4-byte fixed-header wire format from **NPS-1 §3.1** with Tier-1 JSON
payload encoding (Flags T0=0, T1=0). Accepts any frame code in the NPS sub-protocol
range per NPS-0 §6 (NCP `0x01-0x0F`, NWP `0x10-0x1F`, NIP `0x20-0x2F`, NDP `0x30-0x3F`,
NOP `0x40-0x4F`) plus the shared ErrorFrame `0xFE`. Sub-protocol semantics (signing,
scope carving, task DAGs) live in sibling packages.

Tier-2 MsgPack, extended header (EXT=1), and application-layer encryption (ENC=1)
are v0.2.0+ and out of scope here.

## Install

```bash
pnpm add @nps-kit/codec
```

## Usage

```ts
import { buildFrame, parseFrame, FrameType } from "@nps-kit/codec";

const bytes = buildFrame(FrameType.CapsFrame, {
  frame: "0x04",
  anchor_ref: "sha256:a3f9b2c1...",
  count: 1,
  data: [{ id: 1001, name: "iPhone 15 Pro", price: 999.0, stock: 42 }],
});

const { type, flags, payload } = parseFrame(bytes);
// type === 0x04
// flags.encodingTier === "tier1-json"
// payload === { frame: "0x04", anchor_ref: ..., count: 1, data: [ ... ] }
```

## Frame types supported

Codec builds and parses any frame in the NPS sub-protocol range `0x01-0x4F` plus
`0xFE`. Advisory TypeScript types ship for NCP and NIP frames; NWP / NDP / NOP
frames parse as opaque `unknown` payloads until their own packages land.

| Code | Name | Spec | Typed? |
|---|---|---|---|
| `0x01` | AnchorFrame | NPS-1 §4.1 | ✅ `AnchorFramePayload` |
| `0x02` | DiffFrame | NPS-1 §4.2 | ✅ `DiffFramePayload` |
| `0x03` | StreamFrame | NPS-1 §4.3 | ✅ `StreamFramePayload` |
| `0x04` | CapsFrame | NPS-1 §4.4 | ✅ `CapsFramePayload` |
| `0x06` | HelloFrame | NPS-1 §4.6 | ✅ `HelloFramePayload` |
| `0x20` | IdentFrame | NPS-3 §5.1 | ✅ `IdentFramePayload` |
| `0x21` | TrustFrame | NPS-3 §5.2 | ✅ `TrustFramePayload` |
| `0x22` | RevokeFrame | NPS-3 §5.3 | ✅ `RevokeFramePayload` |
| `0xFE` | ErrorFrame | NPS-1 §4.7 | ✅ `ErrorFramePayload` |
| other in-range | NWP / NDP / NOP frames | per sub-protocol | ⚠ wire-only |

`0x05` AlignFrame is deprecated (see NPS-1 §4.5) and is not built by this codec.
Received `0x05` frames parse successfully so implementations can handle legacy traffic.

## Out of scope for v0.1.0

- Tier-2 MsgPack encoding (Flags `01`)
- Extended 8-byte header (Flags EXT=1, payloads > 64KB)
- E2E encryption (Flags ENC=1)
- Payload schema validation (codec handles wire format; per-frame field validation
  is the caller's responsibility)

## License

Apache 2.0.
