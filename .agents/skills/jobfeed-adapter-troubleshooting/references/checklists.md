# Fix-pattern checklists

## A. New adapter, end-to-end (themuse, June 2026, as reference)

1. Probe the upstream API/feed with curl FIRST: shape, volume, page_count,
   rate limits, sort guarantees, location filter behavior. Decide full-fetch
   vs shard model (cap pages if feed > ~5K jobs).
2. `src/db/schema.ts`: add provider to the `pgEnum` array if missing from the
   TS union (no migration if the value already exists in the DB enum).
3. `src/adapters/<provider>.ts`: copy the closest pattern —
   `remotive.ts` (simple aggregator), `jooble.ts` (config shards),
   `successfactors.ts` (RSS/XML ATS), `jazzhr.ts` (HTML scrape + detail
   enrichment). Include the US-only filter from day one. Header comment must
   document endpoint, response shape, caveats.
4. `src/adapters/index.ts`: import + registry key (+ `isAggregator` if agg).
5. Aggregators: add to always-on list in `src/cli/sync-aggregators.ts`; add
   seed entries in `src/cli/seed-aggregators.ts` (ON CONFLICT DO NOTHING —
   safe to rerun).
6. Lint: `bun x oxlint -c /opt/stacks/saas-starter/.oxlintrc.json <files>` (repo
   standard is oxlint, NOT eslint). Typecheck ON THE HOST: `npx tsc --noEmit`
   from `job_feed/` (SKILL.md §rules — the old docker one-liner is obsolete).
   NOTE Jon gates standalone tsc runs — report ready and ask before running.
7. Smoke test (template below) against a small real account.
8. Seed: `npx tsx src/cli/seed-aggregators.ts` (host OK).
9. Full provider test run DETACHED:
   `systemd-run --unit=<prov>-test --collect /bin/bash scripts/cron/aggregators.sh <prov>`
   Poll `logs/aggregators-<prov>.log` + job counts. NEVER launch directly from
   MCP (cgroup OOM, rc=137).
