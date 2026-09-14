# JS → TS Adapter Promotion Checklist

Playbook for converting a legacy CJS `.js` adapter stub (e.g. `src/adapters/gem.js`)
to a proper TypeScript AtsAdapter and wiring it into the per-account sync pipeline.
Compiled from the gem promotion session (2026-06-27, commit `366beba`).

> **Read first:** `job_feed/docs/seed-and-adapter-overlap-reference.md` — the
> single-writer rule, slug-scheme trap, and external_id preservation are all
> explained there with concrete examples.

---

## 0. Pre-flight: understand the current writer

Before writing a line of TS, answer these:

| Question | Where to look |
|---|---|
| Who writes jobs for this provider now? | `scripts/ats-ingest.ts` SOURCES, or n8n |
| What slug scheme do existing accounts use? | `SELECT slug FROM company_ats_accounts WHERE provider='X'` |
| What does the existing external_id look like? | `SELECT external_id FROM jobs WHERE provider='X' LIMIT 5` |
| Does the provider's source_url encode the real board slug? | `SELECT source_url FROM jobs WHERE provider='X' LIMIT 3` |

If the provider is currently in `ats-ingest.ts`, follow the **promotion playbook
(§2 of the overlap reference)** — especially steps 2–4 on renaming lazy slugs
BEFORE seeding.

---

## 1. Create `src/adapters/<provider>.ts`

### Imports (always used)
```typescript
import { httpPostJson, httpGetJson } from '../lib/http.js';   // POST or GET
import type { AtsAdapter, NormalizedJob } from './types.js';
import { parseLocation } from '../normalize/location.js';
```

### AtsAdapter shape
```typescript
export const <name>Adapter: AtsAdapter = {
  provider: '<provider>',
  async fetchJobs(slug: string, config?: Record<string, unknown>): Promise<NormalizedJob[]> {
    // ...
  },
};
```

### HTTP helpers (from `src/lib/http.ts`)
| Need | Call |
|---|---|
| JSON GET | `httpGetJson<T>(url, opts?)` |
| JSON POST (GraphQL, etc.) | `httpPostJson<T>(url, body, opts?)` — sets `content-type: application/json` |
| Raw text GET | `httpGetText(url, opts?)` |
| Raw buffer GET | `httpGet(url, opts?)` |

The http layer handles per-host rate limiting, exponential backoff on 429/5xx,
connection pooling, and circuit breaking. Do NOT add your own sleep/retry loop.

### NormalizedJob fields
```typescript
{
  externalId: string,          // MUST match legacy format if promoting
  title: string,
  department?: string | null,
  team?: string | null,
  descriptionHtml?: string | null,
  descriptionText?: string | null,
  rawEmploymentType?: string | null,
  isRemoteHint?: boolean,
  locations: ParsedLocation[],  // from parseLocation()
  salary?: ParsedSalary | null,
  applyUrl?: string | null,
  sourceUrl?: string | null,
  postedAt?: Date | null,
  updatedAtSource?: Date | null,
  rawPayload: Record<string, unknown>,
}
```

### US-only filter (required for every adapter)
```typescript
// Pre-filter (before detail fetches): drop clearly non-US
const usOnly = items.filter(item => {
  const loc = parseLocation(item.locationStr);
  return loc.country == null || loc.country === 'US';
});
// Post-filter: require resolved US
return usOnly.filter(j => j.locations.some(l => l.country === 'US' || l.isRemote));
```

If the API already gives structured location data (`isoCountry`, `isRemote`),
filter directly on those fields before passing through `parseLocation`.

### external_id format when promoting from ats-ingest

**Do NOT change the external_id format.** Changing it churns every existing row:
old ids hit `missing_syncs → removed`, new ids insert as phantom duplicates.

Check what ats-ingest produced for this provider:
```javascript
// e.g. ats-ingest produced:
external_id: `gem-${slug}-${o.extId ?? o.id}`
// → adapter must produce the same:
externalId: `gem-${slug}-${posting.extId ?? posting.id}`
```

