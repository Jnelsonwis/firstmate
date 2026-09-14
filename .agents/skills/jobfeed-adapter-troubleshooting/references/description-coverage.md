# Short / truncated descriptions playbook

Compiled from the 2026-08-31 sessions that fixed phenom (44k teaser rows),
oracle_cloud (54k blurb rows) and pinpoint (1.3k intro-only rows). Symptom:
rows whose `description_text` is a ~200–500 char snippet — sometimes ending
"…", usually NOT.

## Step 0 — classify the provider before touching code

| Class | Providers (2026-08-31) | Fixable? |
|---|---|---|
| **Snippet-only aggregator API** — upstream sends ONLY a snippet; full text sits behind a click/affiliate redirect URL | careerjet (775k, avg 204), jooble (53k, avg 279), adzuna (24k, hard 500-char cut + "…") | **NO adapter fix.** Mass-following `redirect_url` = faking paid ad clicks (ToS) + scraping arbitrary employer sites. Options: accept snippets, Coverage Improvement Console (browserless), or UI "view at source" |
| **Detail-capable provider** — a per-job page/endpoint HAS full text, adapter under-fetches | phenom, oracle_cloud, pinpoint (all FIXED 2026-08-31 — see fix table below), potentially any detail-capped adapter | YES — one of the three mechanics below |

## Step 1 — measure (cheap queries only)

**COST TRAP:** a fleet-wide `description_html LIKE '%…%'` scan ran ~10 min
(parallel seq scan, IO-bound). Provider-scoped `length(description_text)`
queries run in 0.1–45s. Never pattern-match `description_html`.

Use triage-queries §15 (per-provider coverage, per-account clustering, length
histogram). Read the histogram for a **bimodal gap**:

- phenom: teasers ≤462, full ≥644 → clean threshold 600.
- oracle_cloud: NO gap (blurbs 1–500 shade into genuine short JDs) → length
  can't discriminate; use the rawPayload marker (§15d): the adapter stores
  `rawPayload = {list, detail}` and upsert overwrites it every sync, so
  `raw_payload->>'detail' IS NULL` = "last arrival was listing-only".

**Detection gotcha:** teasers usually do NOT end with "…" — phenom truncates at
a sentence boundary. Ellipsis-matching finds adzuna and little else. Length
distribution is the signal.

## The three mechanics (all observed, don't re-derive)

1. **Snippet emitted on listing-only re-arrivals OVERWRITES full text.**
   `upsert.ts` does `COALESCE(incoming, stored)` on description — a NON-NULL
   incoming teaser/blurb wins over stored full text. Any detail-capped adapter
   that re-emits known jobs WITH the listing snippet downgrades them the moment
   they rotate out of the detail budget (oracle: newest-40 window; phenom:
   first-300-by-position). **RULE: a listing-only re-emit of an
   already-enriched job MUST carry `descriptionHtml/Text: null`.** This is the
   established eightfold/workday/oracle/phenom pattern; upsert also preserves
   department/team/employmentType/remoteType on such re-arrivals.

2. **Snippet poisons the drain gate (confident-default masking, description
   flavor).** The job-details-drain backfill selects/bails on
   `!row.descriptionText` (`job-details/fetch.ts` goal-idempotence). A stored
   200-char blurb makes the row look enriched → never backfilled, forever.
   Analog of the parseSalary "100% coverage" trap in checklists. Corollary:
   enqueueing blurb-bearing rows does nothing — backfill requires NULLing
   their description first, and the adapter fix must land BEFORE the SQL or
   the next sync re-writes the blurb.

3. **Adapter reads one field of a multi-field JD.** pinpoint's payload splits
   the JD across `description` + `key_responsibilities` +
   `skills_knowledge_expertise` + `benefits`; the adapter mapped only
   `description` (~300-char intro). Compose all sections (oracle-style `<h3>`
   joins). When a provider's short rows cluster oddly, check `raw_payload`
   keys for unused content before assuming a detail fetch is needed.