10. Verify: country 100% US, sync_runs all ok, field quality (query #5/#6).
    Purge aborted-run remnants if any test got killed:
    `DELETE FROM jobs WHERE provider='<prov>' AND country IS NULL` (only when
    the NULL set matches the killed run's window/count).
11. ~~Update pg_reports code-truth~~ **OBSOLETE** — pg_reports removed
    entirely 2026-07 (`d09c96c8`); there is no coverage VALUES list to update.
    Instead: verify the new provider appears in the SKILL.md funnel-step-1
    fleet query after its first sync.

## B. US-only retrofit for an existing adapter (successfactors/jazzhr pattern)

1. Adapter: drop non-US in `normalize()` (`country !== 'US'` → return null).
   If the adapter does per-job detail fetches, ALSO pre-filter rows that
   already parse to a non-US country before fetching details (jazzhr 2-stage).
2. Smoke test on a mixed/global board — confirm US rows survive, foreign drop.
3. Disable definitively-foreign accounts (data-driven, reversible):
   ```sql
   WITH per_acct AS (
     SELECT ats_account_id,
            count(*) FILTER (WHERE country = 'US') AS us,
            count(*) FILTER (WHERE country IS NOT NULL AND country <> 'US') AS foreign
     FROM jobs WHERE provider = ':prov' GROUP BY ats_account_id)
   UPDATE company_ats_accounts a SET is_active = false, updated_at = now()
   FROM per_acct p WHERE p.ats_account_id = a.id AND a.provider = ':prov'
     AND a.is_active AND p.us = 0 AND p.foreign > 0;
   ```
   (For providers with no NULL-country ambiguity, `p.n > 0 AND p.us = 0` like
   successfactors.)
4. Expire existing non-US rows (sweeper-style; >50K rows → run detached or
   expect MCP timeout then verify):
   ```sql
   UPDATE jobs SET status = 'expired', updated_at = now()
   WHERE provider = ':prov' AND status = 'active'
     AND (country IS NULL OR country <> 'US');
   ```
5. Verify reconciliation: active + expired == previous total; active == prior
   US count.

## C. Pause a provider (jobspy/jsearch/jobicy/snagajob/themuse-legacy pattern)

```sql
UPDATE company_ats_accounts SET is_active = false, updated_at = now()
WHERE provider IN (':p1', ':p2') AND is_active;
```
- `sync-all` filters on `isActive` — takes effect next cron tick, no deploy.
- Reverse: same with `true`. Old jobs stay until sweeper churns them; rows show
  as `orphaned`/disabled in the coverage matrix — that's informational.

## D. Adapter smoke-test template

```bash
cd /opt/stacks/saas-starter/job_feed
cat > /tmp/t.mts << 'TS'
import { <name>Adapter } from '/opt/stacks/saas-starter/job_feed/src/adapters/<file>.js';
const jobs = await <name>Adapter.fetchJobs('<slug>' /*, { config } */);
console.log('jobs:', jobs.length);
for (const j of jobs.slice(0, 5))
  console.log('-', j.title.slice(0, 35), '|', j.locations[0]?.rawText,
    j.locations[0]?.country, '| desc:', j.descriptionText?.length ?? 'NULL',
    '| sal:', j.salary?.min ?? '-');
TS
npx tsx /tmp/t.mts 2>&1 | grep -v '"level"'; rm /tmp/t.mts
```
Must be `.mts`; absolute import path; run from project dir (env). Pick the
account with triage query #8 (small + exhibits the bug). No DB writes happen —
fetch-only.

For incremental-detail adapters, exercise BOTH partitions by passing fake opts
(3rd fetchJobs arg): pass 1 `knownJobs: async () => new Map()` (everything owes
detail — probe/detail paths run), pass 2 a map marking pass-1 ids
`{hasDescription: true, descriptionLength: 5000, postedAt: null, sourceUrl: null}`
(expect listing-only: every description null, near-instant). Capture
`onResolvedConfig: (p) => …` to assert persisted config patches (e.g. phenom's
probed jobPagePrefix). To force detail on ONE known id inside a big board,
subclass Map and override `get`/`has` for that id.

## E. Add a pg_reports report

> **OBSOLETE 2026-07** — the pg_reports Rails sidecar was removed entirely
> (`d09c96c8`): no container, no `:3945` dashboard, no `job_feed/pg_reports/`
> dir. Kept for git-history context only; new diagnostics = direct psql
> (triage-queries.sql). Do not follow the steps below.

Files (all four, or it won't register/render):
1. `pg_reports/custom_reports/sql/adapters/<name>.sql` — anchor on
   `unnest(enum_range(NULL::ats_provider))` with LEFT JOINs when the report
   must show zero-data providers. Wrap in `SELECT * FROM (...) x` to ORDER BY
   computed columns.
2. `pg_reports/custom_reports/definitions/adapters/<name>.yml` — columns list
   must match the SQL exactly.
3. `config/initializers/pg_reports_adapters.rb` — REPORTS entry + REPORT_CONFIG
   thresholds/problem_fields.
4. `config/locales/pg_reports_adapters.en.yml` — what/how/nuances/ai_prompt.
Validate SQL against live DB with `\timing` before wiring. Ruby syntax check:
`docker run --rm -v "$PWD:/app" -w /app ruby:3.3-slim ruby -c <file>`.
Rebuild required (SQL baked into gem at build) — ASK JON. Route:
`/api/admin/pg-reports/adapters/<report>` (port 3945; container-internal 3000).
Heavy-query note: provider aggregates over `jobs` are a ~5.4GB seq scan
(~5-13s warm, 30s+ cold). Optional speedup if it ever matters:
`CREATE INDEX CONCURRENTLY jobs_active_provider_first_seen_idx ON jobs (provider, first_seen_at) WHERE status='active';` (DDL — ask first).

---

## Field-coverage check (run before calling ANY adapter done)

"It returns jobs" hides missing salary / posted_at / location precision. Measure
per-field coverage on a REAL board, and **sample values** — percentages hide
wrong-but-present data (e.g. a department cell that is actually a place name).

```ts
// /tmp/coverage.mts — npx tsx /tmp/coverage.mts  (run from job_feed/)
import { <adapter> } from '/opt/stacks/saas-starter/job_feed/src/adapters/<file>.ts';
const jobs: any[] = await <adapter>.fetchJobs('<slug>', {}, {} as any);
const n = jobs.length, p = (c: number) => `${c}/${n} (${Math.round(100*c/n)}%)`;
console.log('jobs', n);
console.log('title      ', p(jobs.filter(j=>j.title).length));
console.log('description', p(jobs.filter(j=>j.descriptionText).length));
console.log('postedAt   ', p(jobs.filter(j=>j.postedAt).length));
console.log('employment ', p(jobs.filter(j=>j.rawEmploymentType).length));
// SALARY: count REAL figures, never object presence — see the trap below
console.log('salary REAL', p(jobs.filter(j=>j.salary && (j.salary.min!=null||j.salary.max!=null)).length),
            ' noise=', jobs.filter(j=>j.salary && j.salary.min==null && j.salary.max==null).length);
console.log('loc US     ', p(jobs.filter(j=>j.locations?.[0]?.country==='US').length));
console.log('  city     ', p(jobs.filter(j=>j.locations?.[0]?.city).length));
console.log('  region   ', p(jobs.filter(j=>j.locations?.[0]?.region).length));
console.log('department ', p(jobs.filter(j=>j.department).length));
for (const j of jobs.slice(0,5)) console.log('  ', JSON.stringify(j.locations?.[0]), '|', j.title.slice(0,32));
```

### The confident-default trap (cost me a false "100% salary")

`parseSalary` **never returns null**. With no match it returns a fully-populated
object — `{min:null,max:null,currency:null,period:null,hasEquity:false,hasBonus:…}`.
So `!!job.salary` reports **100% coverage when the real figure is 16%**. Always:

```ts
const sal = parseSalary(text);
job.salary = sal && (sal.min != null || sal.max != null) ? sal : null;
```

Applies to any normalizer with confident defaults — count real values, not objects.

**Description flavor of the same trap:** "description present" hides teasers —
a 200–500 char listing snippet counts as present, blocks the job-details-drain
backfill (its gate is "description EMPTY"), and can COALESCE-overwrite full
text on re-arrivals. For any detail-fetching adapter, also check the length
histogram (triage §15c) and see `description-coverage.md`.

### Healthy baseline (taleo TBE, measured 2026-07-25)

| field | coverage | note |
|---|---|---|
| location | **100% US**, 92% city+state | geocoded lat/long |
| description | 100% | from a detail fetch |
| postedAt | 76–100% | tenant-dependent |
| employmentType | 100% | |
| **salary (real)** | **16%** | prose-only; JSON-LD has no `baseSalary` |
| postalCode | 0% | |
| department | 0–94% | tenant configures the column |

### Two gotchas this surfaced

- **Salary often lives only in description prose** ("Pay range: $28.83 to $38.44"),
  not in structured JSON-LD. Parse the description; don't assume the feed has it.
- **A "department" cell can be a place.** ADELPHI renders campus *"Manhattan Center"*
  AND *"New York City"*. Labelling a place as a department is worse than leaving it
  null — drop a leftover cell that itself parses to a US location.

## F. Adapter invariants learned from the Wave 2 builds (dayforce / neogov / frontline / workstream, 2026-09-05/06)

Add these to section A for every new adapter; each one bit us once.

1. **Shape guard, never silent zero.** A 2xx whose body is not the expected shape (non-array,
   HTML where JSON was expected, a large body that parses to 0 postings) throws
   `UpstreamShapeError` (`src/adapters/types.ts`) so the run DEFERS instead of letting
   `markMissingJobs` sweep the board. Count layouts / blank details per run and throw when
   `unknownLayout` or `detailsNoPosting` dominates (neogov: >25% AND ≥20 fetches).
2. **Per-run counters in the `fetched` log line**: listed, us, details, listingOnly,
   noJsonLd, noDate, droppedNonUs (keep "detail fetch failed" SEPARATE from "non-US").
3. **Redirects**: `lib/http.ts` follows none. Walk them yourself, bounded (3), and ONLY within
   the provider's own domain (dayforce `*.dayforcehcm.com`). Check what the 301 actually
   points at — workstream's drops `/positions` and lands on a 5-posting marketing page.
4. **Unitless numeric rates need a period** (`inferRatePeriod`: `<300` hour, `≥5,000` year,
   else null → `parseSalary` fallback gated on min/max). `0/0` = not published. Count real
   min/max, never object presence (the confident-default trap).
5. **Employment type**: when the feed's code is opaque, derive a raw string from the title
   (`employmentTypeFromTitle`), else the classifier defaults EVERY row to full_time.
6. **Company = the operator, not the brand / board / consortium.** Resolve it once per account
   (listing page header, JSON-LD identifier) and persist via `onResolvedConfig`; brand → team.
   Watch for synthetic names (`adp_wfn 79e10f03 …`) — discovery must capture the employer name.
7. **Geography from the ACCOUNT when the feed has none** (frontline): `config.state`/`city`
   resolved at discovery; the adapter never invents a `'US'` token; a board without geography
   returns `[]` + `onPartialFetch` and must never be seeded.
8. **Location strings with a label** (`code - name - City`): the city is the LAST segment,
   the label goes to `department`, the whole string stays `rawText`.
9. **`addressCountry`** may be alpha-3 or a name: defer to `parseLocation` when the two-letter
   fast path finds nothing.
10. **Dedup key**: decide bare-id vs composite `(id|locationId)` from PILOT DATA (multi-location
    postings fan out: dayforce `ReferenceNumber`, workstream `jobDigestKey`), and count
    repeated keys under different locations so a wrong choice is visible.
11. **Aggregator or not**: if the listing walk emits the full id set every run and truncation
    calls `onPartialFetch`, make it a non-aggregator so two-strike removal applies; aggregator
    only when the account cannot own the company (neogov).
12. **Known-jobs re-emit = NULL description**, never the listing snippet (COALESCE invariant);
    date-sorted feeds stop paging on the first all-known page; cap detail fetches per run and
    let later runs finish the backfill (first pass of a 4.5k-board host = days, plan for it).
13. **Discovery classification**: permanent conditions (HTML careers shell on 200, dead 404)
    → `invalid`; only 429/5xx/circuit/timeout/truncated bodies → `deferred`. A fallback that
    fired during validation marks the candidate `duplicate` and upserts the real sibling.
14. **Rollout**: supervise the first full ingest (pinned, `SYNC_CONCURRENCY=2`, watch RSS +
    warnings); then run §17 of triage-queries.sql the next day.
