BEGIN;

-- views

CREATE OR REPLACE VIEW pghero_running_queries AS
  SELECT
    pid,
    state,
    application_name AS source,
    age(now(), xact_start) AS duration,
    wait_event_type,
    wait_event,
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

-- table bloat views

CREATE OR REPLACE VIEW pghero_relation_bloat AS (
SELECT current_database(), schemaname, tblname, 
  pg_size_pretty((bs*tblpages)::bigint) AS real_size,
  pg_size_pretty(abs(((tblpages-est_tblpages)*bs)::bigint)) AS extra_size,
  CASE WHEN abs(tblpages - est_tblpages) > 0
    THEN 100 * abs(tblpages - est_tblpages)/tblpages::float
    ELSE 0
  END AS extra_ratio, fillfactor, 
  abs(((tblpages-est_tblpages_ff)*bs)::bigint) AS bloat_size_bytes,
  CASE WHEN abs(tblpages - est_tblpages_ff) > 0
    THEN 100 * abs(tblpages - est_tblpages_ff)/tblpages::float
    ELSE 0
  END AS bloat_ratio, is_na
FROM (
  SELECT ceil( reltuples / ( (bs-page_hdr)/tpl_size ) ) + ceil( toasttuples / 4 ) AS est_tblpages,
    ceil( reltuples / ( (bs-page_hdr)*fillfactor/(tpl_size*100) ) ) + ceil( toasttuples / 4 ) AS est_tblpages_ff,
    tblpages, fillfactor, bs, tblid, schemaname, tblname, heappages, toastpages, is_na
  FROM (
    SELECT
      ( 4 + tpl_hdr_size + tpl_data_size + (2*ma)
        - CASE WHEN tpl_hdr_size%ma = 0 THEN ma ELSE tpl_hdr_size%ma END
        - CASE WHEN ceil(tpl_data_size)::int%ma = 0 THEN ma ELSE ceil(tpl_data_size)::int%ma END
      ) AS tpl_size, bs - page_hdr AS size_per_block, (heappages + toastpages) AS tblpages, heappages,
      toastpages, reltuples, toasttuples, bs, page_hdr, tblid, schemaname, tblname, fillfactor, is_na
    FROM (
      SELECT
        tbl.oid AS tblid, ns.nspname AS schemaname, tbl.relname AS tblname, tbl.reltuples,
        tbl.relpages AS heappages, coalesce(toast.relpages, 0) AS toastpages,
        coalesce(toast.reltuples, 0) AS toasttuples,
        coalesce(substring(
          array_to_string(tbl.reloptions, ' ')
          FROM '%fillfactor=#"__#"%' FOR '#')::smallint, 100) AS fillfactor,
        current_setting('block_size')::numeric AS bs,
        CASE WHEN version()~'mingw32' OR version()~'64-bit|x86_64|ppc64|ia64|amd64' THEN 8 ELSE 4 END AS ma,
        24 AS page_hdr,
        23 + CASE WHEN MAX(coalesce(null_frac,0)) > 0 THEN ( 7 + count(*) ) / 8 ELSE 0::int END
          + CASE WHEN tbl.relhasoids THEN 4 ELSE 0 END AS tpl_hdr_size,
        sum( (1-coalesce(s.null_frac, 0)) * coalesce(s.avg_width, 1024) ) AS tpl_data_size,
        bool_or(att.atttypid = 'pg_catalog.name'::regtype) AS is_na
      FROM pg_attribute AS att
        JOIN pg_class AS tbl ON att.attrelid = tbl.oid
        JOIN pg_namespace AS ns ON ns.oid = tbl.relnamespace
        JOIN pg_stats AS s ON s.schemaname=ns.nspname
          AND s.tablename = tbl.relname AND s.inherited=false AND s.attname=att.attname
        LEFT JOIN pg_class AS toast ON tbl.reltoastrelid = toast.oid
      WHERE att.attnum > 0 AND NOT att.attisdropped
        AND tbl.relkind = 'r'
      GROUP BY 1,2,3,4,5,6,7,8,9,10, tbl.relhasoids
      ORDER BY 2,3
    ) AS s
  ) AS s2
) AS s3
WHERE schemaname not in ('information_schema','pg_catalog')
ORDER BY bloat_size_bytes desc
);

CREATE OR REPLACE VIEW pghero_relation_needs_vacuum AS (
    select * from pghero_relation_bloat where bloat_ratio > 10 and bloat_size_bytes > (1024 * 1024 * 100)
);

CREATE OR REPLACE VIEW pghero_relation_last_vacuum AS (
    SELECT relname, last_vacuum, last_autovacuum, last_analyze, last_autoanalyze FROM pg_stat_user_tables
);

-- internal cache hitrate

CREATE OR REPLACE VIEW pghero_cache_hitrate AS (
SELECT 
  sum(heap_blks_read) as heap_read,
  sum(heap_blks_hit)  as heap_hit,
  sum(heap_blks_hit) / (sum(heap_blks_hit) + sum(heap_blks_read)) as cache_hitrate
FROM 
  pg_statio_user_tables
);

CREATE OR REPLACE VIEW pghero_cache_indexrate AS (
SELECT 
  sum(idx_blks_read) as idx_read,
  sum(idx_blks_hit)  as idx_hit_in_cache,
  (sum(idx_blks_hit) - sum(idx_blks_read)) / sum(idx_blks_hit) as idx_in_cache_hitrate
FROM 
  pg_statio_user_indexes
);

CREATE OR REPLACE VIEW pghero_relation_hot AS (SELECT
  relname as table,
  (n_tup_upd + n_tup_ins + n_tup_del) as total_changes,
  n_tup_ins as total_inserts,
  n_tup_del as total_deletes,
  trunc( ((n_tup_ins::float + n_tup_del::float) / (n_tup_upd::float + n_tup_ins::float + n_tup_del::float) )::numeric,2) as insert_delete_ratio,
  n_tup_upd as total_updates,
  trunc( ((n_tup_upd::float) / (n_tup_upd::float + n_tup_ins::float + n_tup_del::float))::numeric,2 ) as update_ratio,
  n_tup_hot_upd as hot_updates,
  trunc( (n_tup_hot_upd::float / (n_tup_upd::float + 1) )::numeric,2) as hot_update_ratio
FROM
  pg_stat_user_tables
WHERE
  (n_tup_upd + n_tup_ins + n_tup_del) > 0
ORDER BY 2 DESC
);

CREATE OR REPLACE VIEW pghero_client_statistics AS (
   select 
     count(*) as total,
     count(*) filter (where state like 'idle%') as idle,
     count(*) filter (where state='active') as active,
     count(*) filter (where query ilike 'REFRESH MATERIALIZED VIEW%') as refresh_materialized_view,
     count(*) filter (where query ilike 'autovacuum%') as autovacuum
   from pg_stat_activity
   where pid <> pg_backend_pid()
);

COMMIT;
