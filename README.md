# Postgres Workload Lab

This repository is a reference exploring how different workload patterns (OLTP, time-series, vector, document) shape PostgreSQL design, from indexing strategies, and schema trade-offs to architectural boundaries between specialised workloads.

## Context / Philosophy 

Postgres is a transactional database engine that can be easily extended (through extensions and indexing strategies).
Its extensibility makes it powerful as it enables support for multi-workload patterns.

> PostgreSQL behaves less like a single-purpose database and more like a multi-workload data platform, where the dominant access pattern defines the optimal design.

The instinct to reach for a specialised system (e.g. Elasticsearch for search, Redis for caching, InfluxDB for time-series) is often premature. PostgreSQL's extensibility makes it capable of handling most of these workloads natively (at the cost of intentional design choices around indexing, schema layout, and query planning).

## Workload Specializations (not "different databases")

Instead of introducing multiple systems prematurely, many workloads can be handled by specializing PostgreSQL per access pattern:

| Workload                      | Optimization Strategy                                                           |
| ----------------------------- | ------------------------------------------------------------------------------- |
| **Relational (OLTP)**         | B-tree indexes → exact lookup and range queries                                 |
| **Time-series (TimescaleDB)** | Time partitioning (hypertables) + continuous aggregates                         |
| **Vector (pgvector)**         | Nearest-neighbour search (exact or approximate via ANN)                         |
| **Document (JSONB + GIN)**    | Inverted index for containment queries                                          |
| **Text search**               | `tsvector` + GIN / `pg_trgm` for similarity matching and misspellings tolerance |

These are not separate databases, but different access patterns running on the same engine. Each demanding a different index structure and schema contract.

# Index Fundamentals

## B-tree (Default Index)

A B-tree is a balanced tree structure, enabling binary searches and optimized for equality.  
It is optimized for scalar comparisons (`=`, `<`, `>`, `BETWEEN`, `ORDER BY`) e.g. in use-cases dominated by `WHERE column = value` scenarii, where a row is mapped to a value.  
Handy in contexts where the workflow is write-heavy.

## GIN (Generalized Inverted Index)

GIN is fundamentally different from a B-tree.
It is optimized for `WHERE value CONTAINS element` where an element is mapped to a _list of rows_.  
Typically, GIN is used when a single column contains **multiple searchable elements** such as:
* `jsonb` (key-value containment)
* arrays (membership queries)
* full-text search (`tsvector`)

Example:
```json
{ "country": "DE", "status": "active", "tags": ["vip", "beta"] }
```

GIN enables the following query patterns:
```sql
-- JSON containment
WHERE data @> '{"country": "DE"}'

-- Array membership
WHERE tags @> ARRAY['vip']

-- Full-text search
WHERE document @@ to_tsquery('postgres')
```

