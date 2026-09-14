# Firstmate × HiringHaus — Setup & Operating Instructions

Set up 2026-08-04. Firstmate is an agent-crew orchestrator: you talk to one
coordinator session (the "first mate"), and it dispatches worker agents
("crewmates") into isolated git worktrees inside tmux windows, supervises them
with a low-token bash watcher, and delivers finished work back to you.

This install is configured so firstmate work on HiringHaus **never touches your
live checkout or your normal Claude sessions**.

---

## Why it can't interfere with normal sessions

| Surface | How it's isolated |
|---|---|
| Working tree | Firstmate has its **own clone** at `~/firstmate/projects/hiringhaus` (cloned from `github.com/Jnelsonwis/wh`). Crewmates work in throwaway worktrees off that clone. `/opt/stacks/saas-starter` is never read or written. |
| Claude hooks | All firstmate hooks live in `~/firstmate/.claude/settings.json` and reference `$CLAUDE_PROJECT_DIR` — they only fire for sessions launched from `~/firstmate`. Your saas-starter sessions are untouched. |
| Sync channel | GitHub is the only bridge. Firstmate lands work into its clone's `main` and pushes `origin main`; your live tree picks it up with a normal `git pull` whenever you choose. |
| Runtime | Crew worktrees have no `.env`, no live SQLite, no containers — so crewmates physically cannot start servers, migrate the DB, or touch Docker. Captain preferences also forbid `bun run dev|build|start`, `bun run db:*`, and `docker compose` outright. |
| Terminal | Crew runs in a separate tmux session named `firstmate` (windows `fm-<id>`), not in your VS Code terminals. |

Delivery mode is registered as **`local-only`** — no PRs (matches your solo,
main-only workflow). Crew branch → guarded local fast-forward into the clone's
`main` → push to origin.

**Two projects are registered**: `hiringhaus` (the saas-starter monorepo) and
`hiringhaus-extension` (Chrome autofill extension, cloned from
`Jnelsonwis/warmhand-extension`; its live checkout
`/opt/stacks/hiringhaus-extension` is equally off-limits to crew). Both
local-only, both GitHub-synced.

## Subject routing — how briefs get their special instructions

`data/hiringhaus-routing.md` is the routing table. A captain-preference mandate
makes the first mate read it at intake for every hiringhaus/extension task and
paste the matching blocks into the crewmate's brief:

- **UNIVERSAL** block — ground rules in every brief (read CLAUDE.md first,
  forbidden commands, verification commands, RTK, SESSION_LOG.md, commit style).
- **SUBJECT** blocks — one per domain, mirroring your normal-session delegation
  routes: `frontend` (design-system traps, MOBILE_AUDIT, pill rule, Phosphor),
  `backend` (router mounting, Zod placement, contracts), `auth` (better-auth
  v1.5 rules), `billing` (gate inventory discipline), `database` (SQLite
  migration *authoring only* + captain-apply handoff), `job_feed` (Postgres
  traps: provider-scoped external_id, FK indexing, aggregator fan-out no-op,
  workday/rippling/parseSalary gotchas, Windmill author-never-apply), `tests`
  (scoped suite, mock.module restore), `extension` (token auth, kill-switch,
  Chrome-137 E2E caveat).
- **Cross-cutting order**: database → backend/billing/auth → frontend, same as
  your agent-team order.
- **OUT OF SCOPE list** — the first mate refuses these instead of dispatching:
  applying migrations, Docker, deploys, `.env`, live Windmill/n8n, live DB
  queries, monitoring, CWS.

Why the doc exists at all: `.claude/skills/` is gitignored, so crew worktrees
lack the project skills your normal sessions have — the routing blocks carry
that knowledge (sourced from CLAUDE.md + your session memory) into each brief.

Maintain it like memory: when you confirm a new trap in a normal session, add a
line to the matching subject block in
`~/firstmate/data/hiringhaus-routing.md` (or ask the first mate to).

---

## Install state — complete, smoke-tested 2026-08-04

Everything required is installed and verified: firstmate cloned, **treehouse
v2.1.1** (worktree provider), `tasks-axi` 0.2.4 + `quota-axi` 0.1.17, both
project clones registered, captain preferences written, `gh` auth verified,
tmux 3.4 present. A headless `captain -p` smoke test booted the first mate:
session-start ran, it reported both projects, the Opus 4.8 model mandate, the
tmux backend, and correct watcher state.

Optional tools firstmate will mention as `MISSING` at session start —
**safe to ignore for local-only work**: `no-mistakes` (PR validation pipeline;
runs a daemon), `gh-axi` / `chrome-devtools-axi` / `lavish-axi` (PR + browser
tooling; their `setup hooks` step edits hook config). They were deliberately
skipped to keep this box clean. Install later only if you switch hiringhaus to
a PR-based delivery mode.

---

## Launching — the first mate is PERSISTENT

The first mate lives in a long-running tmux session named `captain`, started
at boot by a systemd user service (`captain.service`; linger is on). It
survives SSH drops, VS Code restarts, and your Windows machine sleeping —
detaching does not stop it, and its Stop-hook watcher keeps supervising crew
while you're away. An idle first mate costs nothing.

