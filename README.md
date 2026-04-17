# nps-kit

Reference implementation and adapter kit for [NPS (Neural Protocol Suite)](https://github.com/labacacia/nps).

**Status:** private, pre-release. Package name `@nps-kit/*` is placeholder pending Lab-Cubes npm scope confirmation.

## Scope of v0.1.0

Four packages per the design-of-record:

| Package | Purpose | v0.1.0 |
|---|---|---|
| `@nps-kit/codec` | NCP frame build/parse | Shipping first |
| `@nps-kit/identity` | NIP IdentFrame loader + DevCA | Deferred |
| `@nps-kit/topology` | Agent graph + discovery | Deferred |
| `@nps-kit/orchestrator` | NOP task executor | Deferred |

## Requirements

- Node.js ≥ 22
- pnpm ≥ 10

## Layout

```
nps-kit/
  packages/
    codec/          # @nps-kit/codec
  LICENSE           # Apache 2.0
  NOTICE
  pnpm-workspace.yaml
```

## License

Apache 2.0 — see [LICENSE](./LICENSE) and [NOTICE](./NOTICE).
