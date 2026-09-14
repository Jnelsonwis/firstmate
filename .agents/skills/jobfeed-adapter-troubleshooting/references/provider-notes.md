# Provider mechanics & landmines

Observed/verified June 2026. Trust these over first principles.

## successfactors (SAP RMK)

- Feed: `https://{host}/sitemal.xml` — yes, **"sitemal"**, SAP's real stable
  typo endpoint. One RSS response, whole board, no pagination.
- Host resolution: `config.host` > slug-as-URL > slug-with-dot > `job.{slug}.com`.
- Location: `g:location` ALWAYS trails with a real ISO alpha-2 country —
  `parseSfLocation()` strips trailing postcode, pulls trailing ISO, FORCES it
  onto the parse result (generic `parseLocation` mis-reads "Rudolstadt, DE" as
  Delaware). Never bypass this helper.
- US-only filter lives in `normalize()`: `if (parsedLoc?.country !== 'US') return null;`
- Tenants are global boards: 620 pure-foreign accounts were disabled
  (data-driven: had jobs, zero US). Mixed boards (basf.jobs) stay active and
  rely on the adapter filter.
- Some tenants 404 sitemal (RMK disabled) → adapter returns [] = `ok, 0 jobs`.
  That's expected, not a bug.

## jazzhr (applytojob.com)

- Listing: `https://{slug}.applytojob.com/apply/jobs`, server-rendered table.
  **Rows appear TWICE in the HTML** (desktop+mobile tables) — externalId dedupe
  in `parseListing` makes counts come out right; raw `grep -c row_job_` ÷ 2.
- Edge intermittently serves a ≤20KB JS-shell instead of the listing — needs
  browser UA + `accept: text/html` headers AND the existing retry loop
  (`LISTING_ATTEMPTS`, `SHELL_MAX_BYTES`). Same shell can hit detail pages.
- **TWO detail templates**:
  1. Modern: JSON-LD `JobPosting` (description, datePosted, jobLocation,
     baseSalary). Handled by `enrichFromDetail`.
  2. Legacy (~30% of tenants): JSON-LD is `Organization` only; the ad lives in
     `<div class="job_description">…</div>` terminated by
     `<div id="resumator-job…`. Handled by `enrichFromLegacyHtml` (sets
     `rawPayload.legacyHtmlEnriched = true`; no posted_at exists on this
     template — null is correct).
- Tenant existence check: `https://{slug}.applytojob.com/apply` — REAL tenant
  titles as `<Company> - Career Page`; `/apply/jobs` titles generically for
  everyone, so it does NOT discriminate.
- **Big boards are usually real.** Ladgov (gov-services, slug
  `httpsladgovcomjobopenings` — sloppy but valid subdomain) ~630 jobs,
  YourMechanic ~537, Amada franchise ~1,740. Verify via the branded /apply
  page before declaring junk.
- US-only is TWO-stage in `fetchJobs`: pre-detail drop when listing cell parses
  to a non-US country (saves detail fetches); post-enrichment keep only
  `country === 'US'`. Remote-first boards with no parseable state (botkeeper)
  legitimately drop to 0 — accepted cost.
- 177 definitively-foreign accounts disabled (us=0 AND foreign>0). All-NULL
  -country accounts stay active (cheap; may resolve later).

## brassring (IBM Kenexa / Radancy TalentBrew)

- Two-phase: `sitemap.xml` (recurses sitemap-index children) → every `/job/` URL,
  then fetch each detail page for JSON-LD `JobPosting`. Slug = careers domain;
  `config.sitemapUrl` / `jobUrlPattern` override. Defense primes + big retail/health.
- **Mega-tenant tail = the #1 "ats-sync is hung" cause.** Large tenants explode the
  URL list — CVS Health (`jobs.cvshealth.com`) = **12,243** URLs across 33 child
  sitemaps; Walgreens/Cisco/Intuit also big. At `FETCH_CONCURRENCY=4` + per-host
  politeness, ONE such tenant crawls for an hour+ and monopolizes the whole run: the
  log goes silent (per-URL misses log at `debug`, suppressed), `sync_runs` shows 0
  completions for many minutes, and the run only ends when the `--max-wallclock 5000`
  / `timeout 5400` backstop kills it. Looks wedged; it's just slow-tail starvation.
- **Not all "brassring" accounts are Radancy.** Several are **Phenom People** careers sites
  (detect: `"refNum":"<TENANT>"` in any rendered page). Known: careers.rtx.com=`RAYTGLOBAL`,
  careers.cisco.com=`CISCISGLOBAL`, jobs.cvshealth.com=`CVSCHLUS`.
- **Phenom sidecar (opt-in, `config.phenomTenant`)**, added 2026-07-26. `content-ir.phenompeople.com`
  is keyless and un-gated BUT **cannot paginate**: `from`/`offset`/`pageNumber`/`keywords`/
  `selected_fields` are ALL ignored and `size` caps at 500, so it can never enumerate a board —
  the sitemap stays authoritative. Use it only as a lookup: skip all-foreign pages before
  fetching, add businessUnit/locationType/experienceLevel/geo. **Trap:** the flat
  `country`/`city`/`state` describe only the PRIMARY location — skipping on them loses
  multi-location US postings (cost 2 real cisco jobs in testing); read `multi_location`.
- `waf_blocked` 403s on a careers-site sitemap are **intermittent Cloudflare reputation, not UA** —
  the same URL fetches fine on demand with our own client. The lever is fewer page fetches.
- careers.rtx.com is 0-jobs / 9×waf_blocked AND duplicates workday `globalhr/rec_rtx_ext_gateway`
  (job ids match); jobs.cvshealth.com duplicates workday `cvshealth/CVS_Health_Careers`.
- JSON-LD `occupationalCategory` is the ONLY department signal these pages carry (every account
  sat at 0% department coverage before 2026-07-26; cisco measures 93% from it).
- Full writeup: `job_feed/docs/brassring-phenom-sidecar-2026-07-26.md`.
- Diagnose via **Process-level triage** in SKILL.md — the worker shows **+CPU / 0
  network I/O** (compute/backoff churn on the tail), which rules out a deadlock.
- **Fix (2026-06-20):** `MAX_FETCH_MS` per-tenant wall-clock budget on the detail-fetch
  phase in `brassring.ts`. Once hit, remaining URLs are skipped (logged `WARN … partial`)
  and roll to the next sync (sitemap is re-read every run → no data loss). `MAX_JOBS=10000`
  stays as the hard URL ceiling.

## themuse (aggregator)

- API: `https://www.themuse.com/api/public/jobs?page=N&category=<exact name>`.
  Keyless 500 req/hr (3600 w/ key — not needed). `page_count` in response.
- Whole feed ~500K jobs — UNFETCHABLE. Model: one account per **category
  shard**, `config: { category, level?, maxPages? }`, default cap 25 pages
  (=500 jobs scanned/account/sync). 12 shard accounts seeded
  (`themuse-cat-*` in `seed-aggregators.ts`).
- **No date sort exists** (`descending` does not order by publication_date) —
  capped pages take an arbitrary stable-ish slice; churn via missing_syncs is
  by design.
- **Server-side location filter is BROKEN upstream** (`location=United States`
  returns Auckland/Hyderabad). US filter is client-side: keep locations parsing
  to US; remote-only-no-US-location postings dropped.
- Category names must match Muse taxonomy EXACTLY — validate with a 1-page
  fetch (`total > 1`). Known-bad: "Marketing" (use category list in
  seed-aggregators), "Nurses".
- Sweeper age policy bites here: Muse serves postings from 2024 → ~23% of a
  first crawl gets `expiredByAge` immediately. Expected.

## smartrecruiters

- **Incremental detail fetch (2026-07-19, the "dominos margin" fix).** dominos is
  ~24.4k US postings; per-job detail calls took ~80 min/sync and defined the
  ats-sync 7200s timeout risk. The listing payload has NO usable change signal
  (no `updatedOn`; `releasedDate` is re-release churn — 72% of dominos actives
  show posted_at < 14d). Rule: a known ACTIVE job whose stored row already has a
  description is emitted **listing-only** — `upsert.ts` COALESCE-preserves its
  description/salary, and `markMissingJobs` still counts it as seen because it
  IS emitted. Only unknown/description-less postings pay the detail call.
- Plumbing: `AdapterFetchOpts.knownJobs` (lazy `Map<external_id, {hasDescription,
  postedAt}>`, built in `sync-one.ts` only when the adapter calls it).
- Accepted trade-off: a silently edited ad body won't refresh while the posting
  keeps its id; the 12-month age sweep bounds staleness.
- Landmine: adding another incremental adapter? The job MUST still be emitted,
  or `markMissingJobs` will churn it through missing_syncs removal.

## phenom (customer-domain CXM sites)

- Listing: `POST https://{host}/widgets` (`ddoKey: refineSearch`) — carries only a
  `descriptionTeaser` (~200–460 chars, truncated at a SENTENCE boundary, so no "…"
  to grep for). Full text = job page's JSON-LD JobPosting.
- **Job-page locale prefix varies per tenant** and the wrong one 302s to the site
  home — which `httpGetText` turns into a silent throw→teaser-fallback, i.e.
  100%-teaser accounts with zero errors (circlek/pnc/labcorp/usbank/dhl/baesystems
  were `/global/en/job/`; omers `/ca/en/job/`; default `/us/en/job/`). Since
  2026-08-31 the adapter probes candidates on real job ids (302 `location` header +
  `"locale":"en_xx"` HTML stamps yield candidates) and persists the winner via
  `onResolvedConfig` → `config.jobPagePrefix`.
- Incremental detail via `knownJobs.descriptionLength >= 600` (fleet bimodal:
  teasers ≤462 / full ≥644); DETAIL_MAX=300/account/sync; known-full rows re-emit
  LISTING-ONLY with null description. Full mechanics + backfill state:
  `description-coverage.md`.
- brassring overlap: several "brassring" accounts are really Phenom sites
  (careers.rtx.com, jobs.cvshealth.com — see brassring section); the `phenom`
  provider is the standalone adapter for tenants seeded directly.

## oracle_cloud

- Listing carries `ShortDescriptionStr` (a real 1–500 char blurb, NOT a truncation);
  full text = per-job `recruitingCEJobRequisitionDetails` call, capped
  `ORACLE_DETAIL_MAX=40`/sync. Before 2026-08-31 the blurb was the listing-only
  fallback → it (a) blocked the job-details-drain backfill (gate = "description
  empty") and (b) COALESCE-overwrote full text when enriched rows rotated out of
  the newest-40 window — 54k blurb-locked rows (egud 99.5%, jpmc 98% short).
- Fixed: blurb only when a detail was actually fetched; `knownJobs` partition
  spends the 40-budget on un-described rows; listing-only rows emit null desc so
  the drain (which owns oracle via `shouldEnqueueDetail`) backfills new arrivals.
- Old blurb rows: one-time NULLing UPDATE **executed 2026-08-31** (57,979 rows —
  template in `description-coverage.md`); they backfill via the job-details-drain
  as their accounts re-arrive in rotation. Convergence check: triage §15a/§15d.
- Diagnosis marker: `rawPayload = {list, detail}`, overwritten every sync —
  `raw_payload->>'detail' IS NULL` = last arrival was listing-only (131k of 145k
  rows on 2026-08-31; among detail-fetched rows only ~100 are genuinely short).

## pinpoint

- ONE `postings.json` call, no detail fetches — but the JD is split across FOUR
  fields: `description` (often a ~300-char intro) + `key_responsibilities` +
  `skills_knowledge_expertise` + `benefits`. Adapter composes all four with `<h3>`
  headers since 2026-08-31 (1,326 of 1,332 short rows had the meat sitting unused
  in `raw_payload`). Self-heals: desc always emitted → COALESCE overwrites every
  active row within one rotation. `hooli` is a TEST board ("Test Job" rows) —
  never smoke against it.
- No posted-date field exists (only `deadline_at`) → rows never age out by the
  12-month rule; they rely on missing_syncs.

## recruitee

- **Dead-tenant 302 churn is normal, not an adapter bug.** Dead/renamed tenants
  (mostly EU — recruitee is a Dutch ATS) 302-redirect `https://<slug>.recruitee.com/api/offers/`
  to a marketing page. The adapter correctly treats that as failure; quarantine
  catches repeats (158 accounts quarantined as of 2026-07-24) and the ~30% "bad
  run" rate is just quarantine's retry cadence on those accounts. They yield 0
  US jobs anyway. Durable cleanup: deactivate persistent 302 accounts AND expire
  their rows (pause pattern in checklists).
- Dual-writer split (2026-07-14): pipeline adapter owns seeded board accounts;
  the industry-coverage ingest owns its own accounts — see
  `docs/adapter-us-coverage-fixes.md` before touching either.

## hiring_cafe (hiringcafe.com — DEAD since 2026-09-02, quarantined by design)

- **State (verified 2026-09-06):** Cloudflare managed challenge (`cf-mitigated: challenge`,
  `cType: 'managed'`, "Just a moment...") on EVERY route — `/`, `/recently-posted-jobs`,
  `/_next/data/*`, `/job/*`, `/sitemap.xml`, `/api/*`, `www.`/`api.` hosts. Only `robots.txt`
  is exempt. `hiring.cafe` 308s to `hiringcafe.com`. The block is GLOBAL, not our IP (a second,
  unrelated egress gets the same 403). Headless Chrome via browserless (`/function`, stealth,
  30 s wait) never clears it — no `cf_clearance` cookie. The daily static snapshot had already
  frozen on 2026-08-28 (`manifest.generatedAt`) before the challenge landed. Third breakage
  after the keyword-route 403 (2026-08-29) and the empty `/_next/data` twin. Do NOT build a
  challenge solver; the source is closed to non-browser clients.
- **Symptom you'll see:** `sync_runs.error_message = "hiringcafe: could not resolve the Next.js
  buildId from the homepage"` as `unknown_error` (pre-`b15612fa`) — the adapter swallowed the
  homepage 403 into null. Fixed `b15612fa`: non-200 homepage throws `HttpError` (message carries
  the `cf-mitigated` header) → sync-one `waf_blocked` → single-failure fast-track to
  recovery/quarantine. Expected steady state: `last_status='waf_blocked'`, one
  `account_quarantine` row for `hc-recently-posted`, resurrection re-probes it (one request)
  and re-quarantines while the challenge stands. Nothing to do unless the probe starts passing.
- **Rows:** 9,898 active `hiring_cafe` jobs on 2026-09-06 age out via the 21-day stale
  `last_seen_at` sweep (aggregator ⇒ no `markMissingJobs`). Its `raw_payload`
  (`source`/`board_token`) is still mined by `scripts/discovery/import-hiringcafe-payloads`.
- **Account model reminder:** ONE designated account (`config.feed='recently-posted'`); the 11
  legacy keyword shards are `is_active=false`. `CONFIG_REQUIRED_AGGREGATORS` keeps the provider
  out of ats-sync; cron `scripts/cron/hiringcafe.sh` (Windmill `hiringcafe`, 08:13 UTC).

## aggregator pattern (general)

- One logical account per source/shard; `config` jsonb drives the adapter
  (keywords for jooble/careerjet, category for themuse).
- **Snippet-only APIs — descriptions are structurally short, do NOT "fix" the
  adapter:** careerjet (avg ~204 chars), jooble (~279), adzuna (hard 500-char
  cut ending "…"). Full text sits behind click/affiliate redirect URLs;
  mass-following them fakes paid ad clicks (ToS) and means scraping arbitrary
  employer sites. See `description-coverage.md` step 0.
- `isAggregator()` in `src/adapters/index.ts` must include the provider.
- Always-on list in `src/cli/sync-aggregators.ts`; careerjet is opt-in only
  (slow), runs solo at 04:13.
- Jobs carry `companyHint` → `upsert-aggregator` resolves/creates companies.

## workday

- Quarantine clusters of `getaddrinfo ENOTFOUND {tenant}.wdNNN.myworkdayjobs.com`
  = wrong cluster number guess (wd1/wd3/wd5/wd101…), not dead companies.
  Batch-fix the tenant configs; do not mass-disable.
- **TWO country-facet schemas.** A board serves exactly one, and the applied-facet
  key is NOT interchangeable (posting the wrong one to 3m = HTTP 400):
  A) nested `locationMainGroup` → `locationCountry` ("Location Country / Region"), lilly.wd115
  B) flat top-level `Location_Country` ("Geography/Country"), 3m.wd1
  Always take the key from the facet the board advertised. Handling only A made
  schema-B boards look facet-less → classified single-country → one detail payload
  decided the whole board (3m: 669 postings / 312 US, first witness Chennai ⇒ cached
  `NON_US` and skipped forever; 1,386 accounts cached that way, 443 with US jobs).
  Fixed 2026-07-26; `config.boardCountryVersion` expires stale verdicts automatically.