## Silent detail-fetch killer: redirects

`httpGetText`/`httpGetJson` **THROW on 3xx** (`lib/http.ts` follows NO
redirects). An adapter whose detail path catches-and-falls-back (phenom) turns
a wrong URL into 100%-teaser accounts with zero errors anywhere. Phenom's
job-page locale prefix varies per tenant (`/us/en/job/` vs `/global/en/job/`
vs `/ca/en/job/` — wrong one 302s to the site home). The adapter now probes
candidates per sync via `httpGet` (which exposes status+headers), derives new
candidates from the 302 `location` header and from `"locale":"en_xx"` stamps
in tenant HTML, and persists the winner via `onResolvedConfig`. Reuse that
probe pattern for any tenant-hosted detail page.

## Incremental-detail plumbing (knownJobs)

`AdapterFetchOpts.knownJobs` (built lazily in `sync-one.ts`) maps external_id →
`{hasDescription (>50 chars), descriptionLength (length(description_text),
added 2026-08-31), postedAt, sourceUrl}`. Consumers: smartrecruiters, workday,
eightfold, breezy, taleo, hiringcafe, phenom, oracle_cloud.

- `hasDescription` alone CANNOT tell teaser from full — a 200-char teaser
  passes the 50-char bar. Threshold on `descriptionLength` where a bimodal gap
  exists (phenom: `>= 600`).
- Partition pattern: known-full → emit listing-only (null desc); everything
  else (new + teaser-length) competes for the detail budget. Budget then
  CONVERGES the backlog across syncs instead of re-fetching the same head.
- The skipped job MUST still be emitted or `markMissingJobs` churns it.

## Fix state (2026-08-31) + how each converges

| Provider | Fix | Backfill of old short rows |
|---|---|---|
| phenom | Locale-prefix probe + FULL_DESC_MIN=600 knownJobs partition + null-desc listing-only re-emits (DETAIL_MAX 300/account/sync) | Automatic: ~300/account/sync toward teaser rows; largest tenant ≈ 2.5 days |
| pinpoint | Compose 4 JD sections | Automatic: adapter always emits desc, COALESCE overwrites on next rotation (~2.8d) |
| oracle_cloud | ShortDescriptionStr fallback ONLY when a detail was actually fetched; knownJobs partition spends ORACLE_DETAIL_MAX=40 on un-described rows; listing-only emits null → drain enqueues new rows | One-time NULLing SQL **EXECUTED 2026-08-31** (57,979 rows, 6m14s; post-state 58,385 null-desc incl. 406 pre-existing, still-short exactly the 100 genuine-short-JD floor). Rows drain-enqueue as their accounts re-arrive over the ~2.8d rotation |

The executed oracle unlock, kept as the template for any future blurb-class
provider (run only AFTER the adapter stops emitting the snippet on
listing-only rows; detach — the 58k-row run took 6+ min):

```sql
UPDATE jobs SET description_text = NULL, description_html = NULL, updated_at = now()
WHERE provider = 'oracle_cloud' AND status = 'active'
  AND raw_payload->'detail' IS NOT NULL AND raw_payload->>'detail' IS NULL
  AND length(description_text) <= 600;
```

Convergence check: short-row counts by provider (triage §15a) — phenom teaser
≈44k on 2026-08-31 trends to ~0 (~300/account/sync); oracle null-desc ≈58k
refills via the job-details-drain as accounts rotate. Genuine short JDs exist
(oracle floor measured at exactly 100) — expect a small floor, not zero.

## Adapter-done checklist addition

Before calling any detail-fetching adapter done, run the description-length
histogram (§15c) on a real board, not just "description present %": present
but short = teaser class. And verify a re-sync of an enriched board does NOT
shrink `avg(length(description_text))` — that's the COALESCE downgrade.
