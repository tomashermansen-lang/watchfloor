---
name: performance-patterns
description: Performance analysis patterns — N+1 queries, caching, pagination, bundle size, scaling bottlenecks. Used by performance-engineer agent.
user-invocable: false
---

# Performance Patterns

## When to Use

- Reviewing code that touches DB queries, API endpoints, or list rendering
- Planning features that handle growing datasets (sessions, events, logs)
- After implementation, before QA sign-off

## Thinking Framework

Before auditing, identify:
1. **Hot paths** — Which endpoints/components are called most frequently?
2. **Data growth** — Which tables/collections grow unboundedly over time?
3. **User-facing latency** — Where does the user wait for a response?

## Backend Checklist

### Database & Queries
- [ ] **N+1 detection:** Loop that issues a query per item → use JOIN or batch fetch
- [ ] **Unbounded queries:** SELECT without LIMIT → add pagination
- [ ] **Missing indexes:** Columns in WHERE/JOIN/ORDER BY without indexes
- [ ] **Large payloads:** API returning full objects when client needs subset → add field selection
- [ ] **Connection pooling:** New connection per request → use pool

### API Design
- [ ] **Pagination:** All list endpoints paginated (cursor or offset)
- [ ] **Filtering server-side:** Client filtering large datasets → move to server
- [ ] **Batch endpoints:** Multiple round-trips for related data → add batch/compound endpoint
- [ ] **Response compression:** Large JSON responses without gzip/brotli
- [ ] **Caching headers:** Static/slow-changing data without Cache-Control/ETag

### Data Volume
- [ ] **Growth projection:** Will this table exceed 100K rows? 1M? Plan indexing strategy
- [ ] **Archival strategy:** Time-series data without retention policy → add TTL or archive
- [ ] **Aggregation:** Computing stats on-the-fly from raw data → pre-aggregate

## Frontend Checklist

### React-Specific
- [ ] **Unnecessary re-renders:** Components re-rendering on unrelated state changes → memo/useMemo
- [ ] **Large lists:** Rendering 100+ items without virtualization → use react-window/virtuoso
- [ ] **Bundle size:** Single bundle >500KB → code split with lazy/Suspense
- [ ] **Image optimization:** Uncompressed images, no lazy loading, no srcset

### Network
- [ ] **Waterfall requests:** Sequential fetches that could be parallel → Promise.all
- [ ] **Polling intervals:** Polling faster than data changes → increase interval or use SSE/websocket
- [ ] **No debounce:** Search/filter triggering API on every keystroke → add debounce (300ms)

## Scaling Bottlenecks

| Pattern | Risk | Mitigation |
|---------|------|-----------|
| Single-threaded processing | CPU-bound work blocks event loop | Worker threads, queue |
| In-memory state | Lost on restart, can't scale horizontally | External store (Redis) |
| Synchronous external calls | Cascading latency | Circuit breaker, timeout |
| Unbounded concurrent connections | Memory exhaustion | Connection limits, backpressure |

## Severity Rules

- Unbounded queries on user-facing endpoints → WARNING minimum
- Missing pagination → WARNING minimum
- Missing rate limits → WARNING minimum
- O(n²) on potentially large datasets → WARNING
- Cosmetic optimizations (shaving ms) → SUGGESTION

## Gotchas

- **Recharts re-renders on every parent state change.** Wrap chart components
  in `React.memo()` and memoize the data array with `useMemo`. A chart that
  looks fine with 10 data points becomes janky with 500.
- **DataGrid loads all rows by default.** For session/event tables that grow
  unboundedly, you must set `paginationMode="server"` — client-side pagination
  still fetches everything into memory first.
- **JSONL file reads scale linearly.** The dashboard reads entire JSONL files
  per request. Fine for hundreds of events, problematic at thousands. Flag any
  endpoint that reads JSONL without a line limit or tail-based approach.
