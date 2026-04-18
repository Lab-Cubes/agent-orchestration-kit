# @nps-kit/identity

NIP (Neural Identity Protocol) implementation for [NPS](https://github.com/labacacia/nps), per **NPS-3 v0.2**.

v0.1.0 ships **dev mode only** — a per-process self-contained CA that issues
signed `IdentFrame`s to agents. Verification, production-mode CA integration,
auto-renewal, and the `DevCA` CLI are deferred to subsequent versions.

## Status matrix

| Feature | v0.1.0 | Planned |
|---|---|---|
| Ed25519 keypair generation | ✅ | — |
| NID construction + parsing | ✅ | — |
| Dev-mode CA (`DevCA` class) | ✅ | — |
| IdentFrame issuance (signed) | ✅ | — |
| TrustFrame issuance | 🔸 | v0.2.0 |
| RevokeFrame issuance | 🔸 | v0.2.0 |
| `verifyIdentFrame()` (NPS-3 §7 six-step flow) | 🔸 | v0.1.1 |
| Production-mode CA client (NPS-3 §8) | 🔸 | v0.2.0 |
| Auto-renewal (7-day window per NPS-3 §6) | 🔸 | v0.2.0 |
| `DevCA` CLI (`nps-kit ca init`, etc.) | 🔸 | v0.2.0 |

## Install

```bash
pnpm add @nps-kit/identity @nps-kit/codec
```

## Usage

```ts
import { DevCA, DevIdentityProvider, loadIdentity } from "@nps-kit/identity";

// Simplest path — loadIdentity creates a per-process DevCA and provider.
const identity = loadIdentity({ mode: "dev", agentId: "worker-01" });

identity.identFrame;
// {
//   frame: "0x20",
//   nid: "urn:nps:agent:dev:localhost:worker-01",
//   pub_key: "ed25519:MCowBQYDK2VwAyEA...",
//   capabilities: ["nop:delegate"],
//   scope: { nodes: ["nwp://*"], actions: [], max_token_budget: 10000 },
//   issued_by: "urn:nps:org:dev:localhost",
//   issued_at: "...",
//   expires_at: "...",
//   serial: "0x0001",
//   signature: "ed25519:..."
// }

// Sign downstream messages with the agent's private key.
const sig = identity.sign(new TextEncoder().encode("some message"));

// Explicit form — share a DevCA across multiple agents in the same process.
const ca = new DevCA();
const a = new DevIdentityProvider(ca, { agentId: "a" });
const b = new DevIdentityProvider(ca, { agentId: "b" });
// Both IdentFrames are signed by the same CA; a peer verifier configured to
// trust `urn:nps:org:dev:localhost` accepts both.
```

## What dev mode is NOT

- **Not for production.** Dev mode emits a loud startup warning and uses a
  CA keypair that is regenerated per process. Anything signed by dev mode
  MUST NOT cross a trust boundary.
- **Not cross-machine.** Dev mode assumes agents and verifier share the same
  process memory (the DevCA instance). Multi-process dev requires the v0.2.0
  `DevCA` CLI + keypair persistence.
- **Not interop-complete with other NPS SDKs.** The codec's `canonicalize()`
  is RFC 8785–inspired but not strictly compliant; signatures produced by
  dev mode are byte-stable within this kit but may not verify under Ori's
  TypeScript SDK until v0.2.0 upgrades to a full JCS implementation.

## License

Apache 2.0.