- **`limit` is hard-capped at 20** — 21+ returns HTTP 400. The reverse-engineering
  notes in `job_feed/docs/workday/` claim ~100; they are wrong. `POST …/facets/jobs/{type}`
  is 405, also wrong. CSRF cookie really is `CALYPSO_CSRF_TOKEN` (the notes are right there).
- Country evidence: `jobPostingInfo.country` = `{descriptor, id}` only, but
  `jobPostingInfo.jobRequisitionLocation.country.alpha2Code` IS a real ISO code.
  Listings carry `timeType` (employment type without a detail call).
- Detail budget is incremental since 2026-07-26 (`knownJobs`, like smartrecruiters):
  `WORKDAY_DETAIL_MAX` caps NEW enrichments per run, not the first N postings.
  Boards >6,000 postings resume from `config.listingCursor` and flag the run partial.
- Full writeup: `job_feed/docs/workday-cxs-hardening-2026-07-26.md`.

## dayforce (spike 2026-09-04; adapter SHIPPED 2026-09-05 — `src/adapters/dayforce.ts`, `048e0618` + `358238f9`)

- **Adapter facts (2026-09-05):** one `JobFeeds` call per board, no detail stage
  (`listingOnly`/`knownJobs` are no-ops); `www.dayforcehcm.com` 302s to the tenant's cluster
  host and `lib/http.ts` follows nothing, so the adapter walks the hop itself — **only within
  `*.dayforcehcm.com`** (off-domain → `UpstreamShapeError`); non-array 200 →
  `UpstreamShapeError`; `[]` on a non-CANDIDATEPORTAL board → one retry on `CANDIDATEPORTAL`,
  persisted via `onResolvedConfig({ boardCode })`; `externalId` = `ReferenceNumber|city|state`
  lower-cased with same-response dedupe (1,002 → 889 on visionworks); US gate accepts
  `US`/`USA`/`United States`, absent `Country` survives only if `parseLocation` itself resolves
  US from the state. Pilot: 43 boards / 5,615 jobs / 100% US, posted, desc>200 / 51% salary;
  7 invalid = 3 zero-yield, 2 HTTP 400 (JobFeeds client property off), 2 HTTP 403 (tenant IP
  allowlist, not our host). **Traps:** every sync's first hop serializes on the shared
  `www.dayforcehcm.com` at PER_HOST_MIN_DELAY_MS — ~7 min of hops per lane run at the 2026-09-05
  roster of 659 accounts, and the scaling wall for this provider.

- **Fallback duplicates — FIXED 2026-09-05 (`91298bba`).** A non-CANDIDATEPORTAL board that falls
  back used to be seeded as a second account mirroring its sibling. `validate-candidates.ts` now
  records the adapter's `onResolvedConfig` patch and marks such a candidate `duplicate`, upserting
  a `<tenant>/CANDIDATEPORTAL` sibling instead; `emit-seeds.ts` carries the same gate for rows
  validated earlier. Helpers live in `src/discovery/candidates.ts`
  (`dayforceFallbackSibling`, `isDayforceFallbackDuplicate`). `adcs/104482` and
  `chromalloy/116842` were retired the same day.
  **Retirement trap:** `runSeed`'s upsert sets `is_active=true`, so a retired slug must ALSO be
  deleted from its seed file or the next seed run resurrects it. And because `upsert.ts` (Task 12)
  suppresses inserts that have an active `canonical_hash` twin, two accounts on one feed SPLIT
  ownership rather than mirror — retiring one needs a pinned sync of the survivor to reclaim its
  rows, or the tenant visibly dips.

- Feed: `GET https://www.dayforcehcm.com/api/{tenant}/V1/JobFeeds?includeActivePostingOnly=true&internalJobBoardCode={BOARD}`
  — public, keyless, no auth header; just a browser UA + `accept: application/json`.
  Whole-board single call, no pagination, full JD inline (no detail fetch).
  **Confirmed case-insensitive** on both `{tenant}` and `{BOARD}`
  (`GBANK`==`gbank`, `CANDIDATEPORTAL`==`candidateportal`) — casing is not the
  landmine here.
- Slug scheme confirmed `<tenant>/<BOARD>` (matches `ats_tenant_candidates.tenant_key`).
  The public portal (`https://jobs.dayforcehcm.com/en-US/<tenant>/<BOARD>`) is a
  client-rendered SPA — raw HTML carries no JSON endpoint refs (only a static
  `/api/js` bundle path), so it is NOT a usable discovery fallback. The
  `V1/JobFeeds` call above is the only integration point; it worked on the first
  try for all 5 tenants sampled, so the portal-XHR fallback in the brief was
  never needed.
- **Response is a bare JSON array** (not `{jobs:[...]}`); `content-type:
  application/json` on every response seen, including `[]` and the 400 below.
  `[]` on a tenant/board with zero current openings is a valid 200, not a
  failure. All 5 sampled tenants (gbank, acadia, visionworks, hillman, mcr)
  returned HTTP 200 arrays on this exact URL — the 2026-09-02 controller
  probe's "non-array for 15 tenants" was NOT reproduced here and is more
  likely a handful of bad tenant/board slugs or an unthrottled-burst block
  than a wrong URL shape. Wave 2 should re-probe those 15 with ≥1s spacing
  and this header set before concluding the endpoint doesn't work for them.
- **The `internalJobBoardCode` recorded in `ats_tenant_candidates` is not
  always the board with jobs on it.** `mcr/APPCASTJOBBOARD` (the recorded
  candidate) returns `[]`; the same tenant's `CANDIDATEPORTAL` board returns
  456 live postings. Codes like `APPCASTJOBBOARD` read as syndication-partner
  feed labels that can sit empty while the tenant's own career-site board is
  active. **Always retry with `CANDIDATEPORTAL` when the recorded board comes
  back empty**, before marking a candidate dead — 2 of the 5 tenants here
  (hillman, mcr) would have looked like 0-yield without this fallback,
  and one of those two (mcr) was actually the single biggest tenant tested.
- `includeActivePostingOnly=false` is not a "show everything" toggle — it
  400s with `{code:"JOBFEED_QUERY_PARAMETER_NOT_FOUND", message:"...'Last
  Update Time From' and/or 'Last Update Time To'..."}` unless paired with
  those two params. Not needed (adapter only wants active postings); noted
  so nobody burns a call chasing a richer response.
- **Field set is tenant-configurable, not fixed** — 3 different key sets
  across the 3 tenants that had data:
  - Always present: `Title`, `Description`, `ClientSiteName`,
    `ClientSiteXRefCode` (echoes the board code — useful cross-check),
    `JobDetailsUrl`, `ApplyUrl`, `DatePosted`, `LastUpdated`,
    `ReferenceNumber`, `CultureCode`, `ParentRequisitionCode`, `JobType`,
    `TravelRequired`, `IsVirtualLocation` (all int/bool codes here are
    opaque — no lookup table found in this spike, treat as raw passthrough).
  - Sometimes present — **feature-detect, never assume**: `City`/`State`/
    `Country`/`PostalCode`/`AddressLine1`/`AddressLine2` are ABSENT (not
    just empty) on gbank's records; present on acadia and mcr; present on
    1,000/1,002 visionworks rows but absent on that same tenant's 2
    corporate/remote postings. `CompanyName`/`ParentCompanyName`
    (acadia, visionworks). `JobFamily`/`JobFunction` (visionworks only, in
    place of a location breakdown on some rows). `MinHiringRate`/
    `MaxHiringRate` (visionworks only — real salary-range field when
    present, worth mapping). `Education` (visionworks only).
  - `Description` sampled as **plain text with literal `\n` breaks, not
    HTML** — true on gbank (short boilerplate) and visionworks (full
    multi-paragraph JD). No HTML-stripping step looked necessary, but
    reconfirm across more Wave 2 tenants since the schema is per-client.
  - `DatePosted`/`LastUpdated` are naive datetime strings with no UTC
    offset (`2026-07-23T00:00:00` / `2026-07-23T00:12:13.123`) — parseable
    as ISO-8601 but the timezone is unconfirmed in this spike.
- **`Country` is free text, not a normalized enum — and inconsistent WITHIN
  a single tenant's own feed.** visionworks' 1,002 rows split `US` (247) /
  `USA` (753) / absent (2) in the SAME response; acadia used `USA` only
  (plus 15 `GB` rows); gbank used `US` only. Route it through the existing
  location normalizer's country mapper (accept both `US` and `USA`) —
  don't treat it as a reliable ISO2/ISO3 discriminator by itself.
- **`ReferenceNumber` (the id in `JobDetailsUrl`/`ApplyUrl`) is NOT unique
  per record.** A multi-location requisition emits one record per location
  sharing the same `ReferenceNumber` — visionworks: 768 distinct values
  across 1,002 records (83 values reused, one seen twice with two different
  cities). `JobDetailsUrl` collapses to the exact same 768, so using either
  alone as `external_id` silently drops real per-location postings.
  Composing `ReferenceNumber + City + State` gets to 893/1,002 unique
  (the residual collisions look like genuine exact duplicates, not a
  key-choice bug).
- Per-tenant yield (2026-09-04 probe, `includeActivePostingOnly=true`,
  22 total requests spaced ≥1.1s apart, no throttling/blocking seen):

  | tenant | board queried | jobs | US share |
  |---|---|---|---|
  | gbank | CANDIDATEPORTAL | 5 | 4/5 |
  | acadia | CANDIDATEPORTAL | 62 | 47/62 (rest `GB`) |
  | visionworks | CANDIDATEPORTAL | 1,002 | 1,000/1,002 |
  | hillman | CANDIDATEPORTAL (recorded) | 0 | n/a — confirmed genuinely 0 open reqs via the portal page, not an adapter bug |
  | mcr | APPCASTJOBBOARD (recorded) | 0 | n/a — see board-fallback trap above |
  | mcr | CANDIDATEPORTAL (fallback) | 456 | 454/456 |

  Combined using the `CANDIDATEPORTAL` fallback for mcr: **1,525 jobs across
  5 tenants, ~98.8% US** — comparable yield density to jazzhr/successfactors,
  not a thin source. Wave 2 sizing should assume the board-fallback trap
  recovers a meaningful share of candidates that would otherwise validate
  as zero-yield.
- Scratchpad probes (throwaway, not kept):
  `.superpowers/sdd/2026-09-03-jobfeed-longtail-wave1-adapters/task-5-report.md`
  has the full request-by-request log.

## neogov (spike 2026-09-05, no adapter yet — Wave 2)

**Verdict: GO, but build it as a SINGLE-BOARD aggregator crawl, not ~1,100 per-tenant
accounts.** governmentjobs.com exposes a global, agency-less job feed that already contains
every tenant's postings, so the tenant-enumeration problem the parity plan worried about
(§4 row 2: "robots blocks Common Crawl → discovery from apply URLs") **does not need to be
solved at all**. Two accounts cover the whole platform: `www.governmentjobs.com` (public
sector) and `www.schooljobs.com` (K-12, same app, same routes, separate host).

**Sizing correction — the plan's `50–150k` estimate is ~3.5× too high.** Measured live
inventory 2026-09-05: **33,983** jobs on governmentjobs.com + **8,808** on schooljobs.com =
**42,791**, essentially 100% US. Still worth having (public-sector breadth, full JDs, real
salary ranges on most rows), but size Wave 2 against ~43k, not 150k.

### Endpoints verified (all keyless, no cookie, no session)

The ONLY load-bearing header is **`x-requested-with: XMLHttpRequest`**. Verified: with it and
*nothing else* (no UA, no referer, no cookie jar) every endpoint below returns the data
fragment. Without it, `home/index` returns the 199 KB client-rendered SPA shell with **zero
jobs in the HTML** — which is why the July-2026 "no public feed" ruling happened, and why the
plan recorded this as "per-agency page client-rendered; find the XHR".

