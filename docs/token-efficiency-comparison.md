# Token Efficiency Comparison: S3 vs DynamoDB vs MCP

## Disclaimer

Token estimates use the approximation: **1 token ≈ 3.5 characters** for JSON/markdown content.
Actual token counts depend on the undocumented tokenizer used by DevOps Agent's foundation model.
AWS does not publish the agent's context window size or per-investigation token budget.

## What Does the Agent Produce?

The relevant data comes from two DevOps Agent API calls:

| Record Type | API Call | Content | Typical Size |
|-------------|----------|---------|-------------|
| `investigation_summary_md` | `list_journal_records` | Full RCA in markdown | 2-9 KB |
| `investigation_summary` | `list_journal_records` | JSON: findings, cascade_graph, symptoms, resources | 0.7-1.5 KB |

**Combined per investigation: 3-10.5 KB (~860-3,000 tokens)**

Measured from actual results:

```
File                          RCA md    Findings   Combined   Tokens
cpu-stress (full)             8,990     1,535      10,525     ~3,007
cpu-stress (typical)          5,524       722       6,246     ~1,785
container-kill                2,212       800       3,012       ~861
```

**Average: ~6,500 chars = ~1,860 tokens per investigation**

Note: FIS metadata, opus scores, and orchestrator fields are excluded —
those are custom data not produced by the DevOps Agent.

## Token Efficiency Comparison

Scenario: Agent needs historical context for 10 past incidents of the same service type.

### Option A: S3 Skill (current approach)

```
ALWAYS LOADED (at investigation start):
  Skill instructions                          ~500 tokens

PER INVESTIGATION:
  ListObjects (experiments/cpu-stress/)        ~300 tokens (response: 10 keys)
  Read file 1 (~6,500 chars)                  ~1,860 tokens
  Read file 2 (~6,500 chars)                  ~1,860 tokens
  Read file 3 (~6,500 chars)                  ~1,860 tokens
  ─────────────────────────────────────────────────────────
  Total for 3 files:                          ~6,380 tokens
  Total for 10 files:                         ~19,400 tokens

  Note: Agent reads ENTIRE file including fields it doesn't need
  (if stored alongside custom data). If stored separately (RCA-only
  files), these numbers apply directly.
```

**Filtering:** None server-side. Agent reads whole file, reasons over everything.

### Option B: DynamoDB (with GSI on service)

```
ALWAYS LOADED:
  Skill instructions                          ~500 tokens

PER INVESTIGATION:
  Query response (10 items × ~200 chars each)  ~570 tokens
  ─────────────────────────────────────────────────────────
  Total:                                      ~1,070 tokens

  Compact records only: {incident_id, root_cause (1-liner), score, date}
  Full RCA NOT in DynamoDB — agent gets pattern signals, not full text
```

**Filtering:** Server-side via GSI. Returns only matching service, sorted by time.

### Option C: MCP Server (Lambda + Function URL)

```
ALWAYS LOADED:
  Tool description in context                  ~100 tokens

PER INVESTIGATION (only if agent decides to call):
  Tool call (service="cpu-stress-svc")         ~30 tokens
  Response (10 compact results)                ~400 tokens
  ─────────────────────────────────────────────────────────
  Total:                                      ~530 tokens

  Server-side: queries DynamoDB or reads S3, filters, returns compact JSON
  Agent sees: [{incident_id, root_cause, score, date}] × 10
```

**Filtering:** Full server-side logic. Can query, filter, rank, truncate.
Called only when agent decides it's relevant.

## Summary Table

| Method | Tokens (10 incidents) | Server-side filtering | Invocation | Infrastructure |
|--------|----------------------|-----------------------|------------|----------------|
| **S3 Skill (full RCA)** | ~19,400 | ❌ None | Always at start | None |
| **S3 Skill (3 files)** | ~6,380 | ❌ None | Always at start | None |
| **DynamoDB Skill** | ~1,070 | ✅ GSI query | Always at start | DynamoDB + GSI |
| **MCP Server** | ~530 | ✅ Full logic | On-demand | Lambda + Function URL |

## Recommendation

| Scale | Best option |
|-------|-------------|
| < 50 total investigations | S3 Skill — simple, ~6K tokens for 3 files is fine |
| 50-500 investigations | DynamoDB Skill — compact records, 5x more efficient |
| 500+ investigations | MCP Server — 37x more efficient than S3, on-demand only |
