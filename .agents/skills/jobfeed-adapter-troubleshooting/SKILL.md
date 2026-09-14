---
name: jobfeed-adapter-troubleshooting
description: Diagnose and fix job_feed ATS/aggregator adapter, seed account, and sync pipeline problems fast. Use this skill WHENEVER a task touches /opt/stacks/saas-starter/job_feed — an adapter "broken" or "not returning results", a provider with missing/stale/zero jobs, short/truncated/teaser/snippet descriptions, seeds failing or quarantined, sync_runs errors, gap/coverage/freshness findings, adding a new provider adapter, or pausing/cleaning provider data. Read it BEFORE running diagnostic commands — it encodes environment constraints (OOM caps, MCP timeouts) that make naive approaches fail, and known root causes that look like bugs but aren't.
user-invocable: false
metadata:
  internal: true
---

# job_feed Adapter & Seed Troubleshooting

Battle-tested playbook from June–August 2026 sessions (themuse build, successfactors
and jazzhr fixes, provider pauses, the 2026-07-14 US-coverage audit, the 2026-08-31
short-description fixes: phenom/oracle_cloud/pinpoint). Goal: skip rediscovery, go
straight to fix.

## Ground truth (do not re-derive)

| Thing | Value |
|---|---|
| Project | `/opt/stacks/saas-starter/job_feed` (TS, tsx runtime, drizzle) |
| DB | `docker exec job_feed_postgres psql -U jobfeed -d jobfeed` |
| Key tables | `jobs`, `company_ats_accounts` (the "seeds"), `sync_runs`, `account_quarantine`, `companies` |
| Adapters | `src/adapters/*.ts`; registry `src/adapters/index.ts` (`Record<AtsProvider, AtsAdapter|null>` — must list EVERY value of the TS union) |
| Enum trap | DB enum `ats_provider` has MORE values than the TS union in `src/db/schema.ts`. A provider can exist in DB (accounts, runs, jobs) with no TS representation. Adding an adapter for such a value = add it to the `pgEnum` array first (no migration needed if the value already exists in DB). |
| Pipeline | `src/pipeline/sync-all.ts` (selects `is_active`, concurrency `env.SYNC_CONCURRENCY`), `sync-one.ts` (also provides the lazy `knownJobs` map — `{hasDescription (>50ch), descriptionLength (added 2026-08-31), postedAt, sourceUrl}` — for incremental-detail adapters: smartrecruiters, workday, eightfold, breezy, taleo, hiringcafe, phenom, oracle_cloud skip detail calls for known-enriched jobs; the job is still EMITTED listing-only with a **NULL description** so `markMissingJobs` counts it as seen and upsert's COALESCE preserves the stored text — re-emitting the listing snippet instead OVERWRITES full text, see `references/description-coverage.md`), `status-sweeper.ts` |
| Scheduler | **Windmill** (CE, self-hosted `/opt/stacks/windmill`, UI `127.0.0.1:8085`) fires every cron below — each is a Windmill schedule that execs the *unchanged* `scripts/cron/*.sh`. Source of truth `windmill/jobfeed/catalog.json` (edit → `bun windmill/jobfeed/generate.ts` → push-rest). **NOT** host crontab; **Temporal was decommissioned 2026-06-19.** A `systemd-run` of the same script (Environment rules §2) faithfully reproduces a scheduled run. |
| Cron | ATS: `43 5,11,17,23` via `scripts/cron/ats-sync.sh` (`MAX_ACCOUNTS=4500`/run since 2026-07-14, ordered `last_synced_at ASC` = fair rotation; per-provider quota overrides `ats-sync.sh:84`: greenhouse 750, bamboohr 750, icims 750, lever 500, ashby 500, default 250). Aggregators: `09:13` (`sync-aggregators.ts`, always-on: remotive, themuse; **arbeitnow paused ~2026-07-13** — 0 active accounts, rows cleanly expired, silence is deliberate). Careerjet: `04:13` solo. **Long-tail SMB lane** (adp_wfn/ukg_pro/paycom/paylocity/dayforce): `13 2,14` UTC via `scripts/cron/ats-sync-longtail.sh` (`--providers`, quotas paycom 2500 / paylocity 2000 / adp_wfn 1500 / ukg_pro 800 / dayforce 800, `SYNC_PER_PROVIDER_CONCURRENCY=2` × `SYNC_CONCURRENCY=8`); excluded from the unpinned ats-sync by `LONGTAIL_LANE_PROVIDERS`; log `logs/sync-longtail.log`. Coverage cron `jobfeed-ats-coverage` (`scripts/ats-ingest.ts`): **recruiterbox, mercor ONLY** — rippling promoted 2026-06-12 (commit `01d83e3`); join retired-to-adapter 2026-06-12 (commit `37bb9be`, `src/adapters/join.ts`); gem promoted 2026-06-27 (commit `366beba`, 496 seeded accounts). |
| Long-tail lane knobs | `scripts/cron/ats-sync-longtail.sh` exports: `SYNC_CONCURRENCY=8` + `SYNC_PER_PROVIDER_CONCURRENCY=2` (≤ 2 slots per provider, round-robin rank order when `--providers` is pinned); `SYNC_QUOTA_OVERRIDES` per provider (frontline=2500 = whole roster, neogov=2 = two hosts); `SYNC_SKIP_OVERRIDES="neogov=36000000"`; first-pass detail caps (`PAYCOM_DETAIL_MAX=30`, REMOVE when paycom `never_synced` ≈ 0). **Host floors** (`lib/http.ts minDelayForHost`): workday 1500 · adp 1500 · eightfold 1200 (group-keyed) · www.workstream.us 1600 (429s at 600) · paycom / paylocity **300 DOWNWARD** (canaried 2026-09-06; delete the export on any `rate_limited`/`waf_blocked`). Measured first-pass throughput per 5,000 s run: paylocity ~870 boards, paycom ~580, adp ~130, dayforce ~600, frontline 2,175 (one request each) |
| Single-writer rule | Every provider has exactly ONE writer (pipeline adapter XOR ats-ingest XOR n8n) and ONE account-slug scheme. Before adding/promoting/seeding a provider, read `job_feed/docs/seed-and-adapter-overlap-reference.md` — it has the 5-step promotion playbook (rename lazy synthetic slugs → seed → retire old writer) and the duplicate-account/job traps. |
| Sweeper policy | `missing_syncs >= 2` → removed; `posted_at` older than **12 months** → expired-by-age; manual expiry pattern: `SET status='expired', updated_at=now()` |
| pg_reports | **REMOVED 2026-07 (`d09c96c8` "remove pg_reports Rails sidecar entirely")** — the `job_feed/pg_reports/` dir, its baked report SQL, and the `:3945` dashboard are all gone. Run diagnostics as direct psql (funnel step 1 + `references/triage-queries.sql`); git history preserves the old report SQL if ever needed. |
| account_quarantine cols | `ats_account_id, quarantined_at, reason, unquarantine_at, unquarantined_by` — **there is NO failure_count/attempt counter**; escalation state lives in the timestamps + `company_ats_accounts.missing_syncs`, don't query columns that aren't there. |
| Policy | **US jobs only** (June 2026): every adapter filters `location.country === 'US'` client-side; unverifiable-country postings are dropped. |
| Writer map (US-gate) | Enforcement lives INSIDE each adapter — the shared writers do NOT gate: `scripts/ats-ingest.ts` (`ImportJob` has no country field) and n8n `/api/n8n/jobs/import` → `upsertPgJob` both write `country=NULL` (as of 2026-07-14). Per-adapter filter/country-source/detail-cap status: `references/us-filter-matrix.md`. |

## Environment rules (violating these wastes 10+ minutes each)

1. **Typecheck ON THE HOST**: `cd /opt/stacks/saas-starter/job_feed && npx tsc --noEmit`.
   Clean baseline — **0 errors** (verified 2026-08-11).
   **OBSOLETE (superseded 2026-08-11):** this rule used to say the host OOMs on
   `tsc`/`vite build` and to typecheck via
   `docker run --rm --memory=1g … node:22-bookworm-slim npx tsc --noEmit`, ignoring
   "14 known pre-existing errors". The box is now 20 GB RAM (+20 GB swap, 5 cores),
   so the host runs `tsc` fine — and those 14 errors were **an artifact of that
   container**, not real: `bun:sqlite` cannot resolve under `node:22-bookworm-slim`,
   which is why `embed-backfill` / `embed-seekers` / `seed-occupations` /
   `embed/embedder` / `recovery/stages/browser` appeared to fail. Do not route the
   typecheck through Docker, and do not treat any error as "known pre-existing" —
   the baseline is zero.
2. **MCP-Hub cgroup caps spawned processes at ~460MB RSS** — a full provider
   sync launched from MCP gets SIGKILLed (rc=137, "Memory cgroup out of
   memory" in dmesg, NOT host exhaustion). Launch heavy runs detached:
   `systemd-run --unit=<name> --collect /bin/bash scripts/cron/<script>.sh [args]`
   then poll `logs/*.log` and `systemctl is-active <name>`.
3. **MCP transport hard-times-out ~60s.** Keep every command under ~45s wall
   time. No `sleep` > 30s. Big UPDATEs (>50K rows) either detach or expect the
   timeout and VERIFY state afterward — the statement usually completed
   (post-update slowness = autovacuum + MV refreshes, check `pg_stat_activity`).
4. **Adapter smoke tests**: write a throwaway `.mts` (NOT `.ts` — tsx infers
   CJS outside the project and top-level await fails) in `/tmp`, import the
   adapter by ABSOLUTE path, run `npx tsx /tmp/x.mts` from the project dir
   (env loads from there). Template in `references/checklists.md`.
5. **Ask Jon before any `docker compose build`/`up` or other redeploy.** Code
   edits, lint, psql, one-off syncs are fine without asking.
6. Files created via MCP land root-owned — `chown jon:jon` when done.

7. **`systemd-run --user` units start in `$HOME`.** Pass
   `--working-directory=/opt/stacks/saas-starter/job_feed` (or the repo root for scripts that
   need the app SQLite) — an inline `cd` inside `bash -c` got dropped four times in one session
   and tsx then resolved `/home/jon/src/cli/sync.ts`.
8. **Auto-mode classifier blocks bulk destructive writes** (mass UPDATE/DELETE, `purge --commit`),
   the Windmill token read, and `.env*` edits. Write the SQL to the task's SDD dir with inline
   guards (`\gset` + `\if` + `\quit`) and before/after counts per section, hand the one-liner to
   Jon, move on. Small targeted writes (a 2-account deactivation, seeding) are allowed.
9. **Supervise a provider's FIRST full ingest** (frontline: 2,200 boards / 80k rows / 760 MB in
   one run) as a pinned detached sync with `SYNC_CONCURRENCY=2`, sampling worker RSS and
   warnings, instead of letting the lane tick take it unobserved.

## Triage funnel (in order — stop when cause found)

1. **Fleet health matrix first** (one command, classifies the gap — the old
   `adapter_coverage.sql` report died with pg_reports, this replaces it):
   ```
   docker exec -i job_feed_postgres psql -U jobfeed -d jobfeed <<'SQL'
   SELECT caa.provider, COUNT(*) runs,
          COUNT(*) FILTER (WHERE sr.status='ok') ok,
          COUNT(*) FILTER (WHERE sr.status<>'ok') bad,
          SUM(sr.jobs_found) found, SUM(sr.jobs_new) new,
          to_char(MAX(sr.started_at),'MM-DD HH24:MI') last_run
   FROM sync_runs sr JOIN company_ats_accounts caa ON caa.id=sr.ats_account_id
   WHERE sr.started_at > now()-interval '48 hours'
   GROUP BY 1 ORDER BY runs DESC;
   SQL
   ```
   Read it as: provider missing entirely → check writer type before alarm
   (n8n/ats-ingest providers don't write `sync_runs` — judge them by
   `jobs.created_at` freshness instead); high `bad` → cluster the error
   messages (step 2); healthy-but-stale → rotation math (decision table).
   **TRAP:** a provider absent here can still be perfectly healthy (jobspy,
   recruiterbox, mercor) or deliberately paused (personio, arbeitnow, join —
   all 0 active accounts, rows cleanly expired). Cross-check `ls src/adapters/`
   + active-account counts before declaring anything orphaned.
2. **Standard diagnostics**: run the blocks in `references/triage-queries.sql`
   (account health, error clustering, run history, job quality/country/freshness,
   per-account distribution).
3. **Verify upstream LIVE before patching.** `curl` the actual feed/listing/
   detail URL the adapter hits (jazzhr needs browser UA + `accept: text/html`).
   Many "adapter bugs" are upstream template variants, broken upstream filters,
   or real-but-weird data.
4. Only then read/patch the adapter. Provider quirks: `references/provider-notes.md`.

## Process-level triage (sync looks HUNG, not wrong-data)

The funnel above finds data bugs; a "stuck"/"hung" run needs a PROCESS check instead.

1. **Running?** `ps -eo pid,etime,stat,cmd | grep cli/sync`. Tree:
   `timeout 5400 → flock → tsx → node …/.bin/tsx → ➤ node … src/cli/sync.ts`. The real
   worker is the **deepest `node` child** (large RSS, minutes of CPU); the `…/.bin/tsx`
   parent is just the tsx shim and idles at ~0 CPU — sampling it lies.
2. **Progressing?** Sample the worker pid ~15s apart: CPU
   `awk '{print $14+$15}' /proc/<pid>/stat` (Δ jiffies) · I/O
   `awk '/^rchar/{print $2}' /proc/<pid>/io` (Δ bytes, incl. network reads).
   `+CPU +IO`=working (slow tail) · `+CPU /0 IO`=compute/backoff churn, no fetch progress ·
   `0/0`=parked/stuck. Cross-check: `sync.log` mtime + `max(started_at)` in `sync_runs`
   frozen >10 min across all `SYNC_CONCURRENCY` (8) slots ⇒ stuck, not merely slow.
3. **TRAP — host networking.** The Windmill worker runs `--network=host`, so
   `/proc/<pid>/net/tcp` shows the WHOLE host's sockets (windmill 8085, mattermost 8065,
   postgres, redis…), NOT the worker's — a high count is **not** a connection leak.
