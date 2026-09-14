#!/usr/bin/env bash
# tests/fm-classify-lib.test.sh - unit tests for the shared crewmate wake
# classifier (bin/fm-classify-lib.sh): the single source of truth for
# captain-relevant status tests, the durable keyed decision fold, the
# declared-external-wait vocabulary, and the provably-working absorb
# classification that decides whether an idle/stale crewmate is safely absorbed
# or must surface. Most functions are pure status-line/status-file reads; the
# absorb classification is exercised through a stubbed FM_CREW_STATE_BIN so no
# real worktree or no-mistakes install is required. No backend or harness needed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

# --- status-line verb / note / key parsers ----------------------------------

[ "$(status_line_verb 'done: shipped it')" = "done" ] || fail "leading verb of a plain line"
[ "$(status_line_verb 'needs-decision [key=api-shape]: which shape?')" = "needs-decision" ] \
  || fail "verb parser must strip the [key=...] token"
[ "$(status_line_verb '   working: still going')" = "working" ] || fail "verb parser must trim leading space"
[ "$(status_line_note 'blocked: waiting on creds')" = "waiting on creds" ] || fail "note is text after first colon"
[ "$(status_line_note 'no colon here')" = "no colon here" ] || fail "note falls back to whole line without a colon"
pass "status_line_verb/note parse the leading verb (stripping any [key=] token) and the trimmed note"

# --- captain-relevance is verb-aware ----------------------------------------

status_is_captain_relevant 'done: PR ready' || fail "done: must be captain-relevant"
status_is_captain_relevant 'needs-decision: pick one' || fail "needs-decision: must be captain-relevant"
status_is_captain_relevant 'blocked: stuck' || fail "blocked: must be captain-relevant"
status_is_captain_relevant 'failed: tests red' || fail "failed: must be captain-relevant"
# A nonterminal progress verb never becomes captain-relevant just because its
# prose contains a legacy free-text token.
! status_is_captain_relevant 'working: rebased onto merged #76' \
  || fail "a working: line must NOT match on the free-text token 'merged'"
! status_is_captain_relevant 'paused: waiting on upstream release, PR ready later' \
  || fail "a paused: line must never be captain-relevant"
# A legacy bare line with no leading terminal verb may still match a free-text token.
status_is_captain_relevant 'merged into main' || fail "legacy bare 'merged' line must match free-text token"
! status_is_captain_relevant '' || fail "an empty line is not captain-relevant"
pass "status_is_captain_relevant matches terminal verbs, ignores tokens inside working/paused, and honors legacy bare tokens"

# --- pause verb matches the leading verb only -------------------------------

status_is_paused 'paused: vendor rate-limit reset at 5pm' || fail "paused: leading verb must classify as paused"
! status_is_paused 'working: nothing is paused right now' \
  || fail "the word 'paused' in a reason must not false-match status_is_paused"
status_is_paused_or_captain_held 'captain-held: transferred to backlog' \
  || fail "captain-held: must classify as paused-or-held"
! status_is_paused_or_captain_held 'done: shipped' || fail "done: is neither paused nor captain-held"
pass "status_is_paused / status_is_paused_or_captain_held match only the leading verb"

# --- durable keyed decision fold --------------------------------------------
#
# The core contract: a needs-decision/blocked line OPENS a keyed decision, and a
# later UNRELATED terminal line must NOT clear it - only an explicit resolved /
# captain-held line carrying the same key closes it.

TMP=$(fm_test_tmproot fm-classify)
mkdir -p "$TMP"
STATUS="$TMP/task.status"

cat > "$STATUS" <<'EOF'
working: starting
needs-decision [key=api-shape]: which response shape?
working: continued other work
done: unrelated subtask finished
EOF
OPEN=$(status_open_decisions "$STATUS")
assert_contains "$OPEN" "api-shape" "an open decision survives a later unrelated done: line"
assert_contains "$OPEN" "needs-decision" "the open decision keeps its opening verb"
pass "status_open_decisions keeps a keyed decision open through a later unrelated terminal line"

cat > "$STATUS" <<'EOF'
needs-decision [key=api-shape]: which response shape?
resolved [key=api-shape]: went with the array form
EOF
OPEN=$(status_open_decisions "$STATUS")
[ -z "$OPEN" ] || fail "a matching resolved [key=...] line must close the decision, got: $OPEN"
pass "status_open_decisions closes a decision only via a resolved line carrying the same key"