```bash
captain            # attach from any directory / any terminal (recreates if needed)
                   # detach: Ctrl-b d  — first mate keeps running
captain status     # is the captain up? any crew windows?
captain kill       # end the session (systemd restarts it at next boot, or run `captain`)
captain --here     # one-off claude in the current terminal instead (args pass through)
```

From the Claude Code app / VS Code on Windows: open a terminal to this box and
run `captain` — you land in the same ongoing session every time. If claude was
exited inside the session, plain `captain` relaunches it. Conversation
continuity across relaunches: run `captain kill`, then `captain -c`
(continues the last conversation in `~/firstmate`); firstmate's own state
(registry, backlog, task meta) is file-based and survives regardless.

Service control: `systemctl --user {status|restart|stop|disable} captain.service`.

## Mobile access

The Claude mobile app's Code tab runs **cloud sandboxes against GitHub repos**
— it cannot attach to the captain session on this box. Three lanes:

1. **Talk to the captain from your phone (the real thing):** any SSH client
   app (Termius, Blink, JuiceSSH) → connect to this box the same way VS Code
   does → run `captain`. You land in the same persistent session; tmux
   tolerates mobile network drops perfectly (reconnect + `captain` again).
2. **Get pinged without asking (outbound):** captain preference tells the
   first mate to DM you on Mattermost (mobile push) when a delivery is ready,
   something is blocked, or a decision is needed — one DM per event, no spam.
   Conditional on the Mattermost MCP tools being visible in its session; ask
   the first mate "can you DM me on Mattermost?" once to confirm, and it
   records the answer in `data/learnings.md`.
3. **Claude mobile app Code tab (cloud, bypasses firstmate):** fine for quick
   standalone edits — point it at `Jnelsonwis/wh`, work lands on GitHub as a
   branch/PR, and the firstmate clone or your live tree pulls it later. Don't
   use it for anything needing the fleet, the box, or live infra.

## Mattermost bridge — chat with the captain from your phone (WORKING, verified 2026-08-04)

`captain-bridge` runs as a systemd user service (enabled, listening on
`0.0.0.0:8767`, token-gated — everything 403s until configured). Flow:

- **You → captain**: post in a Mattermost channel → outgoing webhook →
  bridge pastes the message into the captain tmux pane (instant "delivered to
  captain" ack in the channel) → captain answers.
- **Captain → you**: it appends replies (and away-notifications: deliveries
  ready, blockers, decisions needed) to `~/firstmate/state/bridge-outbox.md`;
  the bridge posts every append to your incoming webhook → phone push.

Inbound + outbox loop already smoke-tested end-to-end (captain received an
injected message and wrote the reply). Only the Mattermost side remains —
one-time, in the Mattermost UI:

1. Create a channel for it, e.g. `captain` (public — outgoing webhooks need
   public channels). Mute it for others if you like; it's your server.
2. **Main menu → Integrations → Outgoing Webhooks → Add**: channel `captain`,
   no trigger words (fires on every post), callback URL
   `http://172.16.27.1:8767/inbound` (that's this host from inside the
   mattermost container; `http://172.23.0.1:8767/inbound` also works).
   Copy the token it generates.
3. **Integrations → Incoming Webhooks**: create one for the `captain` channel
   (or reuse an existing one) and copy its URL.
4. Paste both into `~/firstmate/config/mattermost-bridge.json` (replacing the
   PASTE_ placeholders). No restart needed — config is re-read continuously.
5. Test from your phone: post "status?" in the channel → ack appears →
   captain's reply follows.

Notes: the bridge ignores bot/webhook posts (no loops), strips a leading
"captain:" if you use one, and replies "captain session is down" if the tmux
session isn't running. Logs: `~/firstmate/state/bridge.log`. Service:
`systemctl --user status captain-bridge`. `AGENTS.md` loads
automatically and the session becomes the first mate. Your global config
(RTK hook, caveman mode, Agent-Monitor hooks) still applies — that's fine and
expected.

Then just talk to it:

```
> ahoy — in hiringhaus, add a loading skeleton to the supporter dashboard, and
  separately fix the flaky date formatting in ReferralTimeline. Two crewmates.
```

Useful asks once crew is running:

- "status" / "bearings" — fleet snapshot
- `tmux attach -t firstmate` — watch crewmates live (detach: `Ctrl-b d`)
- "peek at fm-3" — see a crewmate's recent output
- "land fm-3" — review + guarded fast-forward merge into the clone's `main`, then push

## Daily flow

1. **Before dispatching**: say "sync hiringhaus first" (it runs
   `git pull --ff-only` in the clone) — keeps crew off stale code when you've
   pushed from the live tree.
2. Dispatch tasks in plain language; one crewmate per independent task.
3. Review deliveries; approve landings. Landed work is pushed to `origin main`
   (pre-authorized in captain prefs).
4. In your **normal** session / live tree, `git pull` when you want the
   changes on the box. If your live tree has local commits, it's a normal
   merge/rebase — same as your existing multi-session flow.

## What to route where

| Task | Where |
|---|---|
| Parallel/background feature work, refactors, test writing, docs | **Firstmate** |
| Anything needing the live dev server on :3000, UI verification, screenshots | Normal session (your rule: Jon verifies UI in his own dev server) |
| DB migrations, `db:push`, Docker, deploys, Windmill/n8n/job_feed ops | Normal session — worktrees lack `.env` + live DBs by design |
| Hotfix you want on the box *right now* | Normal session (firstmate adds a GitHub round-trip) |

## Model policy — everything runs Claude Opus 4.8

| Role | Mechanism | File |
|---|---|---|
| First mate (the `captain` session) | Claude Code project setting `"model": "claude-opus-4-8"` — untracked, survives firstmate updates | `.claude/settings.local.json` |
| Crewmates / scouts | Captain-preference mandate: firstmate passes `--model claude-opus-4-8` on every spawn (crew harness pinned to `claude` in `config/crew-harness`; that file can't carry a model by design) | `data/captain.md` (mandate) |
| Secondmates (future) | `claude claude-opus-4-8` harness+model tokens | `config/secondmate-harness` |

Override per task by telling the first mate ("run this one on sonnet"), or
change the default by editing the files above. Your normal saas-starter
sessions are untouched — nothing here writes to global `~/.claude` config.

## Hook wiring (audited 2026-08-04 — nothing to install)

Two hook surfaces, both verified correct:

**First mate** (`~/firstmate/.claude/settings.json`, ships with the repo — all
scripts executable, syntax-checked, SessionStart nudge smoke-tested):
- `SessionStart` → session-start digest nudge
- `PreToolUse` → arm-check + cd-guard + subagent-guard (keeps the first mate
  in its home and off raw fleet commands)
- `Stop` → turn-end guard + **asyncRewake auto-arm** — this is the tokenless
  watcher: every turn end re-arms `bin/fm-watch.sh`, and watcher findings wake
  the first mate via Stop-hook feedback. Supervision costs no model tokens
  while parked.

**Crewmates** need *no* firstmate hooks — supervision is external (watcher +
tmux). What they do inherit:
- Hiringhaus repo's tracked `.claude/settings.json` — hooks are all
  worktree-relative (`$CLAUDE_PROJECT_DIR`), helpers tracked; SessionEnd
  writes the worktree's SESSION_LOG.md (never staged, per captain rule);
  Stop/Notification fire your desktop `notify.sh` pings per crew turn-end
  (self-dismissing; silent when headless). Expect pings when crew runs.
- Your global config: RTK Bash rewrite, the global Grep-tool deny (crew briefs
  now tell them to `rg` via Bash), Agent-Monitor handlers (crew appears in
  your monitor), caveman style. All intentional; briefs also tell crew not to
  detour into brainstorming/superpowers flows hooks may suggest.

Fleet-local detail lives in `~/firstmate/data/learnings.md`.

## Guardrails already registered (edit in `data/captain.md`)

- Never touch `/opt/stacks/saas-starter` (= `/home/jon/stacks/saas-starter`).
- No `bun run dev|build|start`, no `bun run db:*`, no `docker compose` — ever.
- Verification = `bun x tsc --noEmit` (root + `frontend/`), scoped
  `bun test ./tests/ ./src/` when relevant; `bun install` in worktrees OK.
- Crew reads repo `CLAUDE.md` before coding; RTK protocol in every brief.
- Never stage `SESSION_LOG.md` (your global SessionEnd hook writes it in every
  worktree); explicit-pathspec staging only.
- Crew branches deleted after landing; `main` is the only durable branch.

## Maintenance

- **Update firstmate**: ask the first mate to "update firstmate", or
  `git -C ~/firstmate pull` when the fleet is idle. Your local files
  (`INSTRUCTIONS.md`, `data/`, `config/`, `projects/`) are untracked/gitignored
  and survive updates.
- **Teardown a stuck crewmate**: ask "tear down fm-<id>", or see
  `bin/fm-teardown.sh`.
- **Nuke everything crew-related**: kill the tmux session
  (`tmux kill-session -t firstmate`) — the live tree is unaffected by
  construction.

## Paths

| What | Where |
|---|---|
| Firstmate install (+ this file) | `/home/jon/firstmate/` |
| Hiringhaus clone (firstmate's copy) | `/home/jon/firstmate/projects/hiringhaus/` |
| Extension clone (firstmate's copy) | `/home/jon/firstmate/projects/hiringhaus-extension/` |
| Project registry | `/home/jon/firstmate/data/projects.md` |
| Captain preferences (the guardrails) | `/home/jon/firstmate/data/captain.md` |
| Subject routing table (brief instructions per domain) | `/home/jon/firstmate/data/hiringhaus-routing.md` |
| Task state / logs | `/home/jon/firstmate/state/` |
| Live checkouts (never touched by firstmate) | `/opt/stacks/saas-starter/`, `/opt/stacks/hiringhaus-extension/` |
