-- job_feed adapter/seed triage queries. All read-only. Run via:
--   docker exec job_feed_postgres psql -U jobfeed -d jobfeed -c "<query>"
-- Replace :prov with the provider name. Keep each call < 45s (MCP timeout).

-- 1. Account health overview — is the provider's seed base ok/failing/stale?
SELECT last_status, count(*), count(*) FILTER (WHERE is_active) AS act,
       max(last_synced_at)::date AS last
FROM company_ats_accounts WHERE provider = ':prov' GROUP BY last_status;

-- 2. Error clustering — one bad pattern usually explains most failures
--    (e.g. ENOTFOUND *.wd101.myworkdayjobs.com = bad Workday cluster guess).
SELECT left(last_error_message, 75) AS err, count(*)
FROM company_ats_accounts
WHERE provider = ':prov' AND last_error_message IS NOT NULL
GROUP BY 1 ORDER BY 2 DESC LIMIT 8;

-- 3. Run history 7d — distinguishes "never scheduled" from "running and failing"
SELECT status, count(*), max(started_at)
FROM sync_runs
WHERE provider = ':prov' AND started_at > now() - interval '7 days'
GROUP BY status;

-- 4. Job volume + status — all-active with new7d=total means fresh onboard
SELECT status, count(*) FROM jobs WHERE provider = ':prov' GROUP BY status;

-- 5. Field quality — low descr/posted % clustered by account = template variant
SELECT count(*) FILTER (WHERE description_text IS NOT NULL AND length(description_text) > 50) AS descr,
       count(*) FILTER (WHERE salary_min_usd IS NOT NULL) AS sal,
       count(*) FILTER (WHERE posted_at IS NOT NULL) AS posted,
       count(*) FILTER (WHERE first_seen_at > now() - interval '7 days') AS new7d,
       max(first_seen_at)::date AS last_ingest
FROM jobs WHERE provider = ':prov';

-- 6. Country mix — US-only policy check
SELECT country, count(*) FROM jobs
WHERE provider = ':prov' AND status = 'active'
GROUP BY country ORDER BY 2 DESC LIMIT 8;

-- 7. Which accounts hold the broken jobs? (e.g. description IS NULL)
SELECT a.slug, count(*)
FROM jobs j JOIN company_ats_accounts a ON a.id = j.ats_account_id
WHERE j.provider = ':prov' AND j.description_text IS NULL
GROUP BY a.slug ORDER BY 2 DESC LIMIT 8;

-- 8. Small all-broken account for cheap smoke testing
SELECT a.slug, count(*)
FROM jobs j JOIN company_ats_accounts a ON a.id = j.ats_account_id
WHERE j.provider = ':prov'
GROUP BY a.slug
HAVING count(*) = count(*) FILTER (WHERE j.description_text IS NULL)
   AND count(*) BETWEEN 3 AND 10
LIMIT 4;

-- 9. Is the DB slow right now? (after big UPDATEs: autovacuum + MV refresh)
SELECT extract(epoch FROM now() - query_start)::int AS sec, state, left(query, 55)
FROM pg_stat_activity
WHERE pid <> pg_backend_pid() AND state = 'active' LIMIT 5;

-- 10. Rotation position — when was the provider last reached vs the queue tail
SELECT provider, min(last_synced_at) AS stalest, max(last_synced_at) AS freshest
FROM company_ats_accounts WHERE is_active GROUP BY provider
ORDER BY stalest ASC LIMIT 10;