4. **Self-heals.** Bounded by `timeout -k 30 5400` (hard SIGTERM) + `--max-wallclock 5000`
   (graceful, but only checked BETWEEN accounts — won't fire if stuck inside one account).
   A hung run self-kills within ~90 min; next cron resumes stalest-first. Force early:
   `kill -TERM <timeout-pid>` or cancel in the Windmill UI. Already-synced accounts commit.
5. **Usual cause:** one oversized tenant monopolizing the detail-fetch tail —
   provider-notes § brassring.

## Decision table — symptom → real cause (all observed, don't re-debate)

| Symptom | Likely cause | Fix |
|---|---|---|
| Sync "HUNG": dashboard flat, `sync.log` frozen mid-run, **0 `sync_runs` completions for >10 min** (worker alive, +CPU / 0 I/O) | One oversized tenant monopolizing the detail-fetch tail (brassring CVS Health = 12,243 URLs); bounded only by the run's `--max-wallclock`/`timeout` — **NOT** a deadlock | Process-level triage (above) to confirm; it self-kills at the run `timeout` (~90 min) & next cron resumes. Durable: per-tenant fetch budget (`MAX_FETCH_MS` in `brassring.ts`) |
| `gap = orphaned: data but no adapter` | Enum value with rows but no TS adapter (jobspy, jsearch…) | Pause accounts or build adapter (checklists); if the provider was fed by ats-ingest, follow the promotion playbook in `job_feed/docs/seed-and-adapter-overlap-reference.md` |
| 0% success, tiny durations, `unknown_error` | "No adapter implemented" throw per run — NOTE: `sync-all` has excluded no-adapter providers at the query since 2026-06-07, so fresh errors of this kind mean a different dispatcher | Same as above — check `started_at` before assuming it's still happening |
| Duplicate accounts for one company / duplicate jobs across accounts | Seed-vs-lazy slug-scheme mismatch (board slug vs synthetic `${provider}-${name}`), or two writers live for one provider | overlap-reference §2/§5 — rename lazy slugs BEFORE seeding; one writer per provider |
| Last sync 1–3 days old, accounts all `ok` | **NOT broken** — rotation math: ~50K active accounts ÷ 18K/day ≈ 2.8-day cycle (p90 staleness was 9.7d on 2026-07-14). Stalest accounts go first next run. | Nothing, or shrink rotation: 45% of active boards had never yielded a US job (triage-queries §11) — prune per `docs/plans/2026-07-14-jobfeed-us-coverage-and-efficiency.md` Task 6 |
| ALL jobs active, `new7d = total` | Fresh onboard, nothing has aged yet | Nothing |
| Mattermost "provider health changed": `WARN greenhouse/ashby/lever starved — stalest account 14d` at ~22:37 CDT, gone on the next tick | NOT starvation. `resurrection` (~22:05 CDT) DELETEs expired `account_quarantine` rows without resetting `consecutive_failures`; `recovery-drain` re-quarantines the still-404 ones ~35 min later; in between they are active+non-quarantined with a 14-30d-old `last_synced_at`. Adapters fine — real stalest is <2d | FIXED 2026-09-02: health_tui `stalest` ignores `consecutive_failures >= 3`; `degraded` gated on 20 runs/3 bad; `jobfeed-provider-health.sh` debounces flags over 2 ticks. If it recurs, check `logs/resurrection.log` + `logs/recovery-drain.log` timestamps first |
| Jobs "disappearing" after a sync | Sweeper `expiredByAge` (posted_at > 12mo — themuse served 2024 postings) or `missing_syncs` churn on capped/shard fetches | Expected behavior |
| 30% of a provider's jobs missing description+posted_at, clustered by account | Second/legacy page template the adapter doesn't parse (jazzhr: no JSON-LD JobPosting, desc in `div.job_description`) | HTML fallback extractor; details in provider-notes |
| One account with 500–1,700 jobs | Often REAL (Ladgov, YourMechanic, franchises). Verify via the tenant's branded page before assuming junk/fallback. | provider-notes § jazzhr |
| `ENOTFOUND *.wdNNN.myworkdayjobs.com` clusters in quarantine | Wrong Workday cluster guess, not dead companies | Batch-fix tenant configs |
| recruitee ~30% failure rate, errors all `GET https://<slug>.recruitee.com/api/offers/ failed: 302 You are being redirected` | Dead/renamed (mostly EU) tenants — the API 302s to a marketing page. NOT an adapter bug: quarantine is catching them (158 accts on 2026-07-24) and the bad runs are its retry cadence. They're 0-US boards anyway. | Nothing urgent. Durable: deactivate persistent 302 accounts (pair with expiring rows, checklists pause pattern) |
| Detail-fetched provider: many NULL `jobs.country` but the primary `job_locations` row HAS a country (iCIMS worst-hit; also workday/brassring/greenhouse/lever) | Enrichment writer `writeEnrichment` (`src/pipeline/job-details/fetch.ts`) wrote `job_locations` but NOT the denormalized `jobs.country` that matching + the US-only filter read; sitemap-only iCIMS carried no listing country → ~225k US rows stayed NULL/invisible | FIXED going forward 2026-06-28 (commit a156efc). Backfill existing per provider: `UPDATE jobs SET country=jl.country FROM job_locations jl WHERE jl.job_id=jobs.id AND jl.is_primary AND jobs.provider='<p>' AND jobs.country IS NULL AND jl.country IS NOT NULL;` (memory `project_jobfeed_enrich_country_denorm`). **Well DRY as of 2026-07-14: 0 recoverable rows across ALL providers — don't re-run this hunt; remaining NULLs lack country in `job_locations` too and need writer/adapter fixes.** |
| NULL-country rows AND `job_locations` ALSO lacks a country | Aborted (killed) run wrote jobs before location denorm, OR genuinely unparseable locations | Purge aborted remnants (`country IS NULL` + timing match); strict US filter handles the rest |
| Adapter "works" (returns jobs) but a field is empty feed-wide — salary/posted_at/description | Never measured per-field coverage. **Trap:** `parseSalary` NEVER returns null — it returns `{min:null,max:null,currency:null,period:null,hasEquity:false,hasBonus:…}` when it finds nothing, so `!!job.salary` reports **100% coverage when the real figure is ~16%** (confident-default masking). Salary also often lives only in description PROSE, not structured JSON-LD | Gate on a real number: `job.salary = sal && (sal.min != null \|\| sal.max != null) ? sal : null`. Run the field-coverage check in `references/checklists.md` before calling an adapter done; count `min/max != null`, never object presence |
| Non-US jobs present | Adapter predates US-only policy | Apply the 3-step US-only retrofit in checklists; current per-adapter filter status in `references/us-filter-matrix.md` |
| Provider ~0% US AND ~100% NULL `jobs.country` (brassring, recruiterbox, mercor, snagajob on 2026-07-14) | The WRITER never writes country — ats-ingest/n8n paths have no country field, or the adapter drops it before `NormalizedJob` | Fix the writer, not the data. Check `references/us-filter-matrix.md` for which writer owns the provider |
| `sync_runs` `SUM(jobs_new)` ≫ rows with `created_at` in the same window (careerjet: 1.0M reported vs 205k created /wk) | Dedupe hard-DELETEs → re-insert treadmill. Two flavors, same signature: cross-provider (aggregators: careerjet 1.0M reported vs 205k created /wk) and within-provider clone requisitions (ATS: oracle_cloud 8.5×, workday 1.6×, icims 1.5× on 2026-08-08 — same canonical_hash, adjacent external_ids; deletions in logs/dedupe-<p>.log reconcile the gap to <0.5%) | Diagnose in minutes: sum `deleted` in logs/dedupe-<provider>.log over the window vs the jobs_new gap — NO snapshot table needed. Durable fix: AGG_PREINSERT_DEDUPE (provider-scoped twins for ATS, cross-provider for aggregators) — see docs/plans/2026-08-08-jobfeed-ingestion-master-plan.md |
| Active jobs on accounts that never sync (deactivated accounts, or aggregator fan-out accounts that no-op) | Nothing increments `missing_syncs` → rows are immortal; the 2026-07-14 `fetchSucceeded` fix only helps accounts that DO sync | **Always pair `is_active=false` (or making an account no-op) with expiring its active rows.** Audit: triage-queries §14 |
| Many rows with SHORT descriptions (~200–500 chars), with or without a trailing "…" | THREE distinct causes (2026-08-31 audit): (a) snippet-only aggregator API — adzuna/jooble/careerjet ship no full text, NOT fixable in the adapter; (b) detail-capable adapter whose listing snippet poisons the pipeline — a non-null snippet on listing-only re-arrivals COALESCE-OVERWRITES stored full text AND blocks the job-details-drain (its gate is "description empty"), phenom/oracle_cloud pattern; (c) adapter reads one field of a multi-field JD (pinpoint). Teasers usually do NOT end "…" (phenom cuts at sentence) — hunt by length histogram, not ellipsis | Full playbook incl. classification, queries, fix state + backfills: `references/description-coverage.md`. phenom/oracle_cloud/pinpoint FIXED 2026-08-31 — check converged before re-diagnosing |
| Long-tail lane run syncs ONE provider only (e.g. 143 adp_wfn) and `accountsSkippedBudget` ≈ everything else | Bulk-seeded boards all carry `last_synced_at` NULL, so oldest-first = physical row order and every `SYNC_CONCURRENCY` slot lands on one shared host (workforcenow.adp.com / recruiting.paylocity.com / paycomonline.net), serialized by PER_HOST_MIN_DELAY_MS | FIXED `cc6f3808` (2026-09-05): `--providers` runs order by per-provider rank (round-robin) and `SYNC_PER_PROVIDER_CONCURRENCY` caps slots per provider. If it recurs: check the lane script still exports it, and count per-adapter lines in `logs/sync-longtail.log` |
| Provider shows **100% salary coverage** but `salary_min_usd` values like 9.00 / 16.50 / 47.74 | The feed ships an unitless rate (dayforce `MinHiringRate`) and the adapter emits `period: null`, which the pipeline treats as ANNUAL — hourly rates stored as $16/yr (19,352 rows, 2026-09-06). Sibling trap: `0/0` = "not published" was counted as listed | Infer the period from magnitude in the adapter (`inferRatePeriod` in dayforce.ts: `< 300` → hour, `≥ 5,000` → year, the middle/0/0 → null → fall through to `parseSalary` gated on min/max). Hunt with `salary_period_raw IS NULL AND salary_max_usd < 300` per provider. Backfill pattern: task-12-backfill.sql §1 |
| Rows with `salary_period_raw='month'` and `salary_min_usd > 300,000` (a $720k custodian) | `parseSalary` accepted a "month" token anywhere in the window (an unrelated "monthly stipend"), AND a bare `$18-19` was shorthand-scaled to 18,000–19,000 and then read as monthly | FIXED `c28c7f0d` + `e38c7104` (2026-09-06): period token must be within 12 chars of the figure, EVERY occurrence is checked, a shorthand-scaled figure is always annual, plausibility guard (month reading > $300k while year reading is 20k–300k → year). Signature query: `salary_period_raw='month' AND salary_min_usd > 300000` |
| A provider's `employment_type` is **100% full_time** | The adapter emits `rawEmploymentType: null` (opaque upstream code) and `normalizeEmploymentType` defaults a missing signal to full_time on INSERT (the on-conflict path keeps the stored value) | Derive a raw string from the TITLE when the feed has none (`employmentTypeFromTitle` in dayforce.ts: part-time / PRN / per diem / seasonal / temporary / intern) — case-sensitive `\bPRN\b`, `\btemp\b` (not "Temperature"), `intern(ship)?` (not "Internal"). 3,325 dayforce rows on 2026-09-06 |
| `job_locations.city` holds a label like `040034 - Wp Latrobe - Latrobe` or `Volvo - Fresno - Fresno` | The feed's location string is `<store code> - <store name> - <city>` (paycom) and the adapter fed the whole thing to `parseLocation`, which kept it as the city | FIXED `b10fb277`: city = the LAST ` - ` segment, the label → `department` (only if empty), whole string stays `rawText`; the re-parse only wins when it resolves a city and agrees with the whole-string country. Hunt: `city ~ ' - '` per provider (17,237 paycom rows) |
| Aggregator-style provider (neogov, workstream) keeps closed postings for ~21 days | `isAggregator()` skips `markMissingJobs` (company is per JOB, not per account), so only the stale-`last_seen` sweeper removes rows | If the adapter's listing walk emits the FULL id set every run and `onPartialFetch` guards truncation, make it a NON-aggregator (two-strike removal) with the account's `company_id` = the resolved operator (workstream, 2026-09-06 decision). Keep aggregator only when the account cannot own the company (neogov: one host, 1,100 agencies) |
| New adapter validates fine but the US gate drops **every** posting | The feed carries NO city/state/country (frontline: `Location:` is a building name) | Geography must come from account `config` resolved at DISCOVERY (frontline: the tenant's landing-page contact address → state/city; NCES LEA directory as fallback); the adapter stamps location from config, treats the feed's string as `rawText`/department, and returns `[]` + `onPartialFetch` for an account without `config.state`. Unresolved candidates must never seed (`hasRequiredGeography` gates in validate-candidates.ts + emit-seeds.ts) |
| Discovery candidates loop as `pending` forever ("deferred" every run) | A PERMANENT upstream condition is classified transient: jobvite tenants serve the HTML careers shell on HTTP 200 (JSON widget off), and "returned non-JSON" was in the transient bucket (a rule written for the bun gzip-truncation bug) | `src/discovery/classify.ts`: a 200 with `content-type: text/html` / `<!doctype html` body and NO interstitial marker (cloudflare / captcha / "Just a moment" / Access Denied) is PERMANENT → `invalid` `no_json_widget`; 429/5xx/circuit/timeout/truncated JSON stay deferred. jobvite: 456/495 resolved that way → STOP discovery there |
| Board fallback (dayforce `[]` → CANDIDATEPORTAL) works in the adapter but the tenant gets a **duplicate account** at seeding | Two candidates (`adcs/104482`, `adcs/CANDIDATEPORTAL`) both resolve to the same live board; twin suppression then SPLITS ownership between them rather than mirroring | Capture `onResolvedConfig` in the validator (`91298bba`): a candidate whose fallback fired is marked `duplicate` and its sibling upserted; emit-seeds carries the same gate. Retiring a duplicate account = deactivate AND expire its rows AND remove it from the seed file (`runSeed` re-activates on update) |
| JSON-LD / avature / any schema.org source yields 0 US jobs on boards that are obviously US | `addressCountry` is an alpha-3 (`USA`) or a name (`United States`); the two-letter fast path returns null and the US gate drops the row | Defer to `parseLocation(rawText)` when the fast path finds nothing (avature `7236f1e4`, jsonld `bf60c72a`) — never a second country table, never a forced `'US'` token; unmappable stays null and is dropped |
| A tenant's 2xx listing parses to ZERO postings while the body is large (frontline West Virginia, 980 postings, 8.5 MB) | Per-tenant layout config changed the posting anchor / description markup; a regex tuned on one board silently matches nothing | Detect layouts explicitly, count them per run (`parsed / pdfOnly / externalOnly / unknownLayout`) and throw `UpstreamShapeError` when a 2xx over ~20 KB yields 0 postings or `unknownLayout` dominates — a zero-jobs "success" would let `markMissingJobs` sweep the board |
| Bulk maintenance UPDATE/DELETE dies on `statement timeout` after a while (purge-dead-jobs passes 1–2) | The only usable index is PARTIAL (`jobs_last_seen_nonactive_idx … WHERE status <> 'active'`) and the planner cannot prove its predicate from a bound `status = ANY($1)` parameter → bitmap scan + sort of the whole cohort per slice | State the partial index's WHERE clause LITERALLY in the query (`9a182dd6`: cost 1,624,393 → 15,388). EXPLAIN any slice query against `pg_indexes … WHERE indexdef ILIKE '%WHERE%'` before scheduling it |
| A provider is absent from a lane run's per-adapter lines | Two different causes: (a) correctly skipped by `--skip-if-recent` (dayforce, synced 11 h ago); (b) the lane-wide skip window is WRONG for that provider (neogov's two host accounts must run every tick) | Compare `last_synced_at` with the window first. Per-provider windows: `SYNC_SKIP_OVERRIDES="neogov=36000000"` (same `a=ms` format as the quota overrides, `3a2ddeb9`) |
| An aggregator lane (careerjet / jobs2careers / hiringcafe / aggregators) reports `rc=1` AFTER its own `aggregator sync done` line, with `Failed query: UPDATE jobs SET status='expired' … last_seen_at < NOW() - make_interval(days => $1)` | NOT the crawl. `sync-aggregators.ts` ran the whole-fleet status sweeper at the tail of EVERY lane, and its `staleLastSeen` UPDATE walked 3.06M rows (no index for `status='active' AND last_seen_at < …`) exposed to the database's `lock_timeout=5s` — SQLSTATE 55P03. Windmill then re-ran the ENTIRE script: 279k jobs re-crawled 3× for `jobsNew: 0` | FIXED 2026-09-08: migration 0072 adds the four backlog indexes; `sync-aggregators.ts` takes `--no-sweep` (passed by `aggregators.sh`, which all four lanes `exec`) and a sweeper failure is now non-fatal; careerjet `retryAttempts` 3→1. GC is owned by the 01:05 `f/jobfeed/status-sweeper` schedule alone. Full diagnosis: `docs/plans/2026-09-08-windmill-lock-contention-failures.md` |
| hiring_cafe: `could not resolve the Next.js buildId from the homepage` daily as `unknown_error`, or `waf_blocked` + quarantined | hiringcafe.com is behind a site-wide Cloudflare managed challenge since 2026-09-02 (global, not our IP; headless stealth Chrome does not clear it; snapshot frozen 2026-08-28). Source is CLOSED, not buggy | Nothing — `b15612fa` makes the 403 surface as `waf_blocked` so quarantine/resurrection own it. Do not build a challenge solver, do not re-diagnose: provider-notes § hiring_cafe |
| ukg_pro: `detail failed; listing-only` … `OpportunityDetail … failed: 302` on EVERY job of a board, listing fine, whole board descriptionless (16 boards / 2,073 rows on `gusea1p01.rec.pro.ukg.net`, 2026-09-07) | The tenant answers listing on the shared cluster host but 302s detail GETs to its VANITY host (`upperline.rec.pro.ukg.net`) with the identical path; `lib/http.ts` follows no redirects | FIXED `2a189274`: adapter fetches detail via `httpGet`, adopts a same-path different-host `*.ukg.net`/`*.ultipro.com` redirect once per sync, retries, persists `config.detailHost` via `onResolvedConfig`. Signature query: ukg boards with 0 rows at `length(description_text) >= 200`; a login/marketing redirect changes the PATH and is never adopted |
| Two (or four) ukg_pro accounts hold the SAME rows — slugs differ only by tenant-code case (`RIV1014RIVCA` / `riv1014rivca`) or by host (cluster `gusea1p01.rec.pro.ukg.net` vs the vanity host) | The key kept the CODE's case (wrongly believed case-sensitive) and discovery minted the board once per host alias; the board GUID (3rd slug segment) is the only tenant identity | FIXED 2026-09-07: whole key lower-cased (`normalizeTenantKey`/`ukgKey`), `isUkgBoardAlias` gates validate-candidates + emit-seeds by GUID, roster de-duped (30 GUIDs / 69 accounts → 30, SQL in `.superpowers/sdd/2026-09-07-ukg-vanity-host/`). Hunt: `SELECT lower(split_part(slug,'/',3)) FROM company_ats_accounts WHERE provider='ukg_pro' AND is_active GROUP BY 1 HAVING count(*)>1`. Seed JSON must equal the active DB slugs — `runSeed` re-activates by exact slug |
| Detail-capable provider with 100%-short accounts, ZERO errors anywhere (phenom circlek/pnc/labcorp…) | Detail URL 30x-redirects (wrong tenant locale prefix) and `httpGetText`/`httpGetJson` THROW on 3xx (`lib/http.ts` follows NO redirects) — adapter's catch → silent snippet fallback | Probe prefixes via `httpGet` (exposes status + `location` header); phenom does this per-sync since 2026-08-31 and persists via `onResolvedConfig`. Pattern: description-coverage.md |

## References

- `references/triage-queries.sql` — copy-paste diagnostic SQL, one block per question (§15 = description coverage, §16 = parity KPIs, **§17 = the 24-hour spot check: per-provider field coverage + a 15-row random sample per provider — run it after ANY adapter ships or changes; it found five defects across 44k rows on 2026-09-06**).
- `references/provider-notes.md` — per-provider mechanics + landmines (successfactors, jazzhr, brassring, themuse, smartrecruiters, phenom, oracle_cloud, pinpoint, recruitee, aggregator shard pattern, workday).
- `references/checklists.md` — new-adapter end-to-end checklist, US-only retrofit, pause/cleanup SQL patterns, smoke-test template (incl. knownJobs/opts testing pattern), field-coverage check.
- `references/description-coverage.md` — **short/truncated-description playbook (2026-08-31)**: snippet-only vs detail-capable classification, the COALESCE-downgrade + drain-gate invariants, knownJobs `descriptionLength` thresholding, the phenom locale-prefix probe, per-provider fix state + the pending oracle_cloud backfill UPDATE. Read when ANY provider's descriptions look short, or before writing/altering a detail-fetching adapter.
- `references/js-to-ts-promotion.md` — **step-by-step checklist for converting a legacy `.js` adapter stub to TypeScript and wiring it into the pipeline**: exact file paths, imports, NormalizedJob fields, external_id preservation rule, slug rename SQL, seed JSON generation, typecheck command, smoke-test template. Compiled from the gem.js → gem.ts session (2026-06-27).
- `references/us-filter-matrix.md` — per-adapter matrix (audited 2026-07-14): country source, US-filter type (server/client/NONE), server-side potential, detail caps, board-country cache, waste notes. Check here FIRST when a provider's US share looks wrong.
- `/opt/stacks/saas-starter/job_feed/docs/adapter-us-coverage-fixes.md` — mechanics of the 2026-07-14 fixes: workday `locationCountry` facet + `boardCountry` cache, oracle facet, the `markMissingJobs`/`fetchSucceeded` immortal-jobs fix, recruitee dual-writer split, snapshot/rollback tables.
- `/opt/stacks/saas-starter/docs/plans/2026-07-14-jobfeed-us-coverage-and-efficiency.md` — the standing improvement program (zero-US prune criteria, treadmill fix, dead-row purge, kalil/pinpoint/NLx source expansion). Check task status before re-diagnosing something it already covers.
- `/opt/stacks/saas-starter/job_feed/docs/seed-and-adapter-overlap-reference.md` — **read before adding/promoting/seeding any provider**: the three ingestion paths and their single-writer assignments, the two account-slug schemes and the duplicate-account trap, external_id format rules for promoted providers (keep the legacy `{provider}-{slug}-{id}` format), the ats-ingest→adapter promotion playbook (rippling case study), and the seed-data inventory (`scripts/ats-seeds/*.csv` vs `src/seed/data/*-companies.json` — regenerate, don't drift).