cat > "$STATUS" <<'EOF'
needs-decision [key=api-shape]: which response shape?
needs-decision [key=db-index]: add a partial index?
resolved [key=api-shape]: array form
EOF
OPEN=$(status_open_decisions "$STATUS")
assert_not_contains "$OPEN" "api-shape" "the resolved key must be closed"
assert_contains "$OPEN" "db-index" "an unrelated key stays open when a different key is resolved"
pass "status_open_decisions tracks each decision key independently"

# A bare (no-token) line uses the 'default' key, preserving one-open-decision behavior.
cat > "$STATUS" <<'EOF'
blocked: waiting on a decision
resolved: decided
EOF
OPEN=$(status_open_decisions "$STATUS")
[ -z "$OPEN" ] || fail "a bare resolved: must close the default-key blocked decision, got: $OPEN"
pass "status_open_decisions folds bare lines under the default key"

# --- signal actionability over a file list ----------------------------------

ACTIONABLE="$TMP/actionable.status"
BENIGN="$TMP/benign.status"
printf 'working: still going\n' > "$BENIGN"
printf 'blocked: needs a credential\n' > "$ACTIONABLE"
# signal_files_actionable lives in bin/fm-watch.sh (it replaced
# signal_reason_is_actionable upstream in #3268). Sourcing the watcher returns
# before its runtime; a subshell keeps its globals and a throwaway STATE (no
# seen markers, so each whole file is classified) out of the rest of this file.
(
  export FM_STATE_OVERRIDE="$TMP/watch-state"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-watch.sh"
  signal_files_actionable "$BENIGN" "$ACTIONABLE" \
    || fail "a captain-relevant line anywhere in the list is actionable"
  ! signal_files_actionable "$BENIGN" "$TMP/task.turn-ended" \
    || fail "no captain-relevant .status line (and a skipped non-status arg) is not actionable"
) || exit 1
pass "signal_files_actionable is 0 iff some listed .status file carries a captain-relevant line"

# --- absorb classification via a stubbed crew-state reader -------------------
#
# crew_absorb_class shells out to FM_CREW_STATE_BIN for the authoritative
# current-state line. Stub it so the working/paused/none decision is exercised
# without a real crew: the stub answers by task id.

STUB="$TMP/crew-state-stub.sh"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  running) echo "state: working · source: run-step · ci queued" ;;
  busy)    echo "state: working · source: pane · typing" ;;
  waiting) echo "state: paused · source: status · vendor reset" ;;
  editor)  echo "state: working · source: composer · editing brief" ;;
  gone)    echo "state: unknown · source: endpoint · dead" ;;
  *)       echo "garbage not a state line" ;;
esac
EOF
chmod +x "$STUB"
export FM_CREW_STATE_BIN="$STUB"

[ "$(crew_absorb_class running)" = "working" ] || fail "run-step working must classify as working"
[ "$(crew_absorb_class busy)" = "working" ] || fail "a busy pane must classify as working"
[ "$(crew_absorb_class waiting)" = "paused" ] || fail "a paused current state must classify as paused"
# working but NOT from run-step/pane (e.g. a composer edit) is not the absorb-safe kind.
[ "$(crew_absorb_class editor)" = "none" ] || fail "working from a non run-step/pane source must classify as none"
[ "$(crew_absorb_class gone)" = "none" ] || fail "an unknown/dead crew must classify as none"
[ "$(crew_absorb_class '')" = "none" ] || fail "an empty id must classify as none"
crew_is_provably_working running || fail "crew_is_provably_working must be 0 for a run-step crew"
! crew_is_provably_working gone || fail "crew_is_provably_working must be 1 for a dead crew"
crew_is_paused waiting || fail "crew_is_paused must be 0 for a paused crew"
pass "crew_absorb_class maps the authoritative state line to working/paused/none and drives the provably-working predicate"

# signal_crew_provably_working absorbs only when EVERY referenced task is working.
signal_crew_provably_working "$TMP/running.status" "$TMP/busy.status" \
  || fail "all-working signal list must be provably working (absorb)"
! signal_crew_provably_working "$TMP/running.status" "$TMP/gone.status" \
  || fail "any non-working task in the list must surface"
! signal_crew_provably_working \
  || fail "an empty/unresolvable signal list must surface, never absorb"
pass "signal_crew_provably_working absorbs a no-verb signal only when every referenced crew is provably working"

echo "# fm-classify-lib.test.sh: all assertions passed"
