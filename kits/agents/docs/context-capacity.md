# Context Capacity Reporting

Workers self-report their context window usage in every result via the
`context_capacity` field. The orchestrator uses this to decide whether to
queue another task or pause the worker.

## Buckets

| Bucket     | Usage   | Orchestrator action |
|------------|---------|---------------------|
| `fresh`    | < 40%   | Queue freely |
| `half`     | 40–70%  | Queue, but tighten report scope |
| `tight`    | 70–85%  | Finish current task, then pause |
| `imminent` | > 85%   | Save state immediately, do not queue |

## Wire format

`context_capacity` is an optional string field on `NopResultPayload`:

```json
{
  "payload": {
    "status": "completed",
    "context_capacity": "half",
    ...
  }
}
```

Valid values: `"fresh"`, `"half"`, `"tight"`, `"imminent"`.

## How workers estimate

Workers don't have precise context introspection, but can use proxies:

- Message count and estimated token usage across turns
- Tool-call count this session
- Subjective signal: "am I starting to forget earlier context?"

A rough bucket from these signals is better than no signal. False positives
cost one extra memory save; false negatives risk mid-task compaction.

## Type definition

```typescript
export type ContextCapacity = "fresh" | "half" | "tight" | "imminent";
```

Defined in `src/nop-types.ts`, re-exported from `src/types.ts`.

## References

- Issue #56
- `kits/agents/src/nop-types.ts` — `ContextCapacity` type, `NopResultPayload.context_capacity`
- `kits/agents/templates/AGENT-CLAUDE.md` — worker instructions