**Note on types:**
* `jsonb`: Binary JSON, which is a PostgresSQL data type that stores JSON data in a decomposed binary format. Optimized for querying, indexing and performance at the cost of slower insertions.
* `jsonl`: JSON lines, which is a file format (`.jsonl`) and not a PostgreSQL type, where each line is a valid, independent JSON object, separated by a newline character (`\n`) designed primarily for streaming data, logging and processing larger datasets line-by-line (see [CDC Data Platform Reference](https://github.com/olivierbenard/cdc-data-platform-reference)).

In practice:
```sql
CREATE TABLE test_json (
	id BIGSERIAL PRIMARY KEY,
	content JSONB
);

INSERT INTO test_json (id, content)
VALUES
	(1, '{ "country": "DE", "status": "active", "tags": ["vip", "beta"] }'),
	(2, '{ "country": "FR", "status": "active", "tags": ["vip", "beta"] }');

SELECT *
FROM test_json
WHERE content @> '{"country": "FR"}';

-- Optional: GIN index to make @> fast at scale
CREATE INDEX idx_test_json_content ON test_json USING GIN (content);
```

## GIN Trade-offs at Scale

GIN is not better than B-tree, but different.  

If it effectively brings efficient multi-element search and enables document-style querying without leaving SQL, it comes at the cost of:
- higher write overhead (index maintenance)
- larger index size
- slower updates

It solves a different problem than B-tree, with a different cost profile.

## Hybrid-Schema Pattern (Flattening to Prevent Index Bloat)

Storing data in JSONB and indexing it with GIN means every nested key-value pair is indexed, including the fields that are never queried.  
At scale, unused keys inflate the posting lists (index bloat), leading to slow updates (changing one JSONB column will cascade invalidations across many posting list entries) and write amplifications (upserts rewrite more index pages than a B-tree equivalent would).  

The mitigation is to **promote frequently-filtered, high-cardinality fields out of JSONB into typed relational columns**, indexed with B-tree:
```sql
-- Avoid: GIN scan across entire JSONB payload
WHERE payload->>'user_id' = '123' AND payload->>'status' = 'active'

-- Preferred: B-tree on promoted columns
WHERE user_id = 123 AND status = 'active'
-- Composite B-tree index: CREATE INDEX ON events(user_id, status)
```

The main idea here is to preserve JSON columns for the rarely-queried fields, while hot paths get proper relational columns. This hybrid contract gives:
- fast filtering via typed columns + B-tree
- flexible attributes via JSONB
- containment search via GIN on the remainder

## "Hot Filters" - Selectivity-First Query Design

A **hot filter** is a predicate used frequently and early in query execution, e.g.:
```sql
WHERE tenant_id = 'X'
```

Referred as _"hot filters"_ in the context of vector/hybrid search, they are part of pre-filter or selectivity-first strategies. The key principle never changes:

> Promote high-selectivity filter fields early in query execution to reduce the candidate set before the expensive operation (e.g. full-text search, vector ANN, JSONB containment) runs.

In other words: B-tree prunes the working set before GIN, then vector ANN or full-text search operates on the remainder.

Concretely, this translates in PostgresSQL into:
```sql
-- Unoptimised: GIN scans the full table, result filtered after
WHERE payload @> '{"type": "invoice"}' AND created_at > now() - interval '7 days'

-- Optimised: B-tree on created_at prunes first, GIN works on the remainder
-- Requires: B-tree index on created_at, GIN index on payload
-- Planner picks created_at first when it is more selective
```

The query planner uses selectivity estimates derived from table statistics. The plan can be influenced explicitly:
```sql
-- 1. Composite B-tree index: put the most selective column first
CREATE INDEX ON events(tenant_id, created_at);

-- 2. Partial index: pre-filter at index definition time
CREATE INDEX ON events(user_id) WHERE status = 'active';

-- 3. Expression index: extract a JSONB key into an indexed expression
CREATE INDEX ON events((payload->>'tenant_id'));
```

Hot filters are most impactful when the filtered column has high cardinality and the expensive downstream operation (GIN containment, vector search, full-text scan) is non-trivial. Keeping hot filters as **typed columns + B-tree indexes** compared as burying them inside JSON is a strong structural guarantee (and not just an optimisation afterthought).  

When correctly implemented, you end-up with:
* fast filtering via relational columns
* flexible attributes accessible via JSONB
* secondary access path with GIN

## Fuzzy Matching - `pg_trgm`

`pg_trgm` breaks strings into trigrams (overlapping 3-character sequences) and indexes them for fast similarity and pattern matching:
```sql
"HRS" → " H", "HR", "RS", "S "
```

This enables:
- similarity threshold queries (`%` operator)
- `LIKE`/`ILIKE` acceleration with a GIN or GiST index
- Word similarity (`<%`, `%>`) for substring-level matching

```sql
-- Enable once per database
CREATE EXTENSION IF NOT EXISTS pg_trgm;
-- SELECT * FROM pg_available_extensions WHERE name = 'pg_trgm';

-- Fuzzy candidate retrieval
SELECT
  id,
  name,
  similarity(name, 'HRS') AS score
FROM entities
WHERE name % 'HRS' -- trigram similarity gate
ORDER BY score DESC
LIMIT 20;
```

### Limitations for Identity Matching

`pg_trgm` is lexical, meaning it operates on character patterns without token boundary awareness (e.g. "HRS" as a standalone token, i.e. not inside a word), entity type awareness or semantic meaning (e.g. "HRS" refers to a German company). On short strings like "HRS", trigrams are low-entropy and appear in many words ("HOURS", "THRESH"), producing aggressive false positives.

Although not good as final classifier, `pg_trgm` is good as a first-pass candidate generator (maximising recall). Precision would requires layered refinement:
```sql
-- Layer 1: pg_trgm fuzzy gate (recall)
WHERE name % 'HRS'

-- Layer 2: word boundary enforcement via regex (token isolation)
WHERE content ~ '\mHRS\M'

-- Layer 3: tsvector for token-aware full-text (boundary + stemming)
WHERE to_tsvector('english', body) @@ to_tsquery('HRS')

-- Layer 4: entity type pre-filter (hot filter — relational column)
WHERE entity_type = 'company' AND name % 'HRS'
```

For short strings specifically, **Levenshtein distance** (via `fuzzystrmatch`) is often more meaningful than trigram similarity for short strings like "HRS" as it counts the minimum edits needed (e.g. HRS → HR5 = distance 1, which is a stronger signal than a raw similarity score).

```sql
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;

SELECT levenshtein('HRS', 'HR5');   -- 1 (strong candidate)
SELECT levenshtein('HRS', 'HOURS'); -- 3 (weak candidate)
```

# Local Setup

The `docker-compose.yml` provisions two containers, intentionally separated despite PostgreSQL being capable of handling both workloads in a single instance:
| container    | workload                  | port |
| ------------ | ------------------------- | ---- |
| `pg_app`     | relational / OLTP         | 5432 |
| `pg_metrics` | time-series / TimescaleDB | 5432 |


Separation makes trade-offs explicit, isolates performance characteristics, simplifies per-instance tuning and reduces blast radius during incidents.

## Configuration

Each service/instance is configured via:
- environment variables defined within the `docker-compose.yml` file:
  - `POSTGRES_PASSWORD`
  - `POSTGRES_USER`
  - `POSTGRES_DB`
- initialization scripts:
  - `*.sql` and `*.sh` files in `/docker-entrypoint-initdb.d`

This ensures reproducible and idempotent environments.

## Commands

```bash
make up   # provision and start all containers / workload specialisations 
make ps   # verify running state
make down # tear down
```

## Connections

You can check manually, e.g.:
```bash
# direct psql
docker exec -it pg_app psql -U app_user -d app_db -c "select * from orders where 1 = 0;"
```

Or via DBeaver / any JDBC client:
- `jdbc:postgresql://localhost:5432/app_db`
- `jdbc:postgresql://localhost:5433/metrics_db`

# Workload Walkthroughs / Data Exploration

## Relational Workflow (OLTP)

```sql
-- select * from orders;
-- select * from customers;
select * from mart_revenue_daily;
```

|revenue_date|total_orders|paid_orders|refunded_orders|gross_revenue_cents|refunded_amount_cents|net_revenue_cents|
|------------|------------|-----------|---------------|-------------------|---------------------|-----------------|
|2026-04-20|3|2|1|6.998|2.599|4.399|

## TimeSeries Workflow (TimescaleDB)

```sql
select * from cpu_metrics;
```

|ts|host|cpu_percent|
|--|----|-----------|
|2026-04-20 14:30:07.291 +0200|host-a|41.2|
|2026-04-20 14:50:07.291 +0200|host-a|53.8|
|2026-04-20 15:50:07.291 +0200|host-a|72.1|
|2026-04-20 15:55:07.291 +0200|host-a|65.4|

```sql
select * from cpu_metrics_hourly;
```

|bucket|host|avg_cpu|min_cpu|max_cpu|
|------|----|-------|-------|-------|
|2026-04-20 14:00:00.000 +0200|host-a|47.5|41.2|53.8|
|2026-04-20 15:00:00.000 +0200|host-a|68.75|65.4|72.1|

`cpu_metrics_hourly` is a continuous aggregate i.e. a materialised view with incremental refresh semantics managed by TimescaleDB. Unlike a standard table, ownership of the refresh lifecycle is delegated to the engine (by opposition, with a table, you control when and how a table is updated e.g. incremental, merge, overwrite).

If later the `cpu_metrics` table gets updated:
```sql
INSERT INTO cpu_metrics (ts, host, cpu_percent)
VALUES (now() - interval '1 minutes',  'host-a', 68.3);
```

```sql
select * from cpu_metrics;
```

|ts|host|cpu_percent|
|--|----|-----------|
|2026-04-20 14:30:07.291 +0200|host-a|41.2|
|2026-04-20 14:50:07.291 +0200|host-a|53.8|
|2026-04-20 15:50:07.291 +0200|host-a|72.1|
|2026-04-20 15:55:07.291 +0200|host-a|65.4|
|2026-04-20 16:00:08.062 +0200|host-a|68.3|

You can force a full refresh manually:

```sql
CALL refresh_continuous_aggregate(
  'cpu_metrics_hourly',
  NULL,
  NULL
);
```

Or, using a bounded window (making cost more predictable):
```sql
CALL refresh_continuous_aggregate(
  'cpu_metrics_hourly',
  now() - interval '7 days,
  now()
);
```

```sql
select * from cpu_metrics_hourly;
```

|bucket|host|avg_cpu|min_cpu|max_cpu|
|------|----|-------|-------|-------|
|2026-04-20 14:00:00.000 +0200|host-a|47.5|41.2|53.8|
|2026-04-20 15:00:00.000 +0200|host-a|68.75|65.4|72.1|
|2026-04-20 16:00:00.000 +0200|host-a|68.3|68.3|68.3|

For automated refresh on a moving window:
```sql
SELECT add_continuous_aggregate_policy(
  'cpu_metrics_hourly',
  start_offset => INTERVAL '7 days',
  end_offset   => INTERVAL '1 hour',
  schedule_interval => INTERVAL '15 minutes'
);
```

**Note:** the materialization caches the result and thus, makes the cost more predictable. It trades query-time compute for refresh-time compute. You now control when cost is incurred, as users do not trigger it on demand.

# Architectural Decision Boundary

The most common architectural mistake is choosing a system based on a features benchmark rather than the dominant access pattern. A system that supports a feature is not the same as a system that is optimised for it.

Therefore, choosing the right specialization should always be driven by the:
- dominant query pattern
- cost profile (compute vs. storage vs. index maintenance)
- latency requirements
- expected scaling behaviour under load

A short mention must be made around PostgreSQl and Kafka as these are not competing tools but are rather solving different problem in the same architectural ecosystem:
- PostgreSQL is optimized around state (storage, index maintenance, query execution, transactional guarantees)
- Kafka / event systems is optimized around data flow (moving data between system reliably, decoupling producers from consumers, allowing replay and fan-out at scale)

In that regard, the decision boundary is therefore not "which one is better" but "which problem am I solving". PostgreSQL shows up naturally whenever in need of a query answer and Kafka when data is required to move and fan out to multiple consumers.

# Where This Breaks at Scale

The patterns in this lab are sound for moderate data volumes and mixed workloads on a single engine. At scale, each specialisation hits a different wall.

## Write Throughput - GIN Becomes a Bottleneck

GIN's posting lists are expensive to maintain under high write volume. Even with `fastupdate = on`. At scale, gradual degradation is expected. The fix is usually to either disable GIN on the hot write path and rebuild periodically (acceptable for append-only logs) or to stop indexing the full JSONB column and switch to targeted expression indexes on the promoted keys only.

## Connection Overhead - PostgresSQL Is Process-Based

PostgreSQl forks a process per connection, not a thread. Each process carries ~5-10MB of overhead. At a few hundred concurrent connections, this becomes a memory problem. A spike in application concurrency translates directly into a spike in PostgreSQL processes, which degrades performance for everyone, not just the newcomers. The standard mitigation is a connection pooler sitting in front of PostgreSQL (e.g. `PgBouncer` in transaction mode).

## Vacuum and Bloat - MVCC Maintenance Cost

PostgreSQL's Multi-Version Concurrency Control (MVCC) never overwrites rows in place but writes a new version and marks the old one dead. Auto-vacuum then reclaims dead tuples but under heavy update or delete workloads, can struggle to keep up. For JSONB columns with frequent partial updates, each update to any key in the document writes a full new row version. At scale, a JSONB-heavy table can balloon to several time its logical size without obvious symptoms.

## TimeScaleDB Continuous Aggregates - Refresh Lag Under Backfill

Continuous aggregates with bounded refresh windows are efficient for the current window but degrade under out-of-order or backfilled data. A late-arriving event that falls outside the refresh window either gets silently excluded or forces a full recomputation of historical buckets, depending on policy configuration.
At scale, this matters in any pipeline where upstream delays are normal (late CDC events, retried Kafka consumers, or manual data corrections). The refresh policy gives us predictable cost under normal conditions, but exceptional conditions (incident recovery, historical reloads) can saturate the refresh worker and stall the aggregate for the live window.

## Single-Node Ceiling - No Horizontal Write Scaling

Everything in this lab runs on a single PostgreSQL node. Read scaling is achievable through streaming replication and read replicas. Write scaling is not (PostgreSQL has no native sharding). At the point where write throughput saturates a single node (typically measured in tens of thousands of transactions per second for mixed OLTP, or ingestion rates in the hundreds of thousands of rows per second for time-series), the architectural boundary shifts.
