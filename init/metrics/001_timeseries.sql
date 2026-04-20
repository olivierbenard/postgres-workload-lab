CREATE EXTENSION IF NOT EXISTS timescaledb;

-- this table is a perfectly timescaledb candidate:
-- (1) the main partitioning axis is time
-- (2) data is append-heavy
-- (3) repeated queries will be bucketed aggregations over time
CREATE TABLE cpu_metrics (
    ts TIMESTAMPTZ NOT NULL,
    host TEXT NOT NULL,
    cpu_percent DOUBLE PRECISION NOT NULL
);

-- turns the normal table cpu_metrics into a time-series table optimized by TimescaleDB
-- (split into many smaller tables/chunks) using ts as the time dimension/partition
-- each chunks stores a time range (e.g. 1 day, 1 week) and inserts are automatically
-- routed to the right chunk. Automatically, queries will only scan the relevant chunks
-- and time-series can now be enabled:
-- a. compression policies
-- b. retention policies
-- c. continuous aggregates
-- d. chunk-level optimisations
SELECT create_hypertable('cpu_metrics', 'ts');