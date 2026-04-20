-- MATERIALIZED VIEW and not TABLE to have a managed cache, I explain:
-- when running `REFRESH MATERIALIZED VIEW cpu_metrics_hourly;` with MATERIALIZED VIEW,
-- Postgres automatically recomputes everything. With TABLE, you have full ownership:
-- You decide when to update and how to update (incremental, merge, overwrite etc.)
-- MATERIALIZATION (vs. VIEW) moves compute from read time to write/refresh time, making
-- costs predictable (we control refresh but not when user trigger compute).ma
CREATE MATERIALIZED VIEW cpu_metrics_hourly
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 hour', ts) AS bucket,
    host,
    avg(cpu_percent) AS avg_cpu,
    min(cpu_percent) AS min_cpu,
    max(cpu_percent) AS max_cpu
FROM cpu_metrics
GROUP BY bucket, host;