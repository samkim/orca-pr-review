# shellcheck shell=bash
# Ledger of dispatched reviews for one repo, keyed by PR number.
#   ledger get <pr>
#   ledger set <pr> <state> [key=value ...]   state: dispatched|reviewed|failed|submitted
#                                             keys: lower_snake, not state or at
#   ledger in-flight                          non-stale dispatched entries
#   ledger dump

# Run "$@" holding the ledger lock. Released explicitly rather than by trap so
# callers that hold their own lock (dispatch) keep their trap.
ledger_with_lock() {
  local rc
  for _ in $(seq 1 30); do
    if mkdir "$LOCK_DIR.ledger" 2>/dev/null; then
      rc=0; "$@" || rc=$?
      rmdir "$LOCK_DIR.ledger" 2>/dev/null || true
      return $rc
    fi
    # A holder that died leaves the directory behind; it is never held for long.
    if [ -n "$(find "$LOCK_DIR.ledger" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
      rmdir "$LOCK_DIR.ledger" 2>/dev/null || true
    fi
    sleep 1
  done
  log "ledger lock busy for 30s; giving up"; return 1
}

# ledger_check_set <pr> <state> [k=v ...]: die unless the arguments are a
# valid ledger write. `state` and `at` are written only by ledger_set_locked:
# readers parse `at` as a timestamp, and select keys off `state`.
ledger_check_set() {
  local pr="$1" state="$2" kv key; shift 2
  [[ "$pr" =~ ^[1-9][0-9]*$ ]] || die "ledger: not a PR number: '$pr'"
  case "$state" in dispatched|reviewed|failed|submitted) ;;
    *) die "ledger: unknown state '$state' (dispatched|reviewed|failed|submitted)" ;;
  esac
  for kv in "$@"; do
    [[ "$kv" == *=* ]] || die "ledger: expected key=value, got '$kv'"
    key="${kv%%=*}"
    [[ "$key" =~ ^[a-z_][a-z0-9_]*$ ]] || die "ledger: bad key '$key' (lower_snake)"
    case "$key" in state|at) die "ledger: '$key' is set by the ledger itself" ;; esac
  done
}

ledger_set_locked() {
  # In a subshell so a bad write returns (and the caller frees the lock).
  ( ledger_check_set "$@" ) || return 1
  local pr="$1" state="$2"; shift 2
  local args=(--arg pr "$pr" --arg state "$state" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
  local filter='.[$pr] = ((.[$pr] // {}) + {state: $state, at: $at}'
  local kv n=0
  for kv in "$@"; do
    args+=(--arg "k$n" "${kv%%=*}" --arg "v$n" "${kv#*=}")
    filter+=" + {(\$k$n): \$v$n}"
    n=$((n + 1))
  done
  filter+=')'
  local tmp; tmp=$(mktemp "$STATE_DIR/ledger.XXXXXX")
  jq "${args[@]}" "$filter" "$LEDGER" > "$tmp" && mv "$tmp" "$LEDGER"
}

# ledger_mark_removed <pr>: note that the entry's worktree was deleted. Leaves
# state and at alone: `at` drives re-review triggers, so it must not move.
ledger_mark_removed() {
  local tmp
  tmp=$(mktemp "$STATE_DIR/ledger.XXXXXX") || return 1
  if ! jq --arg pr "$1" '.[$pr].worktree_removed = "true"' "$LEDGER" > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  mv "$tmp" "$LEDGER"
}

# ledger_attempt <pr> <sha> <round>: the attempt number a dispatch of this
# round at this head would be. 1, unless the entry is a failure of the same
# round at the same head, then one more than its attempt. Select uses it to
# retry a failed re-review at an unchanged head only once.
ledger_attempt() {
  local entry
  entry=$(ledger_get "$1") || return 1
  [ -n "$entry" ] || { echo 1; return 0; }
  jq -r --arg sha "$2" --arg round "$3" '
    if .state == "failed" and .sha == $sha and ((.round // "1") | tostring) == $round
    then ((.attempt // "1") | tonumber) + 1 else 1 end' <<<"$entry"
}

# ledger_expire_stale_locked: record every dispatched entry older than
# STALE_HOURS as failed (stage=session), so selection and `dispatch --pr` can
# retry it. Call under ledger_with_lock. Prints the PR numbers it changed.
# A malformed `at` (hand-edited ledger) parses as 0, so the entry counts as
# stale: in-flight skips it and expiry turns it into failed, which select can
# retry, instead of one bad entry failing every run for the repo.
LEDGER_AT='(.value.at | try fromdateiso8601 catch 0)'

ledger_expire_stale_locked() {
  local tmp stale pr
  stale=$(jq -r --argjson h "$STALE_HOURS" '
    to_entries[] | select(.value.state == "dispatched")
    | select((now - '"$LEDGER_AT"') >= ($h * 3600)) | .key' "$LEDGER") || return 1
  [ -n "$stale" ] || return 0
  tmp=$(mktemp "$STATE_DIR/ledger.XXXXXX")
  if ! jq --argjson h "$STALE_HOURS" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    with_entries(if .value.state == "dispatched"
        and (now - '"$LEDGER_AT"') >= ($h * 3600)
      then .value += {state: "failed", at: $at, stage: "session",
                      reason: "no terminal state after \($h)h"}
      else . end)' "$LEDGER" > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  mv "$tmp" "$LEDGER"
  for pr in $stale; do printf '%s\n' "$pr"; done
}

ledger_get() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] || die "ledger: not a PR number: '${1:-}'"
  jq --arg pr "$1" '.[$pr] // empty' "$LEDGER"
}

ledger_in_flight() {
  local bad
  bad=$(jq -r '[to_entries[] | select(.value.state == "dispatched")
      | select((.value.at | try fromdateiso8601 catch null) == null) | .key] | join(" ")' "$LEDGER") || return 1
  [ -z "$bad" ] || log "ledger: malformed 'at' on PR(s) $bad; counted as stale, not in flight"
  jq --argjson h "$STALE_HOURS" '
    [to_entries[] | select(.value.state == "dispatched")
      | select((now - '"$LEDGER_AT"') < ($h * 3600))] | length' "$LEDGER"
}

cmd_ledger() {
  case "${1:-}" in
    get) [ -n "${2:-}" ] || die "usage: ledger get <pr>"; ledger_get "$2" ;;
    set) shift; [ $# -ge 2 ] || die "usage: ledger set <pr> <state> [k=v ...]"
         ledger_check_set "$@"
         ledger_with_lock ledger_set_locked "$@" ;;
    in-flight) ledger_in_flight ;;
    dump) jq . "$LEDGER" ;;
    *) die "usage: ledger get|set|in-flight|dump" ;;
  esac
}