-- 11. Zero-US-yield boards per provider (rotation waste; 2026-07-14: 22.6k of 49.7k active).
--     NOTE: the ORDER BY needs the subquery wrap (aliases of aggregates aren't orderable inline).
SELECT * FROM (
  WITH per_acct AS (SELECT ats_account_id, COUNT(*) total, COUNT(*) FILTER (WHERE country='US') us FROM jobs GROUP BY 1)
  SELECT a.provider, COUNT(*) active_accts,
         COUNT(*) FILTER (WHERE COALESCE(p.us,0)>0)                       AS us_yield,
         COUNT(*) FILTER (WHERE COALESCE(p.us,0)=0 AND COALESCE(p.total,0)>0) AS zero_us,
         COUNT(*) FILTER (WHERE COALESCE(p.total,0)=0)                    AS never_any
  FROM company_ats_accounts a LEFT JOIN per_acct p ON p.ats_account_id=a.id
  WHERE a.is_active GROUP BY 1
) t ORDER BY zero_us + never_any DESC LIMIT 22;

-- 11b. Prunability of the zero-US boards: ok/not_found = safe to deactivate (+ paired expiry!);
--      network/unknown errors belong to the recovery pipeline; NULL last_status = never synced, leave.
WITH per_acct AS (SELECT ats_account_id, COUNT(*) FILTER (WHERE country='US') us FROM jobs GROUP BY 1)
SELECT a.last_status, COUNT(*) FROM company_ats_accounts a
LEFT JOIN per_acct p ON p.ats_account_id=a.id
WHERE a.is_active AND COALESCE(p.us,0)=0 GROUP BY 1 ORDER BY 2 DESC;

-- 12. Rotation staleness percentiles. GOTCHAS: percentile_cont refuses timestamptz (cast to epoch)
--     and round(double,int) doesn't exist (cast ::numeric).
SELECT COUNT(*) FILTER (WHERE is_active) AS active_accts, COUNT(*) AS total_accts,
  ROUND(((EXTRACT(EPOCH FROM now())-percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM last_synced_at)) FILTER (WHERE is_active))/86400)::numeric,1) AS med_days,
  ROUND(((EXTRACT(EPOCH FROM now())-percentile_cont(0.1) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM last_synced_at)) FILTER (WHERE is_active))/86400)::numeric,1) AS p90_days
FROM company_ats_accounts;

-- 13. Churn/treadmill check: reported jobs_new vs rows that actually survived the week.
--     reported >> created  =>  dedupe DELETE -> re-insert treadmill (see decision table).
SELECT provider, SUM(jobs_new) AS reported_new FROM sync_runs
WHERE started_at > now()-interval '7 days' GROUP BY 1 ORDER BY 2 DESC LIMIT 8;
SELECT provider, COUNT(*) AS created_7d FROM jobs
WHERE created_at > now()-interval '7 days' GROUP BY 1 ORDER BY 2 DESC LIMIT 8;

-- 14. Immortal orphans: active jobs on accounts that can never sweep them (inactive accounts).
--     Pair every deactivation with expiry of these rows.
SELECT a.provider, COUNT(DISTINCT a.id) AS accts, COUNT(*) AS jobs,
       COUNT(*) FILTER (WHERE j.country='US') AS us_jobs
FROM jobs j JOIN company_ats_accounts a ON a.id=j.ats_account_id
WHERE j.status='active' AND NOT a.is_active GROUP BY 1 ORDER BY 3 DESC;

-- 15. Description coverage (short/teaser hunt — see description-coverage.md).
--     COST: keep these provider-scoped; a fleet-wide description_html LIKE scan ran ~10 min.
-- 15a. Per-provider short-row coverage (columns are description_text/description_html — there is no `description`)
SELECT count(*) AS active,
       count(*) FILTER (WHERE coalesce(description_text,'')='') AS no_desc,
       count(*) FILTER (WHERE length(description_text) BETWEEN 1 AND 500) AS short_desc,
       round(avg(length(description_text))) AS avg_len
FROM jobs WHERE provider=':prov' AND status='active';
-- 15b. Which accounts hold the short rows (100%-short accounts = detail path dead for that tenant,
--      e.g. phenom wrong locale prefix)
SELECT a.slug, count(*) AS total, count(*) FILTER (WHERE length(j.description_text) < 600) AS shortish
FROM jobs j JOIN company_ats_accounts a ON a.id=j.ats_account_id
WHERE j.provider=':prov' AND j.status='active' GROUP BY 1 ORDER BY 3 DESC LIMIT 15;
-- 15c. Length histogram — look for a bimodal gap to pick a teaser threshold
--      (phenom: teasers <=462 vs full >=644; oracle has NO gap, use 15d instead)
SELECT width_bucket(length(description_text), ARRAY[0,100,200,300,400,500,600,800,1000,2000,4000]) AS b,
       min(length(description_text)) AS mn, max(length(description_text)) AS mx, count(*)