The `slug` in both cases is the REAL BOARD SLUG (from CSV `slug` column or
derivable from `jobs.source_url`).

---

## 2. Add to DB + TS enum — `src/db/schema.ts`

If the provider value already exists in the DB enum (check with
`\dT+ ats_provider` in psql) but NOT in the TS union:

```typescript
// No migration needed — just append to the array
export const atsProviderEnum = pgEnum('ats_provider', [
  // ... existing values ...
  // Gem ATS — value pre-existed in DB enum (migration 0012); added to TS union
  // June 2026 when per-account adapter replaced the ats-ingest.ts coverage path.
  'gem',
]);
```

If the value is NEW (not in DB enum): create a migration SQL file
`job_feed/src/db/migrations/NNNN_add_<provider>.sql`:
```sql
ALTER TYPE ats_provider ADD VALUE IF NOT EXISTS 'gem';
```

---

## 3. Register in `src/adapters/index.ts`

```typescript
import { gemAdapter } from './gem.js';

export const adapters: Record<AtsProvider, AtsAdapter | null> = {
  // ... existing entries ...
  gem: gemAdapter,
  // ...
};
```

The `Record<AtsProvider, ...>` constraint is exhaustive — TypeScript will error
if the new enum value is missing. This is intentional.

---

## 4. Retire from `scripts/ats-ingest.ts`

Remove the provider from the `SOURCES` array. Keep the fetch function in the file
as a comment tombstone or just replace the entry with a comment:

```typescript
const SOURCES: SourceDef[] = [
  // gem retired June 2026 — owned by the pipeline adapter src/adapters/gem.ts
  // (accounts seeded from src/seed/data/gem-companies.json). Account slugs were
  // renamed from 'gem-{boardSlug}' to '{boardSlug}' before seeding.
  { name: "recruiterbox", ... },
  ...
];
```

**Never leave two writers live** — it creates duplicate accounts and jobs
(`upsertPgJob` + pipeline racing on the same `(ats_account_id, external_id)` key).

---

## 5. Create seed data `src/seed/data/<provider>-companies.json`

Format (same as `rippling-companies.json`):
```json
[
  { "name": "Company Name", "slug": "real-board-slug" },
  ...
]
```

Slugs must be the **real board/tenant slug** the adapter fetches with — NOT the
synthetic `${provider}-${normalized-name}` that ats-ingest created.

Generate from the CSV seed file:
```python
python3 -c "
import csv, json
rows = []
with open('scripts/ats-seeds/<provider>.csv') as f:
    for row in csv.DictReader(f):
        rows.append({'name': row['name'].strip(), 'slug': row['slug'].strip()})
with open('src/seed/data/<provider>-companies.json', 'w') as f:
    json.dump(rows, f, indent=2); f.write('\n')
print(len(rows))
"
```

---

## 6. Add to `src/seed/companies.ts` PROVIDER_FILE_MAP

```typescript
const PROVIDER_FILE_MAP: Record<string, AtsProvider> = {
  // ... existing entries ...
  'gem-companies.json': 'gem',
};
```

---

## 7. Update pg_reports coverage SQL

> **OBSOLETE 2026-07** — pg_reports removed entirely (`d09c96c8`); skip this
> step. Verify the promoted provider via the SKILL.md funnel-step-1 fleet
> query after its first sync instead.

`pg_reports/custom_reports/sql/adapters/adapter_coverage.sql` — add the provider
to the VALUES list. The third column is `has_seed_file` (true/false):

```sql
    ('gem',  'ats', true),   -- pipeline adapter + seed file
```

> Note: this SQL is baked into the pg_reports container image at build time.
> The file edit will be correct on the NEXT rebuild. To see it immediately,
> run the SQL directly via psql. Ask Jon before triggering a rebuild.

---

## 8. Rename existing lazy accounts (critical for ats-ingest promotions)

Lazy accounts from `upsertPgJob` have synthetic slugs:
`${provider}-${normalizedName.replace(/\s+/g, '-')}` (e.g. `gem-airvet-com`).

The real board slug is recoverable from `jobs.source_url`:

