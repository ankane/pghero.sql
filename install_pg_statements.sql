BEGIN;

-- you need to preload the pg_stat_statements shared library
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- select / update analysis

CREATE OR REPLACE VIEW pghero_slow_selects AS (SELECT 
  s.calls as calls,
  (s.total_time / 1000 / 60) as total_minutes, 
  (s.total_time/s.calls) as average_time_ms, 
  a.rolname as username,
  d.datname as database,
  (s.shared_blks_hit::float / (s.shared_blks_hit::float + s.shared_blks_read::float + 1)) as buffer_hitrate,
  s.rows,
  s.query
FROM pg_stat_statements s
    INNER JOIN pg_authid a ON (s.userid=a.oid)
    INNER JOIN pg_database d ON (s.dbid=d.oid)
WHERE
    s.query ilike '%select%'
ORDER BY 1 DESC 
);

CREATE OR REPLACE VIEW pghero_slow_updates AS (SELECT 
  s.calls as calls,
  (s.total_time / 1000 / 60) as total_minutes, 
  (s.total_time/s.calls) as average_time_ms, 
  a.rolname as username,
  d.datname as database,
  (s.shared_blks_hit::float / (s.shared_blks_hit::float + s.shared_blks_read::float + 1)) as buffer_hitrate,
  s.rows,
  s.query
FROM pg_stat_statements s
    INNER JOIN pg_authid a ON (s.userid=a.oid)
    INNER JOIN pg_database d ON (s.dbid=d.oid)
WHERE
    (s.query ilike '%update %' OR s.query ilike '%insert %' OR s.query ilike '%delete %')
ORDER BY 1 DESC
);

COMMIT;