- **Global list (recommended integration point):**
  `GET https://www.governmentjobs.com/jobs?page={n}` — and for an incremental lane
  `&sort=date&isDescendingSort=True`. Returns an HTML fragment (not JSON).
  Total in `<span id="jobs-found">…33983 jobs found…`; items are
  `<li class="job-item" data-job-id="{id}-{src}">` carrying title, `div.job-organization`
  (employer name), `span.job-location` (`City, ST`), and one line of
  `type | salary text | closes-in`. **No description, no tenant slug, no absolute posted
  date** — a detail fetch is mandatory per job.
  Deep pagination is uncapped: page 3399 (the last) returned 3 items, HTTP 200.
- **Per-tenant list:** `GET https://www.governmentjobs.com/careers/home/index?agency={slug}&page={n}`
  Total in `<span id="job-postings-number">`; items are `<li class="list-item" data-job-id="{id}">`
  with `href="/careers/{slug}/jobs/{id}/{title-slug}"`, location, employment type, salary text,
  category, department, a **truncated** description teaser, and a **relative** posted date
  ("Posted more than 30 days ago") plus a closing label ("Continuous").
  Past the last page: HTTP 200, ~1 KB fragment, 0 items — a clean terminator.
- **Detail (the good one):**
  `GET https://www.governmentjobs.com/careers/jobInfo/agencyJobDetails/{jobId}`
  → 26–77 KB HTML fragment whose **first element is a `<script type="application/ld+json">`
  schema.org `JobPosting`**. Works cross-tenant with no agency context, no cookie, no prior
  `/careers/{slug}` visit. Prefer it over the public page
  `/careers/{slug}/jobs/{id}/{title-slug}` (231 KB for the same JSON-LD, ~4× the bytes).
- **`{slug}` is case-insensitive** — `VanceCounty` and `vancecounty` both returned 38.
- **K-12 tenants 301 to schooljobs.com with the path preserved**:
  `/careers/home/index?agency=seattleschools&page=1` → `https://www.schooljobs.com/careers/home/index?agency=seattleschools&page=1`
  (96 jobs). Same fragment shape, same detail route, same global `/jobs?page=` feed.
