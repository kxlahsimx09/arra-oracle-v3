-- Lightweight DB health observability for mb-next-staging (Supabase, project sinuwgsqqyqzlpaavimf).
-- Self-contained in schema `obs`; drop with: DROP SCHEMA obs CASCADE; SELECT cron.unschedule('obs-health-capture');
-- Captures a metrics snapshot every 5 min via pg_cron; views expose rates + threshold breaches.
-- Deliberately does NOT alert on rollback% — investigation (2026-06-23) proved the ~65% rollback
-- rate is benign Keep workflow-poller churn (BEGIN/SELECT/ROLLBACK), not errors.

create schema if not exists obs;

create table if not exists obs.health_history (
  captured_at   timestamptz primary key default now(),
  numbackends   int,
  active        int,
  idle_in_tx    int,
  xact_commit   bigint,
  xact_rollback bigint,
  temp_files    bigint,
  temp_bytes    bigint,
  cache_hit_pct numeric,
  deadlocks     bigint,
  max_xid_age   bigint,
  db_size       bigint
);

-- one snapshot of current cumulative counters
create or replace function obs.capture_health() returns void
language sql security definer set search_path = public as $$
  insert into obs.health_history
    (captured_at,numbackends,active,idle_in_tx,xact_commit,xact_rollback,
     temp_files,temp_bytes,cache_hit_pct,deadlocks,max_xid_age,db_size)
  select now(),
    (select count(*) from pg_stat_activity),
    (select count(*) from pg_stat_activity where state='active'),
    (select count(*) from pg_stat_activity where state='idle in transaction'),
    d.xact_commit, d.xact_rollback, d.temp_files, d.temp_bytes,
    round(100.0*d.blks_hit/nullif(d.blks_hit+d.blks_read,0),2),
    d.deadlocks,
    (select max(age(relfrozenxid)) from pg_class where relkind in ('r','t','m')),
    pg_database_size(current_database())
  from pg_stat_database d
  where d.datname = current_database()
  on conflict (captured_at) do nothing;
$$;

-- per-interval deltas (rates) between consecutive snapshots
create or replace view obs.health_rates as
select captured_at,
  round(extract(epoch from captured_at - lag(captured_at) over w),0)        as secs,
  numbackends, active, idle_in_tx, cache_hit_pct,
  (xact_commit   - lag(xact_commit)   over w)                                as commits,
  (xact_rollback - lag(xact_rollback) over w)                                as rollbacks,
  round(100.0*(xact_rollback-lag(xact_rollback) over w)
    / nullif((xact_rollback-lag(xact_rollback) over w)
            +(xact_commit  -lag(xact_commit)   over w),0),1)                 as rollback_pct,
  (temp_files - lag(temp_files) over w)                                      as temp_files_new,
  pg_size_pretty((temp_bytes - lag(temp_bytes) over w))                      as temp_added,
  round(100.0*max_xid_age/2.1e9,2)                                           as wraparound_pct,
  pg_size_pretty(db_size)                                                    as db_size
from obs.health_history
window w as (order by captured_at)
order by captured_at desc;

-- "what's wrong right now" — returns rows ONLY on threshold breach (Keep/cron can watch this)
create or replace view obs.health_alerts as
with r as (select * from obs.health_rates where secs is not null order by captured_at desc limit 1)
select alert, detail from (
  select 'temp_spill'::text as alert, 'temp_files +'||temp_files_new||' ('||temp_added||') in '||secs||'s' as detail
    from r where temp_files_new > 10
  union all select 'idle_in_transaction', 'idle-in-tx sessions = '||idle_in_tx from r where idle_in_tx > 3
  union all select 'low_cache_hit', 'cache_hit = '||cache_hit_pct||'%' from r where cache_hit_pct < 95
  union all select 'high_connections', 'backends = '||numbackends||' / 60' from r where numbackends > 50
  union all select 'xid_wraparound', 'wraparound = '||wraparound_pct||'%' from r where wraparound_pct > 50
) a;

grant usage on schema obs to investigator_ro;
grant select on all tables in schema obs to investigator_ro;
alter default privileges in schema obs grant select on tables to investigator_ro;