FROM jobs WHERE provider=':prov' AND status='active' AND description_text IS NOT NULL
GROUP BY 1 ORDER BY 1;
-- 15d. oracle_cloud only: listing-only marker (adapter stores rawPayload {list, detail};
--      upsert overwrites it every sync, so detail-null = last arrival was listing-only)
SELECT (raw_payload->'detail' IS NOT NULL AND raw_payload->>'detail' IS NULL) AS listing_only,
       count(*), count(*) FILTER (WHERE length(description_text) BETWEEN 1 AND 500) AS short
FROM jobs WHERE provider='oracle_cloud' AND status='active' GROUP BY 1;

-- §16 parity KPIs (docs/plans/2026-09-03-jobfeed-hiringcafe-parity-program.md §5). Run weekly.
-- Direct ledger (what we publish): active US rows from employer-direct providers, deduped, + employers.
-- The provider list MUST equal PUBLIC_DIRECT_PROVIDERS (src/lib/job-sources.ts) — Wave 3 (careerplug/hireology/talentreef/harri) added 2026-09-07.
WITH direct AS (
  SELECT canonical_hash, company_id, provider FROM jobs
  WHERE status='active' AND country='US'
    AND provider IN ('greenhouse','lever','ashby','workable','recruitee','personio','smartrecruiters','bamboohr','teamtailor','jobvite','workday','oracle_cloud','brassring','avature','icims','breezy','join','rippling','gem','recruiterbox','jazzhr','phenom','cornerstone','taleo','successfactors','eightfold','pinpoint','usajobs','adp_wfn','ukg_pro','paycom','paylocity','dayforce','neogov','frontline','workstream','careerplug','hireology','talentreef','harri')
)
SELECT count(*) direct_rows, count(DISTINCT canonical_hash) direct_unique, count(DISTINCT company_id) direct_employers FROM direct;
-- Long-tail lane health: seeds, yield, staleness.
SELECT provider, count(*) FILTER (WHERE is_active) active_accts,
       count(*) FILTER (WHERE is_active AND last_status='ok') ok,
       round(percentile_cont(0.9) WITHIN GROUP (ORDER BY extract(epoch FROM now()-last_synced_at)/86400)::numeric,1) p90_age_d
FROM company_ats_accounts WHERE provider IN ('adp_wfn','ukg_pro','paycom','paylocity','dayforce','neogov','frontline','workstream','careerplug','hireology','talentreef','harri') GROUP BY 1;
SELECT provider, count(*) active_jobs, count(DISTINCT company_id) employers FROM jobs
WHERE status='active' AND provider IN ('adp_wfn','ukg_pro','paycom','paylocity','dayforce','neogov','frontline','workstream','careerplug','hireology','talentreef','harri','smartrecruiters','workable','jobvite','avature') GROUP BY 1 ORDER BY 2 DESC;
-- True intake (never sync_runs.jobs_new): rows created per day, last 14 days.
SELECT first_seen_at::date d, count(*) FROM jobs WHERE first_seen_at > now()-interval '14 days' GROUP BY 1 ORDER BY 1;
-- Discovery funnel state.
SELECT provider, status, count(*), sum(us_job_count) us_jobs FROM ats_tenant_candidates GROUP BY 1,2 ORDER BY 1,2;

-- §17 24-hour SPOT CHECK (2026-09-06). Run after ANY adapter ships/changes. Two queries:
-- (a) per-provider field coverage over rows created in the last 24 h. Heavy (regex over
--     description_text) — detach it if the window holds >100k rows. Read it against the
--     healthy baseline: US ≈ 100, posted ≥ 95, desc200 ≥ 80 (detail-capped first passes read
--     lower and self-heal), salary 15–90 by source, city/region ≈ 100, emp/remote 100 (these
--     are CLASSIFIER defaults — a provider at 100% full_time is a defect, see §17c), title_junk
--     and desc_junk 0.0.
SELECT j.provider, count(*) n,
       round(100.0*count(*) FILTER (WHERE j.country='US')/count(*)) us,
       round(100.0*count(*) FILTER (WHERE posted_at IS NOT NULL)/count(*)) posted,
       round(100.0*count(*) FILTER (WHERE length(description_text)>200)/count(*)) desc200,
       round(100.0*count(*) FILTER (WHERE salary_min_usd IS NOT NULL OR salary_max_usd IS NOT NULL)/count(*)) salary,
       round(100.0*count(*) FILTER (WHERE l.city IS NOT NULL)/count(*)) city,
       round(100.0*count(*) FILTER (WHERE l.region IS NOT NULL)/count(*)) region,
       round(100.0*count(*) FILTER (WHERE employment_type IS NOT NULL)/count(*)) emp,
       round(100.0*count(*) FILTER (WHERE soc_code IS NOT NULL)/count(*)) soc,
       round(100.0*count(*) FILTER (WHERE title ~ '&[a-z#0-9]+;|<|document\.write')/count(*),1) title_junk,
       round(100.0*count(*) FILTER (WHERE description_text ~ 'document\.write|&nbsp;|&amp;|\\n')/count(*),1) desc_junk,
       round(avg(length(description_text))) avg_desc