- Dead ends (don't re-probe): `sitemap.xml` per tenant → 404 HTML; `?format=json` → ignored;
  `pageSize` / `size` / `pagesize` → all ignored, **10/page is hard-fixed server-side**;
  `/careers/home/index` without `agency` → 302 `/Error/NotFound`;
  `/careers/home/loadJobsOnMaps?agency=sc&page=1` → HTTP 500 (the search bundle shows it
  returns real JSON `{success, isMapSearchEnable, jobList[...]}` when the agency has map
  search on — **unexplored, and the only known route to a JSON response**; worth one probe
  on a map-enabled agency before committing to HTML parsing).

### Field map → `NormalizedJob` (from the JSON-LD; 6/6 samples had the identical key set)

Keys, always present: `@context @type title description datePosted employmentType
directApply hiringOrganization jobLocation baseSalary`. **`validThrough` is never emitted.**

| NormalizedJob | source | notes / casing |
|---|---|---|
| `title` | `title` | agency house style, frequently ALL CAPS (`SPEECH PATHOLOGIST 2`) — needs the title canonicalizer |
| `description` | `description` | **HTML-escaped inside the JSON string**; unescape then keep as HTML. 2,365–26,363 chars across 5 tenants, median ~13k. Never a teaser. |
| `postedAt` | `datePosted` | `YYYY-MM-DD`, date only, no time, no offset |
| `employmentType` | `employmentType` | schema.org enum but **low quality: `OTHER` on 3 of 6 samples**; `FULL_TIME`/`PART_TIME` otherwise. Fall back to the listing's `Full Time`/`Part-Time` text or the classifier. |
| `locations[].country` | `jobLocation.address.addressCountry` | `"US"` on 6/6 — a real field, not inferred |
| `locations[].region` | `addressRegion` | clean 2-letter state on 6/6 |
| `locations[].city` | `addressLocality` | **dirty free text, do not trust**: `Nevada`, `Williamsburg County`, `CITY OF LOS ANGELES`, `Oahu, HI`, `Medford, OR`, `Dobson, NC` — state suffixes, county names, agency names, random casing. Prefer `postalCode` (present 6/6) → ZIP lookup, or the global feed's `span.job-location` which is a clean `City, ST`. |
| `salary*` | `baseSalary.value.{minValue,maxValue,unitText}` + `.currency` | `USD`; **`unitText` varies — `YEAR` and `MONTH` both observed** (`HOUR` and `SEMI_MONTHLY` appear in the page's own salary popover), so period normalization is mandatory. |
| `companyName` | `hiringOrganization.name` | `State of Nevada (NV)`, `City of Medford (Oregon)` — parenthetical suffixes are common; `sameAs`/`logo` can be empty strings. |
| `applyUrl` | build | `https://www.governmentjobs.com/careers/{slug}/jobs/{id}` (tenant route) or `https://www.governmentjobs.com/jobs/{id}-{src}/{title-slug}` (global route) |

Closing date is **not** in the JSON-LD. It lives in the fragment HTML as a `Closing Date`
term block, value `Continuous` or a date — parse it only if `valid_through` is wanted.

### Dedup key

`external_id` = **`{jobId}-{src}`, the literal `data-job-id` from the global feed** (e.g.
`5329390-0`, `98681-1`). Ids are a **single global ascending sequence, not per-tenant** — the
same `5269701` is `/careers/nv/jobs/5269701` and `/jobs/5269701-0/…`. The `-{src}` suffix is a
**source discriminator** (`data-job-source`), and `-1` is a *different id space*: ids there are
5-digit (`98681`, `21561`) and would collide with nothing today but will collide with the `-0`
space eventually. Never key on the bare integer. `Job Number` in the detail fragment
(`2026-01057`, `5885 O 2022/03/11 C`) is the agency's own req number and is not unique.

### Per-tenant yield (2026-09-05, one request each, cookieless)

| tenant | kind | jobs | notes |
|---|---|---|---|
| `sc` | state | 1,125 | State of South Carolina; 113 pages |
| `nv` | state | 356 | State of Nevada |
| `seattleschools` | school district | 96 | **301s to schooljobs.com** |
| `honolulu` | city+county | 68 | |
| `lacity` | big city | 52 | far smaller than expected for LA |
| `VanceCounty` | county | 38 | identical to `vancecounty` (case-insensitive) |
| `medfordor` | small town | 6 | |
| **global `/jobs`** | **all agencies** | **33,983** | includes every tenant above (verified: nv's `5269701` appears as `/jobs/5269701-0/…`) |
| **global schooljobs `/jobs`** | **all K-12** | **8,808** | |

US share is effectively 100% by construction (US public employers) and `addressCountry` was
`US` on 6/6 detail samples, so the June-2026 US gate costs nothing here.

### Traps

1. **The whole platform is ONE host, and detail is one request per job.** A full sweep is
   3,399 list + 33,983 detail = **37,382 requests**, all against `www.governmentjobs.com`,
   serialized by `PER_HOST_MIN_DELAY_MS=600` → **~6.2 h per full sweep** (schooljobs adds
   ~1.6 h on its own host). This is the dayforce `www.dayforcehcm.com` serialization wall
   again, one order of magnitude worse. **Do not build a "sync every job every run" adapter.**
   Use the `knownJobs`/listing-only pattern: crawl `?sort=date&isDescendingSort=True` and stop
   at the first page of already-known ids; detail-fetch only new ids. Corpus id velocity
   (max `data-job-id` 5,451,862 → 5,464,473 over 2026-08-20→08-31) suggests **~1.1k new ids/day**,
   i.e. a steady-state lane of ~1.2k requests/day ≈ 12 min. The 6 h number is a one-time backfill.
2. **`baseSalary` is ALWAYS emitted, including when the agency published no salary** — the
   `sc` sample returned `minValue: 0, maxValue: 0, unitText: "YEAR"`. `!!job.baseSalary` will
   report 100% salary coverage and be wrong. This is the exact
   `project_jobfeed_adapter_field_coverage` failure mode (`parseSalary` never returns null);
   gate on `minValue > 0` before mapping, and measure coverage that way in `pg_reports`.
3. **The JSON-LD is not strictly valid JSON.** 1 of 6 samples
   (`/jobs/98681-1/social-work-supervisor-iii-…`) carried **raw literal newlines inside the
   `description` string**, which makes `JSON.parse` throw `Invalid control character`. It is
   content-dependent and intermittent, so it will not show up in a 5-tenant pilot. Sanitize
   control chars inside string literals before parsing, or fall back to a regex extraction of
   `description` — and never let a parse failure quarantine the whole board.
4. **Stale rows are in the live index.** `/jobs/98681-1/…` is served today with
   `datePosted: "2024-03-12"`. Public-sector "Continuous" recruitments legitimately stay open
   for years, so a freshness prune keyed on `posted_at` will delete real jobs; key expiry on
   *disappearance from the listing*, not on age.
5. Without `x-requested-with: XMLHttpRequest` every listing route silently returns a 199 KB
   jobless SPA shell with **HTTP 200** — a shape check that only counts bytes will call this
   healthy. Assert on `id="jobs-found"` / `id="job-postings-number"` presence, not size.
6. `addressLocality` is not a city (see field map). Geocoding straight off it will scatter.

### Tenant enumeration (only needed if you reject the global-feed design)

- **Common Crawl is genuinely blocked.** `robots.txt` allowlists Googlebot/bing/yahoo/msn/
  gsa-crawler-www/NHN/Twitterbot/facebookexternalhit with `Allow: /`, then `User-agent: *` →
  `Disallow: /`. `CC-MAIN-2026-34-index?url=www.governmentjobs.com/careers/*` → **HTTP 404
  `{"message": "No Captures found"}`**. Confirms the plan's §4 note; do not re-run CDX.
- Our own corpus already has **347 distinct tenant slugs** from **532 aggregator rows**
  (`jobs.apply_url ~ 'governmentjobs\.com/careers/([^/]+)/jobs/[0-9]+'`, since 2026-07-26).
  Zero `schooljobs.com` rows.
- Board-count estimate: 33,983 jobs against a per-tenant median of ~60 implies roughly
  **1,000–2,500 boards with live postings**. The plan's "universe ~13k orgs" is NEOGOV's
  customer count across all its products, not tenants with a live public board.
- **None of this is on the critical path.** The global `/jobs?page=` feed returns the same
  33,983 jobs without knowing a single slug; the tenant slug can be recovered per job from the
  detail fragment's `data-printing-url` (`…/careers/{slug}/jobs/newprint/{id}`) if the seed
  model wants per-employer accounts later.

### Rate limits / WAF / terms

- **39 requests over ~4 minutes at ~1.8 s spacing: zero 403, zero 429, no Cloudflare
  challenge, no rate-limit headers.** Server is ASP.NET behind HTTP/2; responses carry only
  `strict-transport-security`, `x-content-type-options`, `x-xss-protection` and a
  `content-security-policy` scoped to `frame-ancestors`. A single 500 was seen, on
  `loadJobsOnMaps` only (agency-config gated, not throttling).
- **`robots.txt` says `Disallow: /` for every agent that is not an allowlisted search engine.**
  There is no `Crawl-delay`, no `/careers/` carve-out. That is a policy call for Jon, not a
  technical blocker, and it is a stronger signal than anything we hit on dayforce/paycom
  (both silent). Note the 532 governmentjobs rows we already hold arrived *via aggregators*,
  which is a different posture from crawling the origin ourselves. **Get an explicit
  go-ahead on this before writing `src/adapters/neogov.ts`.**

### Recommendation

Ship `neogov` as **two aggregator-style accounts** (`www.governmentjobs.com`,
`www.schooljobs.com`), listing lane on `?sort=date&isDescendingSort=True` with the
`knownJobs` short-circuit, detail lane on `careers/jobInfo/agencyJobDetails/{id}` with the
control-char-tolerant JSON-LD parser. **Estimated: 2 boards, ~42.8k US jobs, ~1.1k/day
steady-state intake, ~8 h of one-time backfill.** Effort is comparable to `paylocity`
(HTML listing + JSON-LD detail) — the only new machinery is a global-feed pagination lane
instead of a per-tenant one, which is *less* work than the usual adapter, and it removes
NEOGOV's discovery/seeding work from Wave 2 entirely.

### loadJobsOnMaps probe (2026-09-05)

**Answer: PARTIAL.** It is a real, keyless, unpaginated JSON endpoint that returns an agency's
ENTIRE job set in one call with better structured fields than either HTML lane — but
`FullDescription` is **hard-capped at 703 characters** (54–100% of rows end in `...`), so the
`agencyJobDetails/{id}` JSON-LD fetch is still required for the JD and the detail lane, which
is ~91% of the request budget, does not shrink at all. It replaces the *listing* lane, not the
detail lane, and for a daily incremental it is **worse** than the global date feed (below).

**There is no "map-enabled agency" to hunt for.** `isMapSearchEnable` came back **`false` on
all 9 agencies that returned data**, and every one of them still returned the complete
`jobList`. The flag only tells the client whether to render a map; the server ships the
payload regardless. The earlier `sc` 500 was not a config gate.

#### The call

```
GET https://www.governmentjobs.com/careers/home/loadJobsOnMaps?agency={slug}
GET https://www.schooljobs.com/careers/home/loadJobsOnMaps?agency={slug}      # K-12, identical
    header: x-requested-with: XMLHttpRequest      <- the ONLY required header
```

`content-type: application/json`. **Never send `page`** — it is not a paging endpoint; the
whole agency comes back in one response (nv: 416 rows / 758,777 bytes / 1.9 s). Accepts the
same filter params as `home/index` (`keyword`, `category`, `department`, …), which is the only
way to shard a board. **Agency-less is impossible**: `/careers/home/loadJobsOnMaps` with no
`agency` → 302 `/Error/NotFound`, and the global `/jobs` search has no map route at all. So
this lane *reintroduces the tenant-enumeration problem the global `/jobs?page=` feed avoids.*

Top-level shape:
`{success, jobList[], customLabels, isRemoteOptionEnabled, employerLattitudeValue,
employerLongitudeValue, mapTilerKey, mapBoundsValue, mapsMinZoom, mapsMaxZoom,
isMapSearchEnable, is{location,type,salary,category,department,examtype,division,remote,
opendate,closingdate}visible}`. The `is*visible` flags mirror the agency's own display config
and are a free hint about which fields that agency actually populates.

#### `jobList[]` item field map

| field | value seen | vs. the JSON-LD detail path |
|---|---|---|
| `ID` | int, e.g. `5298882` | same global id as `/careers/{slug}/jobs/{ID}` and `/jobs/{ID}-0/` |
| `JobSource` | `0` on all 1,194 rows | the `-{src}` suffix; pairs with `ID` for the dedup key |
| `Classification` | the real title, agency casing (`SUPERVISOR, RIGHT-OF-WAY SURVEY SERVICES`) | = JSON-LD `title` |
| `JobTitle` | the **URL slug** (`supervisor-right-of-way-survey-services`) — NOT a title | lets you build the apply URL with no extra fetch |
| `FullDescription` | **703-char cap**, 88% end in `...` | **worse** — JSON-LD gives 2.4k–26k chars of real HTML |
| `Location` / `Location2` | clean city (`Carson City`, `Las Vegas`); `Location2` null on 1,194/1,194 | **much better** than JSON-LD `addressLocality` (`CITY OF LOS ANGELES`, `Williamsburg County`) |
| `JobCity[]` / `JobAbbrvState[]` / `JobLatLongList[]` | lower-cased city array, 2-letter state array, `"lat,lng"` string array | **arrays — 143/1,194 (12%) rows are multi-location**; JSON-LD collapses these to one address |
| `Lattitude` / `Longitude` (note the typo) | floats, non-null on **1,194/1,194** | free geocode; JSON-LD has none |
| `JobZipCode` | present or `null` — **empty on all 416 nv rows** | agency-dependent; JSON-LD `postalCode` was present 6/6 |
| `SalaryInfo` / `ShortSalaryInfo` | display string `"$73,309.68 - $109,640.88 Annually"` | **honest**: 1,118/1,194 real ranges, 56 `See Position Description`, 14 `Depends on Qualifications`, 3 `Not Displayed`, 3 `$0.00`. Needs parsing but avoids the JSON-LD `minValue:0/maxValue:0` sentinel entirely. |
| `IsSalaryVisible` | false on 3/1,194 | |
| `PostingDate` | **`MM/DD/YY`, present 1,194/1,194** (`04/30/26` … `09/04/26`) | 2-digit year, must be pivoted; JSON-LD `datePosted` is a cleaner `YYYY-MM-DD` |
| `OpenDate` | the relative string (`Posted more than 30 days ago`) — useless, use `PostingDate` | |
| `ClosingDate` / `CloseDate` / `Continuous` / `ShowClosingDateTime` | real date on 544/1,194, `Continuous` on 650 | **JSON-LD has no `validThrough` at all** — this is the only structured source for it |
| `JobType` | agency free text (`Full-Time`, `Unclassified Full-Time`, `Underfill Full-Time`, `Medical Part-Time`) | richer but dirtier than JSON-LD's schema.org enum, which was `OTHER` on 3/6 |
| `CountyName` | the employer display name (`State of Nevada (NV)`, `Seattle Public Schools`) | = JSON-LD `hiringOrganization.name` |
| `DepartmentName` / `Division` / `Categories[]` / `ExamType` / `JobNumber` | populated per agency config | not in the JSON-LD at all |
| `RemoteWorkOptionText` / `RemoteWorkOptionId` | **effectively dead: non-empty on 1 of 1,194** | do not use for remote classification |
| `IsNew` / `IsFeatured` / `ClusterIdForMap` / `PhysicalAddressId[]` / `IsTopUSAJob` / `TopUSAJobUrl` | flags / internal ids / USAJOBS cross-post | `ClusterIdForMap` is `ID*10 + n`, not a separate key |

No `country` field — infer US from `JobAbbrvState` (12 distinct states across the sample, all
US; only 6 of 1,194 rows had an empty state array).

#### Coverage — it is NOT geocoded-only

Distinct `ID` count matched the HTML listing's `job-postings-number` **exactly on all 6
agencies where both were measured**, and `Lattitude` was non-null on 1,194/1,194 rows. NEOGOV
geocodes everything, so there is no hidden non-geocoded remainder.

| agency (host) | HTML listing total | map rows | map distinct IDs | bytes |
|---|---|---|---|---|
| `nv` | 356 | 416 | **356** ✓ | 758,777 |
| `seattleschools` (schooljobs) | 96 | 96 | 96 ✓ | 168,098 |
| `honolulu` | 68 | 68 | 68 ✓ | 128,668 |
| `lacity` | 52 | 52 | 52 ✓ | 95,681 |
| `VanceCounty` | 38 | 38 | 38 ✓ | 68,490 |
| `medfordor` | 6 | 6 | 6 ✓ | 11,808 |
| `iowa` | — | 205 | 205 | 385,676 |
| `mncities` | — | 195 | 195 | 335,267 |
| `georgiadph` | — | 185 | 174 | 345,456 |
| `kingcounty` | — | 138 | 122 | 267,615 |
| `baltimorecounty` | — | 130 | 130 | 240,501 |
| `louisvilleky` | — | 37 | 37 | 51,954 |
| `sc` | 1,125 | **HTTP 500** | — | — |

**`rows > distinct IDs` is the multi-location fan-out** (nv 416→356, kingcounty 138→122,
georgiadph 185→174) — the same shape as the dayforce `ReferenceNumber` trap. Dedup on
`ID` and fold `JobLatLongList`/`JobCity`/`JobAbbrvState` into one job's location list.

#### Traps

1. **`FullDescription` is a 703-char teaser, not a description.** The name lies. Max length
   was exactly 703 on every one of the 9 agencies. Feeding it straight into `NormalizedJob`
   would ship 34k teaser rows — precisely the short-description defect class this skill exists
   to catch.
2. **The largest agency in the sample reproducibly 500s.** `agency=sc` (1,125 jobs) returned
   HTTP 500 + the generic error page on **5 separate attempts** — with and without `page`, at
   40 s / 60 s / 120 s client timeouts — failing in **2.5 s**, so it is an application error,
   not a timeout or a size cutoff. Adding any filter fixes it (`&keyword=engineer` → 32 rows,
   `&keyword=manager` → 74 rows, both HTTP 200), which is the shard-and-retry workaround, but
   it means **this lane needs an HTML-listing fallback for the boards that carry the most
   jobs**. Largest clean success: nv at 416 rows.
3. `page` is meaningless here and pushed `sc` into the same 500 — do not send it.
4. `PostingDate` is `MM/DD/YY`. A naive 2-digit-year parse will land jobs in 1926 or 2126.
5. `Lattitude` is misspelled in both the item and the envelope (`employerLattitudeValue`).

#### Revised request budget (600 ms `PER_HOST_MIN_DELAY_MS`, single host, 33,983 jobs)

| lane | listing requests | detail requests | total | wall clock |
|---|---|---|---|---|
| **Full backfill — global `/jobs?page=` (spike design)** | 3,399 | 33,983 | 37,382 | ~6.2 h |
| **Full backfill — map, one call per agency** | ~1,100–2,500 | 33,983 | ~35,100–36,500 | ~5.9–6.1 h |
| **Daily incremental — global `?sort=date&isDescendingSort=True`** | ~110 | ~1,100 | **~1,210** | **~12 min** |
| **Daily incremental — map, poll every agency** | ~1,100–2,500 | ~1,100 | ~2,200–3,600 | ~22–36 min |

The map endpoint saves ~3% on a one-time backfill and **costs 2–3× on the daily lane**,
because you must re-pull every agency to notice a change while the date-sorted global feed
surfaces the same new ids in ~110 pages. Detail fetches dominate either way.

#### Recommendation (supersedes nothing in the section above; refines it)

Keep the global `/jobs?page=&sort=date&isDescendingSort=True` feed as the **primary listing
lane** — it needs no slugs, no enumeration, and is the cheapest incremental. Do **not** build
the adapter around `loadJobsOnMaps`.

Use `loadJobsOnMaps` as an optional **weekly enrichment/reconciliation pass** over the agency
slugs we accumulate (recoverable per job from the detail fragment's `data-printing-url`,
`…/careers/{slug}/jobs/newprint/{id}`). One request per agency buys, for that agency's entire
board: clean city + lat/long, multi-location arrays, an absolute posted date, a real closing
date (`validThrough` exists nowhere else), department/category/exam-type, and an honest salary
string that dodges the JSON-LD `0/0` sentinel. That is a genuine location- and
salary-coverage win for `pg_reports`, at ~2k requests/week. It is an enhancement, not the
backbone.

## registry / enum invariants

- `src/db/schema.ts` `pgEnum('ats_provider', [...])` is the TS union;
  `src/adapters/index.ts` `adapters: Record<AtsProvider, AtsAdapter | null>`
  must have a key for EVERY union member (compile error otherwise — this is the
  completeness check; `hiring_cafe: null` is the external/n8n-fed pattern).
- DB enum may contain values absent from the union (jobspy, jsearch, jobicy,
  snagajob — paused June 2026; their rows show as
  `orphaned: data but no adapter` in the coverage matrix). Runtime strings pass
  through fine; only TS-side code needs the union entry.

## pipeline / ops landmines (not provider-specific)

### ats-sync daytime `rc=143` = host earlyoom, not OOM

- `f/jobfeed/ats-sync` Windmill runs failing `exit code for "bash run": 143` are
  killed by the **host `earlyoom` daemon** (SIGTERM → **143**), NOT a cgroup OOM
  (kernel OOM killer = SIGKILL → **137**) and NOT a Windmill timeout or adapter bug.
- The heavy-worker cgroup shows `memory.events oom_kill 0` / `OOMKilled=false` — the
  4 GB cap is never hit, so **raising `WM_HEAVY_MEM_LIMIT` does nothing.**
- Trigger: host crosses earlyoom defaults (**<10% free mem AND <10% free swap**)
  during the **daytime peak** (saas-app + n8n + postgres; 16 GB host, swap chronically
  ~full). The long-running ats-sync `node` child (~560–930 MiB RSS) is the
  highest-`badness` **victim, not the cause** — only that one pid gets SIGTERM (the
  bash wrapper survives and logs `rc=143`). Daytime slots (05:43/11:43/17:43 UTC)
  fail; the 23:43 slot is reliable.
- Fix applied 2026-06-23: catalog `retryAttempts:1, retryDelaySec:420` (retry resumes
  stalest-first after the minutes-long storm via `--skip-if-recent 5h`; deploy via the
  **schedules/update API — NEVER push-rest**) + `scripts/cron/ats-sync.sh`
  `MAX_ACCOUNTS 4000→3000` & `SYNC_CONCURRENCY=5` to shrink the earlyoom target.
- Memory: `project_jobfeed_atssync_earlyoom_kill`.

### benign `flock -n` skip false-fails the scheduler (`exit 1`, empty tail)

- Cron scripts in `scripts/cron/*.sh` guard overlapping runs with
  `/usr/bin/flock -n "$LOCK"`. Plain `flock -n` returns **exit 1** when the lock is
  held — **indistinguishable from a real command failure** — so a benign
  concurrent-skip propagates and the scheduler (Windmill now; Temporal before
  2026-06-19) flags the no-op as a failed run.
- **Signature:** a failed run `exited 1` with an **EMPTY tail** (the script's
  started/finished echoes live *inside* the flock block that never ran). A real
  MV-refresh error instead carries output like `canceling statement due to lock
  timeout` — different and correctly retried.
- **Fix:** `flock -n -E 99 "$LOCK" …` gives the lock conflict its own exit code, then
  `if [ "$rc" -eq 99 ]; then log "skipped"; exit 0; fi`. Any OTHER non-zero rc is a
  real error and still propagates.
- Fixed (commit c56c0dd): the 3 `*/15` MV refreshers
  (`refresh-{country-stats,scraped-quality,data-quality}-mv.sh`). **Still latent**
  (plain `flock -n`): aggregators, ats-sync, industry-coverage, dedupe-providers,
  resurrection, prune-sync-runs, ats-coverage — fix per-job when surfaced (a skipped
  non-idempotent sync may warrant different handling, so don't blanket-apply).
- Memory: `project_jobfeed_flock_lockheld_false_failure`.

## frontline (spike 2026-09-06, no adapter yet — Wave 2)

**Verdict: GO — and it is the cheapest per-job adapter in the whole parity program.** Frontline
Recruiting & Hiring (the product formerly branded AppliTrack) exposes, for every K-12 tenant, a
single keyless URL that returns the tenant's ENTIRE live board — titles, categories, posted
dates, closing dates and full HTML job descriptions — in one HTTP call. No auth, no cookie, no
XHR header, no pagination, no detail stage. `robots.txt` allows everything except the admin
path. **The July-2026 "no public feed" ruling was wrong**; it was almost certainly made against
`default.aspx`, which is a JS shell that `document.write`s the real payload.

**Sizing correction — the parity plan's `30–60k` estimate is ~2× too LOW.** One Common Crawl
crawl plus our own corpus already names **1,837 distinct tenants**, and a uniform random sample
of 8 of them averaged **58.5 live postings**. That is **~90–120k US jobs**, i.e. 2–3× NEOGOV,
from a source whose full sweep costs fewer requests than a single NEOGOV backfill hour.

### Endpoints verified (all keyless, plain browser UA, no special headers)

- **Whole-board feed (the ONLY integration point needed):**
  `GET https://www.applitrack.com/{tenant}/onlineapp/jobpostings/Output.asp?all=1`
  → HTTP 200, `content-type: text/javascript`. Body is a JS file whose payload is a run of
  `document.write('…');` lines, **one per physical line, every line terminated `');`** — join
  the slices between `document.write('` and the final `');`, then unescape `\'` and `\"`, and
  you have the board's HTML. 74 chunks / 68 jobs on collier; 1,054 chunks / 980 jobs on wvde.
  Sizes seen 67 KB → **8.5 MB** (wvde, a statewide consortium). No `page`, no `limit`, no cap.
- **Per-posting page (what our 1,253 corpus rows point at):**
  `https://www.applitrack.com/{tenant}/onlineapp/jobpostings/view.asp?AppliTrackJobId={id}`
  — this is a 3.5 KB JS shell, NOT the job. It `document.write`s `Output.asp?AppliTrackJobId={id}`.
  Use it as `apply_url` (it is the human-facing URL) and never fetch it for content.
  Real apply action is `_application.aspx?posJobCodes={id}&posFirstChoice=&posSpecialty=`.
- `default.aspx?all=1` is the district's search UI — an ASP.NET WebForms page (61–195 KB) with a
  `__VIEWSTATE`, whose job list is the same `jobpostings/Output.asp` include. Nothing to parse.
  `jobpostings/view.asp?embed=1` is the no-JS variant of the same shell.
- **Slug is case-insensitive** — `WESTBONNER` and `westbonner` returned byte-identical 67.4 KB.
- **Dead tenant → clean HTTP 404** (`.../thisisnotarealdistrictxyz/...`), so seed validation is
  a cheap single call per candidate.
- Dead ends (don't re-probe): **no JSON and no RSS anywhere** — `/api/`, `.asmx`, `.ashx`,
  `.json`, `rss` return zero hits across every listing, detail and search page sampled;
  `www.applitrack.com/` 302s to the frontlineeducation.com marketing site (no district index);
  `www.applitrack.com/sitemap.xml` → 404; `www.frontlineeducation.com/jobs` → 404;
  `jobs.frontlineeducation.com` and `{district}.frontlineeducation.com` do **not resolve**.
  There is no newer portal to migrate to and no global aggregate feed — unlike NEOGOV, this
  provider is per-tenant only.
- **No incremental lane exists** (no `sort`, no date filter; the only query params in the wild
  are `all`, `Category`, `AppliTrackPostingSearch=location:"…"`, `internal`, `embed`,
  `AppliTrackJobId`, `AppliTrackLayoutMode`). This does not matter: the whole board is one
  request, so a daily run and a full backfill are the same call. **Cost here is BYTES, not
  requests** — the inverse of the dayforce/neogov serialization wall.

### Field map → `NormalizedJob` (parsed out of the joined HTML)

Postings are delimited by `<p align=center class=noprint id='p{jobId}[_{clientId}]h'>` and
closed by a `<div style='width: 100%; height: .75px; background: gray;…'>` rule.

| NormalizedJob | source | notes |
|---|---|---|
| `title` | `<td id='wrapword' …>` | free text, occasionally a 160-char run-on listing every variant of the role — needs the title canonicalizer |
| `externalId` | `JobID: {n}` (= `AppliTrackJobId`) | **per-tenant, NOT global** — collier `21804` and wvde `70607` coexist. Key on `{tenant}/{jobId}` (`{tenant}/{jobId}_{clientId}` on consortium boards). |
| `description` | the `<span class='normal'>` run after `<span>&nbsp&nbsp</span>` | **three different layouts, see trap 2** |
| `postedAt` | `Date Posted:` | `M/D/YYYY`, no time, no offset. **100% present on all 15 boards sampled.** |
| `validThrough` | `Closing Date:` | present on 0–100% by board; value is often the literal `Until Filled` / `UNTIL FILLED` / `Continuous`, not a date |
| — | `Date Available:` | start date, frequently a school year (`2026-2027`) or `TBD` — not a NormalizedJob field |
| `employmentType` / category | `Position Type:` | two spans, `Family/` + `Subfamily` (`Elementary Teaching/Special Education`). This is a job FAMILY, not an FLSA type — feed the classifier, don't map it to the enum. Same pair is echoed in `applyFor('{id}','{family}','{specialty}')`. |
| `locations[]` | `Location:` | **a building name, not a place** — see trap 1 |
| `companyName` | account metadata, or `County:` on consortium boards | the feed never states the employer for single-district boards |
| `applyUrl` | build | `https://www.applitrack.com/{tenant}/onlineapp/jobpostings/view.asp?AppliTrackJobId={id}` — byte-identical to the 1,253 rows already in our corpus |
| `salary*` | **does not exist** | see trap 3 |
| attachments | `div.AppliTrackJobPostingAttachments` → `1BrowseFile.aspx?id=…` | usually the PDF job description |

### Per-tenant yield (2026-09-06; 26 requests to www.applitrack.com, ≥1.7 s apart)

`desc` = share of postings whose inline JD is ≥200 chars. `sal$` = share whose JD merely
*mentions* `$` or "salary" (NOT structured salary — there is none). `locs` = distinct
`Location:` strings, i.e. how badly a raw geocode would scatter.

| tenant | kind | jobs | post | clos | desc | medLen | sal$ | locs | attach |
|---|---|---|---|---|---|---|---|---|---|
| `wvde` | statewide consortium (WV) | **980** | 100% | 85% | 86% | 1,846 | 68% | 356 | 15% |
| `peoriaud` | large urban (Peoria IL) | 203 | 100% | 56% | 100% | 3,495 | 99% | 45 | 89% |
| `uplifteducation` | charter network (Dallas TX) | 105 | 100% | 0% | 100% | 5,905 | 86% | 51 | 0% |
| `graniteschools` | large urban (SLC UT) | 90 | 100% | 98% | 100% | 4,393 | 77% | 51 | 0% |
| `manchester` | mid district | 76 | 100% | 99% | **17%** | 98 | 0% | 19 | 67% |
| `district196` | mid suburban (MN) | 71 | 100% | 100% | 100% | 4,959 | 63% | 29 | 35% |
| `collier` | large county (FL) | 68 | 100% | 93% | 97% | 982 | 71% | 23 | 3% |
| `carolinecounty` | small rural | 51 | 100% | 0% | **22%** | 105 | 0% | 13 | 92% |
| `msdwt` | mid urban (Indianapolis) | 48 | 100% | 0% | 98% | 4,854 | 92% | 21 | 77% |
| `nassauboces` | BOCES / ESA (NY) | 37 | 100% | 95% | 100% | 2,863 | 54% | 16 | 0% |
| `isd192` | mid suburban (MN) | 35 | 100% | 74% | 100% | 1,762 | 86% | 13 | 69% |
| `gfusd` | small district | 29 | 100% | 100% | **7%** | 78 | 3% | 7 | 97% |
| `pecps` | small rural | 14 | 100% | 0% | 100% | 3,463 | 86% | 6 | 0% |
| `bbschools` | small rural | 12 | 100% | 8% | 100% | 334 | 42% | 5 | 0% |
| `westbonner` | small rural (ID) | 4 | 100% | 100% | 100% | 5,643 | 100% | 3 | 0% |
| **total** | | **1,823** | | | | | | | |

The last 8 rows of the source list (`isd192 gfusd manchester pecps carolinecounty bbschools
peoriaud msdwt`) were a **uniform random sample of the CDX tenant list**, drawn before probing:
468 jobs / 8 boards = **58.5 mean, 41.5 median, 8/8 alive**. Use those numbers for sizing, not
the hand-picked large districts. Description coverage weighted over that random 8 is **72%**;
`Date Posted` is **100% on every board sampled**. US share is 100% by construction (US K-12).

### Traps

1. **There is no city, no state, no country, anywhere in the feed.** `Location:` is the
   *building*: `Golden Gate High`, `Maintenance Department`, `Districtwide`, `Multiple Location
   - RSIP`, `District Schools As Necessary`. wvde alone emits **356 distinct** such strings.
   Geography MUST come from per-account seed metadata (district → city/state/ZIP); running
   `parseLocation` on the raw value will scatter across the country or null out, and the June
   US gate will drop the entire provider if it needs `country` from the payload. This is the
   single biggest integration cost of this adapter and it has to be solved at seed time, not
   at normalize time.
2. **Per-tenant layout config changes both the posting anchor and the JD markup — a regex
   tuned on one board silently returns ZERO or a teaser on another.** Confirmed variants:
   - anchor `id='p{jobId}_h'` on single-district boards vs `id='p{jobId}_{clientId}h'` on
     consortium boards. A `p(\d+)_h` regex parsed **0 of wvde's 980 postings** with HTTP 200
     and a healthy 8.5 MB body. Match `p([0-9]+(?:_[0-9]*)?)h`.
   - JD inside a collapsed `<span id='DescriptionText{jobId}_{clientId}'>` behind an
     `Additional Information:` label (collier, wvde, granite, uplift) — **or** rendered inline
     and unlabeled right after `<span>&nbsp&nbsp</span>` (isd192) — **or** absent entirely,
     with the real JD only as a PDF behind `1BrowseFile.aspx?id=…` (gfusd 97% attachments /
     7% inline JD, carolinecounty 92% / 22%, manchester 67% / 17%).
   - a **short** `Description:` label also exists and is NOT the JD — it is a one-line note
     ("Please upload college/university transcripts, resume, and teaching license"). Mapping it
     to `description` produces exactly the 78–105 char teaser rows the troubleshooting skill
     tells you to quarantine. Parse the block tail, not a named label, and treat a board whose
     median tail is <200 chars as attachment-only rather than broken.
3. **Zero structured salary. The schema has no salary field at all** — no `Salary` label exists
   on any of the 15 boards. Pay appears only as prose inside the JD ("Salary range $26.21 -
   $27.53 based on education") on 0–99% of rows depending on the district. Any `salary_pct`
   computed from a `$` regex is the `project_jobfeed_adapter_field_coverage` lie again; report
   structured salary coverage for `frontline` as 0% and let the estimator handle it.
4. **Consortium boards hide the real employer in a `County:` field.** wvde is one account
   serving 55 county districts: 100% of its 980 rows carry
   `County: <a href='http://www.grantcountyschools.org/'>Grant County School District</a>`.
   Without it all 980 jobs get attributed to "West Virginia K-12 Jobs". The same shape will
   appear on the other statewide/regional slugs already in our corpus (`ncjobs`, `teachiowa`,
   `joindelawareschools`, `teachmississippi`, `resa`, `alaskateacher`, `wvkyschools`, `isba`).
   Treat `County:` as `companyName` when present, and expect these boards to be the fattest
   accounts on the provider.
5. **One board can be 8.5 MB.** Budget on bytes: median board ~250 KB, so a full sweep of
   ~1,837 tenants is roughly **730 MB** in ~1,837 requests. Do not hold whole boards in memory
   alongside a parallel lane.
6. The `Output.asp` payload is JS, not HTML — a shape check that only asserts
   `content-type: text/html` or greps for `<html` will call every healthy response broken.
   Assert on `document.write('` presence and on a nonzero posting-anchor count.

### Tenant enumeration (required — there is NO global feed to fall back on)

- **Common Crawl works, unlike NEOGOV.** `robots.txt` allows crawling, and
  `CC-MAIN-2026-34-index?url=www.applitrack.com/*&output=json&filter=status:200&fl=url`
  returns `{"pages": 2, "pageSize": 5, "blocks": 6}` → **14,226 URLs → 1,701 distinct tenants**
  from that one crawl. Extract with `applitrack\.com/([^/]+)/onlineapp` (lower-case it).
  **Do not use the mid-path wildcard `www.applitrack.com/*/onlineapp/*`** — CDX only supports a
  trailing wildcard or a leading `*.domain`; use the prefix form and filter client-side.
  A `limit=300` truncates each page to the letter "a" (83 tenants) — omit it.
- Our own corpus adds 136 tenants CDX missed: `jobs.apply_url ILIKE '%applitrack.com%'` →
  1,253 rows / **575 distinct slugs**, all on `www.applitrack.com`, all
  `/{slug}/onlineapp/jobpostings/view.asp?AppliTrackJobId={id}`. Union with CDX = **1,837**.
  A 4-crawl CDX pass plus the corpus should land ~2,000–2,500.
- CDX path shapes for the record: 11,327 `/{t}/onlineapp/default.aspx`, 1,943
  `/{t}/OnlineApp/JobPostings/view.asp` (mixed case), 196 `_application.aspx`. Every one of
  them yields the tenant slug from segment 1.
- Seeding is cheap and self-validating: one `Output.asp?all=1` call per candidate, alive →
  200 + parseable, dead → 404.

### Overlap with NEOGOV / schooljobs.com

**Union, not intersection — no de-dup lane needed.** Sampled 3 Frontline districts
(Collier County Public Schools, Granite School District, MSD of Washington Township) against
`https://www.schooljobs.com/jobs?keyword=…`: none of the three appears as an employer there;
the K-12 results that came back are dominated by Hawaii State DOE and Seattle Public Schools.
Districts buy one K-12 recruiting suite, and AppliTrack and SchoolJobs are the two competing
products, so ~43k NEOGOV + ~100k Frontline should be treated as additive. Spot-check after the
first sync anyway via `canonical_hash`.

**Correction to the neogov note above:** on `www.schooljobs.com/jobs` the employer is
`div.primaryInfo` and the location `div.primaryInfo.job-location`, not `div.job-organization`
(that selector is the governmentjobs.com global feed). Same `li.job-item` wrapper, same
`x-requested-with: XMLHttpRequest` requirement.

### Rate limits / WAF / terms

- **26 requests to `www.applitrack.com` over ~9 minutes at ~1.7 s spacing: zero 403, zero 429,
  no Cloudflare, no challenge, no rate-limit headers.** Server is ASP.NET/IIS with Dynatrace RUM
  (`ruxitagentjs_*.js` injected into every page). The 8.5 MB wvde response streamed without
  complaint. No `Crawl-delay` is published.
- **`robots.txt` is permissive** and is the whole file:
  ```
  User-agent: *
  Disallow: /*/onlineapp/admin
  ```
  Every route this adapter needs is explicitly allowed. This is a materially better posture
  than neogov (blanket `Disallow: /`) and needs no separate go-ahead from Jon on that basis.

### Recommendation

Ship `frontline` as **per-tenant accounts** keyed `{tenant}` (slug from segment 1 of the
applitrack URL, lower-cased), one `Output.asp?all=1` call per account per run, no detail lane,
no pagination, no listing/detail split. **Estimated: ~1,837 seeded boards (→2,000–2,500 after a
4-crawl CDX pass), ~90–120k US K-12 jobs, ~1,837 requests and ~730 MB per run, ~18 min
serialized at `PER_HOST_MIN_DELAY_MS=600`, identical cost for a backfill and for a daily
incremental.** The adapter itself is the simplest in the program — the work is (a) the
three-layout JD parser with the attachment-only fallback, and (b) attaching a real city/state to
every account at seed time, which is a discovery/seed problem, not an adapter problem.

## workstream (spike 2026-09-06, no adapter yet — Wave 2)

**Verdict: GO, with a cost caveat.** Workstream (hourly hiring for QSR/franchise/retail/care) is
server-rendered, keyless, and unusually field-rich: **structured hourly pay on ~95% of postings**,
a full USPS street address on 100%, and a real HTML job description on 100%. It is the only
source in the parity program that reliably carries **hourly wage bands** — `$2.13 - 11.79 per
hour` (tipped) through `$65,000.00 per year` — which is exactly the seeker segment our corpus is
thinnest in. The cost is that the listing pages are hard-capped at **10 cards/page** and the
posting body only exists on the detail page, so a full sweep is ~1.1 requests per job, not per
board. Unlike frontline this is a **request-bound**, not byte-bound, provider.

### Endpoints verified (keyless, plain browser UA, no XHR header, no cookie)

- **Account listing (the integration point):**
  `GET https://www.workstream.us/j/{companyDigestKey}/positions`
  → 200 `text/html`. Covers **every brand** the account operates. Single-brand accounts **301**
  to `…/j/{digest}/{brandSlug}/positions`; follow it (the redirect hands you the brand slug for
  free). Multi-brand accounts (41 of 1,054 seen) serve the digest-only URL directly with 200.
- **Pagination:** `?page=N`, page size **fixed at 10**. `per_page`/`limit`/`page_size`/`size`/
  `perPage` are all ignored (verified: all five returned 10 cards / 370 pages on `acbc982a`).
  Inline `<script>` vars give `currentPage = 1`, `totalPages = 370`, `slug = "charter_foods_taco_bell"`,
  `searchBaseUrl = '…/positions'`. **`totalPages` is the only count the server exposes** — there
  is no `totalCount`.
- **Detail page:** `https://www.workstream.us/j/{digest}/{brand}/{citySlug}-{locationId}/{titleSlug}-{jobDigestKey}`
  → 200 `text/html`, server-rendered. `window.jobPageApp = {"digestKey":"6540a200","scope":
  {"company_digest_key":"e16b6820","brand_friendly_id":"chick-fil-a","location_id":"63849"}}`
  gives every key you need without parsing the URL.
- **Location page** `…/j/{digest}/{brand}/{citySlug}-{locId}` exists but pages at **5** cards, so
  it is strictly worse than the account listing. `…/{brand}/locations` is a store directory.
- Dead ends (don't re-probe): **no JSON API of any kind.** `Accept: application/json`, `.json`,
  `?format=json` all return HTML; `api.workstream.is` answers `Welcome to Workstream!` in
  text/plain and 404s every path tried; `/j/api/positions` → `Cannot GET`; `jobs.workstream.us`
  is a DNS alias that redirects to the marketing home page. `/j/{anything-not-a-digest}` returns
  `{"message":"Record does not exist.","status":404}` — the ONLY JSON the public app emits.
  **`https://www.workstream.us/sitemap.xml` is 4.4 MB and contains ZERO `/j/` URLs** (2,121 locs,
  all blog/hire/interview-questions/wage-index marketing). There is no global job index and no
  brand directory.
- **No incremental lane.** `organization-search.js` only builds `page`, `radius`, `title`, `lat`,
  `lng`, `geo`. No date sort, no `updated_since`. See "request budget" for the workaround.

### Field map → `NormalizedJob`

Two extraction paths. **JSON-LD is present on only ~70% of detail pages (5 of 7 sampled) and its
absence is per-posting, not per-tenant** — `e0ef86d8` job #1 had none, job #4 did; adding
`?referer_source=Google` did not make it appear. The HTML path works on 7/7, so **parse HTML and
treat JSON-LD as an enrichment overlay, never as the primary**.

| NormalizedJob | JSON-LD (`script[type=application/ld+json]`, ~70%) | HTML fallback (100%) |
|---|---|---|
| `title` | `title` | `<h1>` / listing `a.no-underline.b.fz16px.black` |
| `externalId` | — | `jobPageApp.digestKey` (8 hex, also the apply-URL tail) |
| `description` | `description` (HTML, 2.1–3.8 KB in samples) | `div.position-rich-text-content` |
| `locations[]` | `jobLocation.address` → `streetAddress`/`addressLocality`/`addressRegion`/`postalCode`/`addressCountry` | `div.position-address` free-text string, **two shapes** — see trap 3 |
| salary | `baseSalary.value` → `minValue`/`maxValue`/`unitText` (`HOUR`\|`WEEK`\|`YEAR`) + `currency` | `span` after `img[data-icon=rate-of-pay]`: `$14.50 - 16.00 per hour`, `$1,100.00 - 2,500.00 per week`, `$45,000.00 - 50,000.00 per year`, or single-value `$20.00 per hour` |
| `employmentType` | `employmentType` array (`["FULL_TIME"]`, `["FULL_TIME","PART_TIME"]`) | `span.tag.tag-small` (`Full-time`) — **present on only 3/8–10/10 of listing cards by tenant**, so prefer JSON-LD or the classifier |
| `postedAt` | `datePosted` (`YYYY-MM-DD`, no time/offset) | **DOES NOT EXIST** — see trap 1 |
| `validThrough` | `validThrough` | derived, worthless — see trap 2 |
| `companyName` | `hiringOrganization.name` = the **brand** (`Taco Bell`); `identifier.name` = the **operator** (`Charter Foods, Inc`) | `slug` var (`charter_foods_taco_bell`) |
| `applyUrl` | `url` | the card's `onclick="location.href='…'"` (absolute, `?locale=en`) |

Listing cards additionally carry a **68-char truncated teaser** in `div.position-short-desc`
(`"Assistant Manager at Culver's…"`). **Never map it to `description`** — it is exactly the
teaser shape the troubleshooting skill says to quarantine. The detail fetch is mandatory.

### Per-tenant yield (2026-09-06)

Hand-picked (to find the tail) — `pages`×10 is the posting count, exact where pages=1:

| digest / brand | kind | pages | ≈jobs | pay | type tag | street+state |
|---|---|---|---|---|---|---|
| `a7fca928` sun-holdings (9 brands: Papa Johns, Taco Bueno, Bar Louie, McAlister's…) | national multi-brand franchisee | **637** | ~6,370 | 9/10 | 10/10 | 10/10 |
| `acbc982a` taco-bell (Charter Foods) | national QSR franchisee | **370** | ~3,700 | 10/10 | 3/10 | 10/10 |
| `e0ef86d8` culvers (SL Companies) | regional chain | 56 | ~560 | 10/10 | 10/10 | 10/10 |
| `e16b6820` chick-fil-a (J.C. Hospitality) | single restaurant | 1 | 8 | 8/8 | 3/8 | 8/8 |
| `44a188ee` northwest-express | logistics / delivery | 1 | 6 | 6/6 | 6/6 | 6/6 |
| `055fd609` ace-hardware (Strand) | retail, single store | 1 | 5 | **0/5** | 0/5 | 5/5 |

**Uniform random sample of 8 digests** drawn from the CDX list before probing (seed 20260906),
which is what to size from — the population is dominated by tiny single-franchisee accounts:

| digest / brand | pages | jobs |
|---|---|---|
| `e0dbfb7e` chick-fil-a | 2 | ~15 |
| `06d8a32a` jimmy-johns | 1 | 9 |
| `f9504e32` chick-fil-a | 1 | 7 |
| `7f9f4378` chick-fil-a | 1 | 7 |
| `2f6f6c3a` firehouse-subs | 1 | 5 |
| `980198e3` chick-fil-a | 1 | 3 |
| `12bdb2b4` chick-fil-a | 1 | 2 |
| `b8a84277` chick-fil-a | 1 | 1 |

**8/8 alive, mean 6.1, median 6.** Body ≈ 1,054 × 6.1 ≈ 6.4k; the three whales measured by hand
are ≈10.6k on their own. Sizing therefore has to be tail-driven: CDX observed **3,590 distinct
(digest, location) pairs**, and the measured jobs-per-observed-location ratio is ~10
(`acbc982a` 358→3,700; `e0ef86d8` 50→560; `e16b6820` 1→8), giving **≈36k as a floor** (CDX
under-observes whale locations — `a7fca928` showed 84 locations but serves ~6,370 jobs).
**Estimate 30–60k live jobs**, i.e. at or slightly above the parity plan's `15–30k`. US share
is ~100% by construction (hourly US franchise), with a small Canadian tail (`moxies`, 8
franchisees) that the address string catches.

### Traps

1. **No posted date on ~30% of postings, and no date ANYWHERE outside JSON-LD.** The listing
   card has no date field, the detail HTML has no date field, and there is no `Last-Modified`
   worth trusting. On a posting without JSON-LD the only date you can record is first-seen.
   Budget for `posted_pct ≈ 70%` and do not let a freshness watchdog read the gap as a stall.
2. **`validThrough` is always exactly `datePosted + 62 days`** — verified on 4/4 LD samples
   (08-27→10-28, 08-29→10-30, 08-05→10-06, 07-31→10-01). It is a synthetic Google-for-Jobs
   filler, not an employer expiry. Do not surface it as a closing date and do not expire rows on it.
3. **Two incompatible address shapes in `div.position-address`.** Google-normalized
   `118 West St, Ware, MA 01082, USA` (space before ZIP, `USA` tail) **and** legacy
   `3949 Crosshaven Dr, Vestavia Hills, AL, 35243` (comma before ZIP, no country). A parser
   anchored on the `, USA` tail silently drops the second shape, and a `, {ST} {ZIP}` regex
   drops the first. Both appeared inside a single 10-card page on `44a188ee` (3/6 with the tail).
   Prefer `jobLocation.address` when JSON-LD is there; otherwise split on `,` from the right.
4. **`hiringOrganization.name` is the BRAND, not the employer.** 501 distinct franchisee accounts
   all say `Chick-fil-A`; 108 say `Jimmy John's`. The operator is in `identifier.name`
   (`Charter Foods, Inc`, `J.C. Hospitality LLC.`, `Strand Ace Hardware, Inc`) and in the page's
   `slug` var. Attributing on `hiringOrganization` collapses 501 independent employers into one
   company row and destroys the network/supporter signal. Key companies on `{digest}`.
5. **`positions` and `locations` are reserved path segments, not brand slugs.** CDX extraction of
   `/j/{digest}/{seg2}` yields a bogus brand `positions` (e.g. `39019d44/positions`). Exclude
   `positions|locations|apply|search` in the tenant-key extractor.
6. **Tipped wages break naive salary sanity checks.** `$2.13 - 11.79 per hour` is a legitimate US
   tipped-minimum posting, and `per week` (`$1,000.00 - 1,900.00`) is a real `unitText: WEEK` for
   delivery. A normalizer that floors hourly at the federal $7.25 or assumes HOUR/YEAR only will
   corrupt or drop the two segments this provider exists to supply.
7. Pay coverage is per-tenant, not universal: `055fd609` (Ace Hardware) showed **0/5** cards with
   any pay. Report structured-salary coverage from the payload, not from a `$` regex over the JD.

### Tenant enumeration

- **Common Crawl works.** `robots.txt` allows `/j/`, and
  `CC-MAIN-2026-34-index?url=www.workstream.us%2Fj%2F*&output=json&filter=status:200&fl=url`
  returns `{"pages": 1, "pageSize": 5, "blocks": 4}` → **8,374 URLs → 1,054 distinct
  `companyDigestKey`, 1,183 (digest, brand) pairs, 365 distinct brand slugs, 3,590 (digest,
  location) pairs** from one crawl. The parity plan's "1,183 Workstream brands" is this
  pair count, not the tenant count — **the account unit is the 8-hex digest, 1,054 of them.**
  Extract with `workstream\.us/j/([0-9a-f]{8})(?:/|$)`; take the brand from segment 2 only to
  seed a display name, and exclude the reserved segments in trap 5.
- Our corpus adds little: `jobs.apply_url ILIKE '%workstream%'` → 274 rows, of which **202 are
  `www.workstream.us/j/*`** (all `hiring_cafe`-sourced) covering ~90 digests, plus 46 rows that
  are Workstream-the-company's own Greenhouse board (`job-boards.greenhouse.io/workstream`) —
  **not** tenant data, filter them out. Union with CDX moves the count only marginally.
- Franchise-group vs single-store, from the 984 digests whose locations CDX observed:
  **617 multi-location (63%), 367 single-location, median 2 locations, max 358.** Brand
  concentration: chick-fil-a 501 franchisees, jimmy-johns 108, culvers 101, ace-hardware 43,
  then a long tail (sonic 9, taco-bell 8, moxies 8, burger-king 6, dunkin 5).
- **Seeding is self-validating and cheap**: one `…/j/{digest}/positions` call per candidate,
  alive → 200 (or 301 to the brand URL), dead → 404. 8/8 of a random sample were alive.

### Request budget

Full sweep ≈ `ceil(jobs/10)` listing pages **+ 1 detail request per job** ≈ **1.1 × jobs**.
At the 30–60k estimate that is **33k–66k requests, ~5.5–11 h serialized at
`PER_HOST_MIN_DELAY_MS=600`** — the most expensive backfill in the program, and all of it against
a single host.

**The daily incremental is cheap, and this is the whole trick:** the apply URL ends in the stable
`{jobDigestKey}`, so a listing-only pass identifies new postings without any detail fetch. A daily
run costs **~3.3k–6k listing requests (~35–60 min)** plus one detail call per genuinely new
posting. Do the detail lane only for unseen digest keys. Re-detail existing rows on a slow
rotation (they carry no update timestamp, so there is nothing to diff against anyway).

### Rate limits / WAF / robots

- **~60 requests to `www.workstream.us` over ~25 minutes at ≥1.6 s spacing: zero 403, zero 429,
  no challenge, no rate-limit headers.** (Budget for this spike was 40; the overrun was the
  random-8 sizing sample, which first had to be re-fetched because digest-only URLs 301.)
- Stack is **CloudFront → AWS API Gateway → Express** (`x-amz-cf-id`, `x-amz-apigw-id`,
  `x-powered-by: Express`, `x-amzn-remapped-server: nginx/1.25.0`). **No Cloudflare, no bot
  challenge.** `x-cache: Miss from cloudfront` on every hit, so the edge is not caching these
  pages for us — expect real origin load and keep the delay honest.
- `https://www.workstream.us/robots.txt` (200, 336 B) is a HubSpot marketing robots file and
  **allows `/j/` entirely**; the whole disallow list is `/sample-*`, `/blog/sample-*`,
  `/_hcms/preview/`, `/hs/manage-preferences/`, `/hs/preferences-center/`, `/*?*hs_preview=*`,
  `/*?*hsCacheBuster=*`, `/partnerships/`, `/wp-admin/`. No `Crawl-delay`. `job-boards.workstream.us`
  does not resolve. Posture is permissive — better than neogov, comparable to frontline.

### Overlap with existing aggregators

**Low — treat as mostly additive.** Active rows by provider for the three brands sampled:

| brand | our active rows (all providers) | Workstream side |
|---|---|---|
| Chick-fil-A | 135 (careerjet 58, adzuna 45, jobspy 11, jobs2careers 9, hiring_cafe 5, jooble 4, google_jobs 2, themuse 1) | 501 franchisee accounts × ~6 ≈ **3,000** |
| Taco Bell | 3,094 (paylocity 2,219, jobs2careers 522, careerjet 331, jobspy 12, jooble 8, adzuna 2) | `acbc982a` alone ≈ **3,700** |
| Culver's | 78 (dayforce 24, careerjet 17, adzuna 17, bamboohr 9, jobspy 6, hiring_cafe 3, jobs2careers 1) | `e0ef86d8` alone ≈ **560** |

Taco Bell is the one to watch: 2,219 rows already arrive via `paylocity`, i.e. a *different*
franchisee group's ATS. Franchisees pick one ATS each, so brand-level totals overlap while
store-level rows generally do not — and **no Workstream operator name (`Charter Foods`,
`Sun Holdings`, `Northwest Express`) exists as a company in our corpus at all**. Spot-check via
`canonical_hash` after the first sync rather than pre-emptively building a de-dup lane.

### Recommendation

Ship `workstream` as **per-account seeds keyed on the 8-hex `companyDigestKey`**, one
`…/j/{digest}/positions` paginator (10/page, follow the 301), a mandatory detail lane keyed on
`jobPageApp.digestKey`, HTML-first parsing with JSON-LD as an overlay, `companyName` from
`identifier.name`, and geography straight from the address string. **~1,054 seeded accounts
(likely 1,300–1,600 after a 4-crawl CDX pass), 30–60k US hourly jobs, ~33–66k requests for the
backfill and ~3.3–6k for a daily incremental.** The adapter itself is simple; the two real costs
are the request budget and the ~30% of postings with no date at all.

### Corrections from the adapter build (2026-09-06, Task 13)

Four spike findings did not survive contact with the live boards. The adapter
(`job_feed/src/adapters/workstream.ts`) is built on the corrected versions.

1. **The 301 does NOT land on `…/{brandSlug}/positions`.** The `Location` header DROPS
   the `/positions` segment: `/j/{digest}/positions` → `/j/{digest}/{brand}`. That
   target is the tenant's marketing LANDING page, not the list — it shows only the
   first FIVE postings and reports `totalPages = 1` regardless. `e0dbfb7e` serves 5
   cards / `totalPages 1` on the landing page and 10 cards / `totalPages 2` on
   `/j/e0dbfb7e/chick-fil-a/positions`, 13 postings in all; `e16b6820` serves 5 on the
   landing page and 8 on the list. Reading the redirect target as served loses more
   than half of a healthy board. Put `/positions` back on before following.
2. **`totalPages` is not a stop condition and `OPEN POSITIONS (N)` is not a count.**
   The landing page's `totalPages` is wrong (above), and the `OPEN POSITIONS` header
   disagrees with both (`e16b6820`: 8 declared, 5 cards on the landing page, 8 on the
   list). Walk until a page returns fewer than ten cards, or repeats keys.
3. **The 600 ms global host floor is too fast.** A 60-candidate listing-only pass at
   600 ms took a 429 inside the first minute and opened the circuit breaker, deferring
   35 of 60 LIVE boards. The same 60 at 1,600 ms: 59 valid, 0 deferred, zero 429s.
   `WORKSTREAM_MIN_DELAY_MS` defaults to 1600. A 25-account sync at that floor still
   drew 9 retryable 429s in 524 requests, all absorbed by the retry ladder with no
   circuit open — so 1,600 ms is a floor, not headroom.
4. **JSON-LD is on ~95% of detail pages, not ~70%.** Measured over 429 live detail
   fetches: 20 with no JSON-LD (4.7%). The 5-of-7 spike sample was too small. It is
   still per-POSTING and still not guaranteed, so HTML stays the primary path — but
   `posted_pct` on fully-enriched rows is 95%, not the 70% the spike said to budget for.

Two spike findings were confirmed exactly: both address shapes coexist and must be
split from the right, and `hiringOrganization.name` is the brand while the operator
lives in `identifier.name`. Two live Chick-fil-A franchisees resolved to
"Jc Hospitality LLC" and "Effective Synergy Corporation".

The operator is NOT taken from `identifier.name`, though. It is absent on ~5% of
postings and on 100% of the listing-only pass that seeds an account, so using it would
split one tenant across two company rows and mismatch the seeded company. The adapter
resolves it once per account from the LISTING page — the digest page's `<title>` when
the request did not redirect ("Sun Holdings", "S&L Companies dba Culver's"), otherwise
the brand page's `var slug` with the brand tail stripped
(`jc_hospitality_llc_chickfila` → "Jc Hospitality LLC") — and persists it to the
account config so it can never churn.

## Wave 3 spike (2026-09-06): the hiring.cafe SMB tail — careerplug, hireology, talentreef, harri GO; tenstreet, paradox NO-GO; applitrack = frontline

Context: hiring.cafe closed (site-wide Cloudflare managed challenge, § hiring_cafe). Its 75% SMB
tail named seven vendors we had no adapter for. Probed 2026-09-06 with the project UA, plain curl,
plus ONE browserless network capture per SPA vendor (to read which public endpoint the page itself
calls — not to render or scrape through the browser). Throwaway files in the session scratchpad only.

| vendor | verdict | hc tenants / jobs | public data path | tenant inventory | description |
|---|---|---|---|---|---|
| applitrack | **already shipped as `frontline`** | 575 / 1,253 | — | 568/575 tokens already seeded; the 7 missing go through the frontline funnel | — |
| careerplug | **GO** | 245 / 282 | HTML listing + JSON-LD detail | sitemap: 4,042 account URLs + 45,958 job URLs, plus `apscareerportal.com` white-label | full (JSON-LD) |
| hireology | **GO** | 146 / 180 | keyless JSON API, `page_size=100` | sitemap index = 13,127 tenant sub-sitemaps | full HTML in the listing record |
| talentreef | **GO** | 41 / 60 | keyless Elasticsearch proxy (`_search`, aggs allowed) | ONE aggregation: 2,080 clients (648 with a posting since 2026-06) | full in `_source` |
| harri | **GO (small)** | 15 / 27 | keyless gateway JSON (search + detail) | CDX `harri.com/{slug}` + `profile/slug` validator | full (`core-reader` detail) |
| tenstreet | **NO-GO** | 17 / 18 | job page embeds JSON, but NO per-company listing; `intelliapp.driverapponline.com` = Cloudflare challenge + 429 | — | — |
| paradox | **NO-GO** | 34 / 60 | `olivia.paradox.ai` = AWS WAF challenge (`awswaf` token, HTTP 202) on every page; it is a chat layer over other ATSes anyway | — | — |

### careerplug (`{tenant}.careerplug.com`, also `{tenant}.apscareerportal.com`; `*.r365hire.com` 302s to the careerplug subdomain)
- **Listing** `GET https://{tenant}.careerplug.com/jobs?page=N` — 30 rows/page, pager links carry
  `page=` (elided in the middle: `[2..9, 25, 26]` → take the MAX). Row = `<a href="/jobs/{id}">`
  with title, `Location: {ST}-{City}-{ZIP}` (also `Hybrid - US` / `Remote`), `Post Date: MM-DD-YY`,
  `Full / Part Time:`. Small tenants (≤ ~10 jobs) ALSO ship an `ItemList` JSON-LD of full
  `JobPosting`s on the listing; big tenants do not — do not depend on it.
- **Single-job tenants** answer `/jobs` with a 302 straight to `/jobs/{id}` — follow ONE hop (lib/http
  follows none; read `location`), it is still the same tenant.
- **Detail** `GET /jobs/{id}` → 302 → `GET /jobs/{id}/apps/new` (200, ~125 KB): one `JobPosting`
  JSON-LD with `description` (HTML-escaped HTML — unescape, then stripHtml), `datePosted`,
  `employmentType`, `jobLocation.address` (`addressLocality/Region/postalCode/addressCountry`),
  `baseSalary` (`unitText` HOUR/YEAR, min/max), `identifier.value` = job id, `hiringOrganization`.
  Canonical `app.careerplug.com/jobs/{id}` redirects the same way (host-agnostic id space).
- **robots** (`/robots.txt`): `Disallow: /apps/`, `/j/`, `/jobs.js`. Robots disallow rules are
  PATH-PREFIX matches, so `/jobs/{id}/apps/new` is allowed (it does not start with `/apps/`);
  never fetch `/apps/…` or `/j/…` at the root. `jobs.json` is 406, `/api/jobs` 404 — HTML is the API.
- **Budget** 1 listing page per 30 jobs + 1 detail per NEW job (knownJobs skip; the listing row's
  post date is enough to re-emit known rows listing-only with a NULL description). Distinct
  subdomains = distinct hosts for the per-host floor; the backend is one app (Heroku-style) —
  keep `SYNC_PER_PROVIDER_CONCURRENCY=2` and a 600 ms gate anyway.
- **Enumeration** `https://s3.amazonaws.com/careerplug-sitemaps/careerplug_com/sitemap.xml.gz`
  (index → `sitemap1.xml.gz` 50k URLs: 45,958 `app.careerplug.com/jobs/{id}` + 4,042
  `…/https://{tenant}.careerplug.org/accounts/{id}` = the tenant subdomain list; `sitemap2` is a
  stub). Same layout for `apscareerportal_com`. Job ids are global: a `/jobs/{id}` from the
  sitemap resolves to its tenant via the detail page's host after redirect — usable to grow the
  tenant list beyond `accounts/`. CDX `*.careerplug.com/jobs*` as the second source.
- **Slug** = the subdomain (lower-case). `external_id` = careerplug job id (global, numeric).

### Corrections from the adapter build (2026-09-07, Task 10)

The spike's page-shape assumptions and floor guess did not survive the live boards. The adapter
(`job_feed/src/adapters/careerplug.ts`) is built on the corrected versions.

1. **Two listing templates share the same `/jobs?page=N` shape.** "card" tenants
   (27-club-coffee, alphagraphics-careers) label each field (`Location:`, `Post Date:`,
   `Full / Part Time:`); "list" tenants (ahhc-careers) ship bare-value sibling `<div>`s with no
   label at all. Label-only parsing silently dropped 732 of 772 rows on ahhc-careers — a
   per-job window (this anchor to the next job anchor / pager link / `<nav>` / `<script>`,
   whichever comes first) plus a body-text-label-then-class-scoped-fallback read covers both.
2. **The per-job window must exclude the pager.** A pager link (`?page=N`) is not a job anchor;
   without stopping the last row's window at it, trailing pager text collapsed into the row body
   ("Full Time 2 9 26" instead of "Full Time").
3. **The 600 ms global host floor 429'd ~1.4% of detail calls** on the first live run (Ruling R8,
   2026-09-06) — careerplug and apscareerportal.com pace on ONE shared host GROUP
   (`hostGroupKey`), not the per-tenant subdomain, so `CAREERPLUG_MIN_DELAY_MS` now defaults to
   1,200 ms.
4. **The city tag-strip only caught the country-suffixed shape at first.** A work-type tag
   (`Hybrid`/`Remote`/`On-site`) glued onto the `ST-City-ZIP` geo string — with a trailing
   country (`WA-Bellevue-98006 Hybrid - US`) — was stripped, but the BARE form with no country
   at all (`CO-Lakewood-80228 Hybrid`, `TX-Austin-78701 Remote`) was not; both are now peeled off
   before the geo regexes (`3922c4a2`).

Measured yields (Step 1, Task 10, 2026-09-07 20:32Z): 967 active accounts (693 ok, 1 bad, 273
never_synced — still draining a first pass), p90 `last_synced_at` age 0.2 d. 17,887 active jobs /
616 employers. §17a coverage over all active rows: US 100, posted 86, desc200 30, salary 91,
city 100, region 100, emp 100, soc 49, junk 0. The low `desc200`/`posted` reads are the
`CAREERPLUG_DETAIL_MAX` cap (200/board) on a still-draining first pass — a capped board's
un-detailed rows re-emit listing-only (NULL description, no post date if the row text lacked
one) and self-heal as later ticks reach them, same pattern as hireology/harri below.

Request budget: 1 listing page per 30 jobs + 1 detail call per NEW job (knownJobs skip re-emits
known rows listing-only for free). Lane quota `careerplug=1500`
(`scripts/cron/ats-sync-longtail.sh`): covers most of the ~967-board roster per run — at the
1,200 ms host-group floor, ~1,500 boards' worth of listing+detail calls still fits a 5,000 s run
because most boards are listing-only.

**FIXED `dd1b0a3e` (2026-09-07 20:50Z) — the 3922c4a2 strip was END-anchored.** Task 10's Step 1
found 257 active rows (1.4% of 17,887) still carrying the tag in the city, ALL first seen after
3922c4a2. Reproduced live with `parseListingPage` + `locationFromRow` on the real rows: the strip
only matched a tag that ended the string, and none of the live shapes do —
`"ID-Boise-83709 Hybrid - US Powered by Privacy Policy"` (footer boilerplate after the tag),
`"Quincy Hybrid - US"` / `"Houston-TX Hybrid - US"` (no ST- prefix, so the ST-City-ZIP branch was
never reached and the country fallback handed the whole string to parseLocation), and
`"AR-Hot Springs-71901 CA"` (junk after the ZIP). `locationFromRow` now drops the boilerplate,
cuts the tag at its FIRST occurrence (the remainder is read only for country + remote hint),
tolerates trailing junk after a ZIP, and parses City-ST / City-ZIP / City forms. Stored rows are
rewritten on re-sync (verified: `fortcomhealth` 1790327 → city `Quincy`); the 34 affected accounts
were re-synced pinned the same evening. Residual, deliberately unhandled (≤ 5 rows): a
franchise/store suffix with NO ZIP and no tag — `"Miami - Aventura And Homestead"`,
`"Delaware Valley - Nj"` — indistinguishable from a real hyphenated place name.

### hireology (`careers.hireology.com/{slug}`)
- **Listing = the whole record**: `GET https://api.hireology.com/v2/public/careers/{slug}?page=N&page_size=100&sort=jobs.created_at&sort_dir=desc`
  → `{data:[job], count, page, page_size}` — keyless (the page's JWT is NOT needed on the `public/`
  route; `v2/jobs` and `v2/organizations/*` are the authed ones, ignore them). `page_size=100`
  honored (default 10). A parent/brand slug that is not a career site (`theupsstore`) is a 404.
- **Job**: `id`, `name`, `created_at`, `status` ('Open'), `employment_status` ('Full Time - hourly'),
  `job_description` (HTML, full), `locations[] {city,state,zip_code}` (NO country — infer US
  from a 2-letter state via parseLocation, drop the rest; 175/38k CA rows on talentreef suggest
  the same order of Canadian share here), `remote`, `compensation {is_comp_range,
  comp_single_amount, comp_range_min/max, comp_period ('hour'), comp_frequency}` — gate on a
  real number, `comp_range_min/max` are "0.0" when unset; `organization {id,name}`;
  `career_site_url` = the apply URL; `job_family.name` = department.
- **Enumeration**: `https://careers.hireology.com/sitemap.xml` = a sitemap INDEX of 13,127
  per-tenant sub-sitemaps (`sitemaps/sitemap-{n}.xml`, ids sparse — iterate the index, do not
  count up). Each lists `careers.hireology.com/{slug}` + one `/{slug}/{id}/description` per open
  job (0 for most of a 6-sample: SMB auto dealers, home care). One index fetch = the roster;
  validate with the API call (count ≥ 0 = live).
- **Slug** = the path segment (lower-case). `external_id` = hireology job id.
- **Budget** 1 request per ≤ 100 jobs, no detail phase. robots: `Allow: /`.

### Corrections from the adapter build (2026-09-07, Task 10)

1. **`count` in the API response can be missing or unreliable** — the adapter cannot use it as a
   stop condition. It paginates until a page returns fewer than `page_size` (100) results instead.
2. **`status` can be absent on a job record.** The spike assumed a `status: 'Open'` gate; a
   missing `status` is treated as open (excluding on a missing field would silently drop live
   rows) — only an explicit closed/non-open value filters a job out.
3. **No country field on `locations[]`** — US is inferred from a 2-letter state via
   `parseLocation`; the ~175/38k Canadian-share seen on talentreef (below) suggests a similar
   order of CA rows ride along here too, filtered client-side.
4. **`comp_range_min`/`comp_range_max` read `"0.0"` (string) when unset** — gate on a real
   parsed number, not truthiness.
5. **A blank `comp_period` was read as annual by default** (first-pass defect, this plan's Task
   5): 34 rows with `salary_max_usd < 300` and no `salary_period_raw` misclassified an hourly
   rate as an annual one (`hourly_as_annual`), plus 2 rows with `salary_period_raw='month'` and
   `salary_min_usd > 300000` (`month_gt_300k`). Fixed `303427df` (reuses `inferRatePeriod`, drops
   the ambiguous middle band, treats a >$300k "month" figure as a year). Rows synced before the
   fix self-heal on re-sync; the pre-fix rows were also backfilled directly.

Measured yields (Step 1, Task 10, 2026-09-07 20:32Z): 8,444 active accounts (3,250 ok, 0 bad,
5,194 never_synced — the roster's second half, draining through the long-tail lane at
2,500/tick), p90 `last_synced_at` age 0.0 d (every touched account is fresh). 27,783 active jobs
/ 3,082 employers. §17a coverage over all active rows: US 100, posted 100, desc200 100, salary
70, city 100, region 100, emp 100, soc 45, junk 0. No new defect signature in §17c for
hireology (`city_has_dash_label` = 1 row — noise, not a pattern).

Request budget: 1 request per ≤100 jobs, no detail phase — the listing IS the whole record.
Lane quota `hireology=2500` (`scripts/cron/ats-sync-longtail.sh`): deliberately sized to the
whole ~13k-tenant roster's headroom per run, since most SMB tenants sit at 0–2 jobs (one page)
and `api.hireology.com` sits on the 600 ms global floor (no per-host override yet).

### talentreef (`apply.jobappnetwork.com/clients/{clientId}/posting/{jobId}`)
- **The SPA's own search**: `POST https://prod-kong.internal.talentreef.com/apply/proxy-es/search-en-us/posting/_search`
  with a plain Elasticsearch body — keyless (add `origin: https://apply.jobappnetwork.com`, it is
  what the page sends). The host name says "internal" but it resolves publicly (44.239.242.101)
  and is the only path the public apply site has; the BFF host answers 401 to everything.
  Aggregations work: `{"size":0,"aggs":{"c":{"terms":{"field":"clientId.raw","size":3000}}}}`
  returned all 2,080 clients in one call (63 KB).
- **Index**: 196,172 docs total but it is an ARCHIVE — the top client (10129 Spirit Halloween,
  18,142 docs) is full of 2019 rows. Filter: `range createdDate >= now-90d` (38,505 docs / 648
  clients since 2026-06-01; 23,509 since 2026-08-01) and `internalOrExternal = externalOnly`
  (968 internalOnly + 31 internalWithExpiration). `endDate` is NOT expiry (only 425 docs carry a
  future one) — treat re-listing as liveness (two-strike removal) plus a 60-day `createdDate`
  window. Country: `address.country` = US 99.5% / CA 0.5% — filter server-side.
- **Doc**: `jobId`, `title`, `positionType`, `description` (HTML, full), `address {street1, city,
  stateOrProvince, postalCode, country}`, `stateOrProvinceFull`, `geo {lat,lon}` (often 0/0),
  `clientId`, `clientName`, `brand`, `brandId`, `department.name`, `contractType` ('fullTime'),
  `isSalaried`, `shifts`, `createdDate`, `startDate`, `url` (relative, legacy). Apply URL =
  `https://apply.jobappnetwork.com/clients/{clientId}/posting/{jobId}`.
- **Account model**: ONE account per clientId (`slug` = clientId, company = `clientName`; big
  franchisors carry many brands — `brand` → department or `rawPayload`), listing =
  `term clientId.raw` + date filter + `sort createdDate desc`, `size` 200, `from` paging (or
  `search_after`). The whole provider is one host: 2,080 clients × ~1–2 requests, fine on a
  600 ms gate.
- **Slug** = clientId (numeric string). `external_id` = jobId.

### Corrections from the adapter build (2026-09-07, Task 10)

1. **`top_hits` aggregations are accepted** by the keyless Elasticsearch proxy, not just the flat
   `terms` aggregation the spike verified — useful for pulling a sample doc per client without a
   second round-trip.
2. **Shared bug patched locally, not fixed at the source** (Ruling R6, SHARED BUG #2):
   `lib/html-text.ts`'s `htmlToText` leaves a space before punctuation when a closing inline tag
   abuts it (`<b>guests</b>.` → `"guests ."`). Patched inside talentreef's own `normalizeDoc`
   only; the shared fix is out of this plan's scope and was carried to Jon alongside the
   `parseLocation` FL/CT bug (see careerplug's location note above).
3. **Salary is a source limitation, not an adapter gap.** The index carries only a boolean
   `isSalaried`, never a compensation figure, so `salary: null` is correct by design — there is
   no detail phase to backfill it from. §17a's 1% salary coverage below is the expected ceiling
   for this provider, not a defect.

Measured yields (Step 1, Task 10, 2026-09-07 20:32Z): 618 active accounts (499 ok, 1 bad, 118
never_synced), p90 `last_synced_at` age 0.4 d. 33,081 active jobs / 499 employers. §17a coverage
over all active rows: US 100, posted 100, desc200 100, salary 1, city 100, region 96, emp 100,
soc 67, junk 0. No new defect signature in §17c for talentreef (`city_has_dash_label` = 1 row —
noise, not a pattern).

Request budget: one Elasticsearch-proxy request per ~200 postings (`size` 200, `from` paging or
`search_after`), no detail phase — the whole provider is one host
(`prod-kong…internal.talentreef.com`). Lane quota `talentreef=800`
(`scripts/cron/ats-sync-longtail.sh`): the whole 618-client roster, one request per ~200
postings on that single host, 90-day window, no detail phase.

### harri (`harri.com/{slug}`)
- **Resolve** `GET https://gateway.harri.com/core/api/v1/profile/slug/{slug}` → `{data:{id,
  type:'brand', career_portal_enabled}}` (a non-portal brand answers `career_portal_enabled:false`
  — skip). `GET core/api/v1/career_portal/brands/{id}/tree` → child brands + `active_jobs_count`.
- **Listing** `POST https://gateway.harri.com/core/api/v1/harri_search/search_jobs`
  `{"size":30,"from":0,"source":"web","brand_level_ids":[{id}],"sort":["publish_date"],"sort_type":"desc","flow":"CAREER_PORTAL"}`
  → `{data:{hits, results[]}}`; `from` pages. Result: `id`, `position.name`, `aliasPosition`,
  `brand {id,name,slug}`, `locations[] {city,state,street,country,country_code,lat,lng}`
  (**country_code** — US gate server-side is not available, filter client-side; Harri is UK+US,
  Azumi's 111 jobs were ~40% London), `publishTime`, `createdTime`, `compensation
  {code:'SET_AMOUNT'|…, rate.code:'PER_HOUR'|…, compensation_from, compensation_to}`.
- **Detail** `GET https://gateway.harri.com/core-reader/api/v1/profile/job/{id}` → `data.job
  {description (HTML), experience_from/to, …}` keyless. The `core/api/v1/*/jobs/{id}` guesses are
  401 — use `core-reader`.
- **Enumeration** CDX `harri.com/*` first path segment → validate via `profile/slug`. Only 15
  tenants known; hospitality groups (Smashburger, Zuma, Wolfgang Puck). Low volume, cheap adapter.
- **Slug** = the harri path slug. `external_id` = harri job id.

### Corrections from the adapter build (2026-09-07, Task 10)

1. **`search_jobs` ignores `from`/`page`.** Repeated calls with a different `from` value return
   the same first page — there is no working pagination on the listing endpoint. The adapter
   issues ONE `size:1000` request per brand instead of paging.
2. **Partial, not silently truncated, when `hits` exceeds what came back.** When the search
   response's `hits` (total matching count) is larger than the 1,000-row cap actually returned,
   the run is flagged partial for that brand rather than dropping the excess unflagged — live on
   the first run: `jib-bflllqsifpwx` reported 1,168 hits against the 1,000-row cap.
3. **The search hit carries no employment-type field at all** — the classifier default made
   every one of the first run's 8,936 rows `full_time`. Fixed `4194329a`: the core-reader
   detail's `Timing[]` codes (`FULL_TIME`/`PART_TIME`, 0/1/2 entries; `is_apprenticeship`
   overrides both) drive `rawEmploymentType` when a detail is fetched, with an
   `employmentTypeFromTitle` (shared with dayforce) fallback for listing-only rows that never
   get a detail this sync. The fix landed 2026-09-07 18:44Z, ~40 minutes AFTER the supervised
   first run finished (17:23–18:02Z) — so the fleet's current rows are still 100% pre-fix
   `full_time`; this self-heals once the long-tail lane's 60 h skip window lets an account
   re-sync, not a sign the fix failed.

**`duration_mode` (`'EVERGREEN' | 'ONE_TIME'`) and stale evergreen dates — known trade-off, not
a defect.** The core-reader detail also carries `duration_mode`, unused by the adapter today. An
`EVERGREEN` posting is a standing req the employer never expires, and Harri does not refresh its
`publishTime`/`createdTime` to match — those postings carry their ORIGINAL post date, which can
be years old. Measured 2026-09-07 20:32Z: 1,477 of 8,903 active harri rows have `posted_at`
older than 12 months (oldest: 2020-05-15). These will age out under the standard sweep policy on
schedule even though the underlying req is still open — accepted as a trade-off of treating
Harri postings the same as every other provider's `posted_at`, not something this task fixes.

Measured yields (Step 1, Task 10, 2026-09-07 20:32Z): 71 active accounts (71 ok, 0 bad, 0
never_synced — the whole roster synced once already), p90 `last_synced_at` age 0.1 d. 8,903
active jobs / 70 employers. §17a coverage over all active rows: US 100, posted 100, desc200 39,
salary 79, city 100, region 95, emp 100, soc 67, junk 0. `desc200` is the `HARRI_DETAIL_MAX` cap
(100/board) on the first pass — 3,511 of 8,936 rows got a detail fetch, the rest re-emitted
listing-only and self-heal on later ticks. No new defect signature in §17c for harri.

Request budget: one `size:1000` search per brand plus one `core-reader` detail per NEW job
(capped at `HARRI_DETAIL_MAX`=100/board). Lane quota `harri=200`
(`scripts/cron/ats-sync-longtail.sh`): the whole 71-brand roster, single gateway host on the
600 ms global floor.

### tenstreet — NO-GO (2026-09-06)
`pulse.tenstreet.com/share_app_show_active_jobs.php?active_job_id=X&company_id=Y` embeds
`active_job_array` (one job × one row per hiring state, `job_description`, `job_requirements`,
`job_pay`) — but the company-level URL (`company_id` only) answers `active_job_array = null`, the
portal index is a 404, and the real board (`intelliapp.driverapponline.com/c/{slug}`) is behind a
Cloudflare challenge that also 429s. No listing = no adapter. 17 trucking tenants; revisit only if
a listing route turns up.

### paradox — NO-GO (2026-09-06)
`olivia.paradox.ai/co/{tenant}` and `/Job?job_id=` answer HTTP 202 with an AWS WAF challenge
(`window.gokuProps`, `challenge.js` from `token.awswaf.com`) on every route. Paradox is a
conversational front-end over customer ATSes (a third of its hiring.cafe apply URLs were Workday
and customer domains). Do not build a solver; the jobs reach us through the underlying ATS.
