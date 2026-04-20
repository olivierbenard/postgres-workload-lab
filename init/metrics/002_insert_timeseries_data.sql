INSERT INTO cpu_metrics (ts, host, cpu_percent)
VALUES
  (now() - interval '90 minutes', 'host-a', 41.2),
  (now() - interval '70 minutes', 'host-a', 53.8),
  (now() - interval '10 minutes', 'host-a', 72.1),
  (now() - interval '5 minutes',  'host-a', 65.4);