FROM jobs j LEFT JOIN job_locations l ON l.job_id=j.id AND l.is_primary
WHERE j.status='active' AND j.first_seen_at > now()-interval '24 hours'
  AND j.provider IN ('adp_wfn','ukg_pro','paycom','paylocity','dayforce','neogov','frontline','workstream','careerplug','hireology','talentreef','harri')
GROUP BY 1 ORDER BY 2 DESC;
-- (b) 15 random rows per provider to EYEBALL (write to a file, then read it). TRAP: coalesce on
--     an enum column needs ::text or Postgres rejects the sentinel ("invalid input value for
--     enum employment_type").
SELECT j.provider, left(j.title,55), left(c.name,32), coalesce(l.city,'-'), coalesce(l.region,'-'),
       coalesce(j.posted_at::date::text,'-'), length(coalesce(j.description_text,'')),
       coalesce(j.salary_min_usd::text,'-')||'-'||coalesce(j.salary_max_usd::text,'-')||'/'||coalesce(j.salary_period_raw,'-'),
       coalesce(j.employment_type::text,'-'), left(coalesce(j.department,'-'),25), left(j.apply_url,60)
FROM (SELECT *, row_number() OVER (PARTITION BY provider ORDER BY random()) rn FROM jobs
      WHERE status='active' AND first_seen_at > now()-interval '24 hours'
        AND provider IN ('adp_wfn','ukg_pro','paycom','paylocity','dayforce','neogov','frontline','workstream')) j
JOIN companies c ON c.id=j.company_id LEFT JOIN job_locations l ON l.job_id=j.id AND l.is_primary
WHERE j.rn<=15 ORDER BY j.provider, j.rn;
-- (c) the defect signatures the 2026-09-06 check found — each should return ~0 after the fixes:
SELECT 'hourly_as_annual' k, provider, count(*) FROM jobs WHERE status='active' AND salary_source='listed' AND salary_period_raw IS NULL AND salary_max_usd < 300 GROUP BY 1,2
UNION ALL SELECT 'month_gt_300k', provider, count(*) FROM jobs WHERE status='active' AND salary_period_raw='month' AND salary_min_usd > 300000 GROUP BY 1,2
UNION ALL SELECT 'city_has_dash_label', j.provider, count(*) FROM jobs j JOIN job_locations l ON l.job_id=j.id AND l.is_primary WHERE j.status='active' AND l.city ~ ' - ' GROUP BY 1,2
UNION ALL SELECT 'dept_placeholder', provider, count(*) FROM jobs WHERE status='active' AND (department IN ('N/A','n/a','None','-','—','null') OR department ~ '^\s*$') GROUP BY 1,2
UNION ALL SELECT 'synthetic_company', j.provider, count(*) FROM jobs j JOIN companies c ON c.id=j.company_id WHERE j.status='active' AND c.name ~ '^(adp_wfn|paycom|paylocity|ukg_pro|dayforce|workstream) [0-9a-f]{6,}' GROUP BY 1,2
ORDER BY 1,3 DESC;
-- (d) employment-type mix per provider — a single class at ~100% means the raw signal is
--     missing and the classifier default is masking it (derive from the title in the adapter).
SELECT provider, employment_type, count(*) FROM jobs WHERE status='active' AND first_seen_at > now()-interval '24 hours'
  AND provider IN ('adp_wfn','ukg_pro','paycom','paylocity','dayforce','neogov','frontline','workstream') GROUP BY 1,2 ORDER BY 1,3 DESC;