```sql
-- Verify: every account has exactly one board slug
SELECT caa.slug, COUNT(DISTINCT regexp_replace(j.source_url, 'https://jobs\.<provider>\.com/', '')) AS distinct_boards
FROM company_ats_accounts caa JOIN jobs j ON j.ats_account_id = caa.id
WHERE caa.provider = 'gem' GROUP BY caa.slug HAVING COUNT(...) > 1;
-- Must return 0 rows before proceeding

-- Preview mapping:
SELECT caa.slug, regexp_replace(j.source_url, 'https://jobs\.gem\.com/', '') AS board_slug
FROM company_ats_accounts caa JOIN jobs j ON j.ats_account_id = caa.id
WHERE caa.provider = 'gem' GROUP BY caa.slug, 2;

-- Rename (adapt URL pattern to provider):
UPDATE company_ats_accounts
SET slug = substring(slug FROM 5)   -- strips 'gem-' prefix (4 chars)
WHERE provider = 'gem' AND slug LIKE 'gem-%';
```

Adjust the strip expression if the synthetic slug prefix differs from `gem-`.

---

## 9. Typecheck

```bash
# job_feed — in Docker (host OOM on direct tsc -b):
docker run --rm --memory=1g --network=host \
  -v /opt/stacks/saas-starter/job_feed:/w -w /w \
  node:22-bookworm-slim npx tsc --noEmit

# backend (src/) — runs fine on host:
cd /opt/stacks/saas-starter && bun x tsc --noEmit
```

Known pre-existing error to ignore: `eightfold.ts` `Cannot find name 'Bun'`.
Empty stdout = zero errors = success.

---

## 10. Smoke test (before seeding)

```bash
cd /opt/stacks/saas-starter/job_feed
cat > /tmp/t.mts << 'TS'
import { gemAdapter } from '/opt/stacks/saas-starter/job_feed/src/adapters/gem.ts';
const slug = '<small-real-board-slug>';
const jobs = await gemAdapter.fetchJobs(slug);
console.log(`Fetched ${jobs.length} jobs`);
for (const j of jobs.slice(0, 3))
  console.log('-', j.externalId, '|', j.title, '|', j.locations.map(l => l.country).join(','));
TS
npx tsx /tmp/t.mts
```

Must use `.mts` (not `.ts`) and absolute import path. Verify:
- `externalId` format matches existing DB rows (no churn)
- All locations resolve to `country: 'US'` or `isRemote: true`
- `jobs.length > 0` (the board is genuinely open)

---

## 11. Update admin route comment — `src/routes/admin-jobfeed.ts`

Move the provider from the ats-ingest comment block to the pipeline section:

```typescript
const ATS_PROVIDERS = [
  // ... main pipeline adapters ...
  // Pipeline adapters promoted from ats-ingest (rippling June 2026, gem June 2026).
  "rippling", "gem",
  // ats-ingest coverage-only (no pipeline adapter):
  "recruiterbox",
  // ...
];
```

---

## 12. Post-deploy: seed

```bash
docker exec job_feed_node tsx src/cli/seed.ts gem-companies.json
```

This creates/activates all N board accounts with real slugs. Run AFTER the slug
rename (step 8) to avoid creating duplicate accounts.

---

## Files changed — quick reference

| File | Change |
|---|---|
| `job_feed/src/adapters/<provider>.ts` | **CREATE** — new adapter |
| `job_feed/src/adapters/index.ts` | import + register in `adapters` record |
| `job_feed/src/db/schema.ts` | append to `atsProviderEnum` array |
| `job_feed/src/seed/companies.ts` | add to `PROVIDER_FILE_MAP` |
| `job_feed/src/seed/data/<provider>-companies.json` | **CREATE** — 496-entry board list |
| `job_feed/scripts/ats-ingest.ts` | retire provider from `SOURCES` |
| ~~`job_feed/pg_reports/...adapter_coverage.sql`~~ | OBSOLETE — pg_reports removed (`d09c96c8`) |
| `src/routes/admin-jobfeed.ts` | update `ATS_PROVIDERS` comment |
