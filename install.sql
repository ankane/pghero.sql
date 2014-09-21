BEGIN;

-- views

CREATE OR REPLACE VIEW pghero_running_queries AS
  SELECT
    pid,
    state,
    application_name AS source,
    age(now(), xact_start) AS duration,
    waiting,
    query
  FROM
    pg_stat_activity
  WHERE
    query <> '<insufficient privilege>'
    AND state <> 'idle'
    AND pid <> pg_backend_pid()
  ORDER BY
    query_start DESC;

CREATE OR REPLACE VIEW pghero_long_running_queries AS
  SELECT * FROM pghero_running_queries WHERE duration > interval '5 minutes';

CREATE OR REPLACE VIEW pghero_index_usage AS
  SELECT
    relname AS table,
    CASE idx_scan
      WHEN 0 THEN 'Insufficient data'
      ELSE (100 * idx_scan / (seq_scan + idx_scan))::text
    END percent_of_times_index_used,
    n_live_tup rows_in_table
  FROM
    pg_stat_user_tables
  ORDER BY
    n_live_tup DESC,
    relname ASC;

CREATE OR REPLACE VIEW pghero_missing_indexes AS
  SELECT * FROM pghero_index_usage WHERE percent_of_times_index_used <> 'Insufficient data' AND percent_of_times_index_used::integer < 95 AND rows_in_table >= 10000;

CREATE OR REPLACE VIEW pghero_unused_indexes AS
  SELECT
    relname AS table,
    indexrelname AS index,
    pg_size_pretty(pg_relation_size(i.indexrelid)) AS index_size,
    idx_scan as index_scans
  FROM
    pg_stat_user_indexes ui
  INNER JOIN
    pg_index i ON ui.indexrelid = i.indexrelid
  WHERE
    NOT indisunique
    AND idx_scan < 50 AND pg_relation_size(relid) > 5 * 8192
  ORDER BY
    pg_relation_size(i.indexrelid) / nullif(idx_scan, 0) DESC NULLS FIRST,
    pg_relation_size(i.indexrelid) DESC,
    relname ASC;

CREATE OR REPLACE VIEW pghero_relation_sizes AS
  SELECT
    c.relname AS name,
    CASE WHEN c.relkind = 'r' THEN 'table' ELSE 'index' END AS type,
    pg_size_pretty(pg_table_size(c.oid)) AS size
  FROM
    pg_class c
  LEFT JOIN
    pg_namespace n ON (n.oid = c.relnamespace)
  WHERE
    n.nspname NOT IN ('pg_catalog', 'information_schema')
    AND n.nspname !~ '^pg_toast'
    AND c.relkind IN ('r', 'i')
  ORDER BY
    pg_table_size(c.oid) DESC,
    name ASC;

-- functions

CREATE OR REPLACE FUNCTION pghero_index_hit_rate()
  RETURNS numeric AS
$$
  SELECT
    (sum(idx_blks_hit)) / nullif(sum(idx_blks_hit + idx_blks_read),0) AS rate
  FROM
    pg_statio_user_indexes;
$$
  LANGUAGE SQL;

CREATE OR REPLACE FUNCTION pghero_table_hit_rate()
  RETURNS numeric AS
$$
  SELECT
    sum(heap_blks_hit) / nullif(sum(heap_blks_hit) + sum(heap_blks_read),0) AS rate
  FROM
    pg_statio_user_tables;
$$
  LANGUAGE SQL;

CREATE OR REPLACE FUNCTION pghero_kill(integer)
  RETURNS boolean AS
$$
  SELECT pg_cancel_backend($1);
$$
  LANGUAGE SQL;

CREATE OR REPLACE FUNCTION pghero_kill_all()
  RETURNS boolean AS
$$
  SELECT
    pg_terminate_backend(pid)
  FROM
    pg_stat_activity
  WHERE
    pid <> pg_backend_pid()
    AND query <> '<insufficient privilege>';
$$
  LANGUAGE SQL;

COMMIT;
