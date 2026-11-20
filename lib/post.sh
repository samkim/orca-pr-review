# shellcheck shell=bash
# post <pr> <review.json>
# Post a PENDING GitHub review: unsubmitted, visible only to the gh user until
# they submit it. review.json:
#   {"commit_id": "<sha>", "body": "<markdown>",
#    "comments": [{"path": "...", "line": N, "side": "RIGHT", "body": "..."}],
#    "replies": [{"thread_id": "<review thread node id>", "body": "..."}]}
# replies is optional (re-reviews): each becomes a reply in an existing thread,
# part of the same pending review. A reply that cannot be added is folded into
# the body instead.
# Exit: 0 posted, 3 a pending review by this user already exists (nothing posted), 1 error.

# post_replies <created-review-json> <payload>: add the payload's thread replies
# to the new pending review; fold any that fail into its body.
post_replies() {
  local created="$1" payload="$2" n i node tid body failed="[]" out
  n=$(jq '.replies // [] | length' <<<"$payload")
  [ "$n" -gt 0 ] || return 0
  node=$(jq -r .node_id <<<"$created")
  for ((i = 0; i < n; i++)); do
    tid=$(jq -r ".replies[$i].thread_id" <<<"$payload")
    body=$(jq -r ".replies[$i].body" <<<"$payload")
    if out=$(gh api graphql \
        -f query='mutation($r:ID!,$t:ID!,$b:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewId:$r,pullRequestReviewThreadId:$t,body:$b}){comment{databaseId}}}' \
        -f r="$node" -f t="$tid" -f b="$body" 2>&1) && jq -e '.data.addPullRequestReviewThreadReply.comment.databaseId' <<<"$out" >/dev/null 2>&1; then
      :
    else
      log "reply to thread $tid failed: $(echo "$out" | head -2)"
      failed=$(jq --argjson r "$(jq ".replies[$i]" <<<"$payload")" '. + [$r]' <<<"$failed")
    fi
  done
  echo "added $((n - $(jq length <<<"$failed")))/$n thread replies"
  [ "$(jq length <<<"$failed")" -gt 0 ] || return 0
  body=$(jq -r --argjson f "$failed" '.body + "\n\n---\n**Replies to earlier threads** (could not be added to the threads):\n\n"
    + ([$f[] | "### thread `\(.thread_id)`\n\n\(.body)"] | join("\n\n"))' <<<"$created")
  if ! gh_retry api graphql \
    -f query='mutation($id:ID!,$b:String!){updatePullRequestReview(input:{pullRequestReviewId:$id,body:$b}){pullRequestReview{id}}}' \
    -f id="$node" -f b="$body" >/dev/null; then
    log "could not fold replies into the body either"; return 1
  fi
  echo "folded $(jq length <<<"$failed") replies into the body"
}

cmd_post() {
  local pr="${1:-}" file="${2:-}" payload me pending out folded
  [ -n "$pr" ] && [ -f "$file" ] || die "usage: post <pr> <review.json>"
  require_pr "$pr"
  jq -e '.commit_id and .body and (.comments | type == "array")
         and ((.replies // []) | type == "array" and all(.[]; .thread_id and .body))' "$file" >/dev/null \
    || die "$file is missing commit_id, body or comments, or has a reply without thread_id and body"
  # GitHub treats an "event" field as a submit. Strip it so the review stays pending.
  # replies are not a REST field; post_replies adds them afterwards.
  payload=$(jq 'del(.event)' "$file")

  me=$(gh_retry api user -q .login)
  # --paginate prints one array per page; -q would run per page. Slurp instead.
  pending=$(gh_retry api "repos/$REPO_SLUG/pulls/$pr/reviews" --paginate \
    | jq -s --arg me "$me" '[.[][] | select(.state == "PENDING" and .user.login == $me)] | length')
  if [ "$pending" != "0" ]; then
    log "PR #$pr already has a pending review from $me; not posting"; return 3
  fi

  if out=$(jq 'del(.replies)' <<<"$payload" | gh api -X POST "repos/$REPO_SLUG/pulls/$pr/reviews" --input - 2>&1); then
    jq -r '"posted pending review \(.id) state=\(.state) \(.html_url)"' <<<"$out"
    post_replies "$out" "$payload"; return $?
  fi
  log "inline post failed: $(echo "$out" | head -3)"

  # Usually a comment on a line outside the diff. Fold every inline comment into the body.
  folded=$(jq '{commit_id, comments: [], replies,
    body: (.body + "\n\n---\n**Line comments** (could not be anchored to the diff):\n\n"
      + ([.comments[] | "### `\(.path):\(.line)`\n\n\(.body)"] | join("\n\n")))}' <<<"$payload")
  if out=$(jq 'del(.replies)' <<<"$folded" | gh api -X POST "repos/$REPO_SLUG/pulls/$pr/reviews" --input - 2>&1); then
    jq -r '"posted pending review \(.id) state=\(.state) (comments folded into body) \(.html_url)"' <<<"$out"
    post_replies "$out" "$folded"; return $?
  fi
  log "folded post failed too: $out"; return 1
}

# backfill: called by a review session when it finishes. Starts the repo's
# automation now if a slot opened and PRs are waiting, instead of waiting for
# the next scheduled run. Bypasses the automation precheck, so it checks first.
cmd_backfill() {
  if [ -z "${AUTOMATION_ID:-}" ]; then
    log "no AUTOMATION_ID for $REPO_SLUG; backfill disabled (run install-automation)"; return 0
  fi
  # `automations run` works on a disabled automation, so honor a pause here.
  # (Not `.enabled // "unknown"`: jq's // treats false as missing.)
  local enabled
  enabled=$(orca automations show --id "$AUTOMATION_ID" --json 2>/dev/null \
    | jq -r '(.result.automation // .result).enabled | if . == null then "unknown" else tostring end' 2>/dev/null) || enabled=unknown
  if [ "$enabled" = "false" ]; then
    log "automation $AUTOMATION_ID is disabled; no backfill"; return 0
  fi
  if ! in_window; then
    log "outside the review window; the next scheduled run picks up remaining PRs"; return 0
  fi
  if ! cmd_select --check; then
    log "nothing waiting, or no free slot; no backfill"; return 0
  fi
  # Exit with orca's status. If formatting fails, print the raw output instead.
  local out rc=0
  out=$(orca automations run "$AUTOMATION_ID" --json) || rc=$?
  jq -c '{ok, run: (.result.run.id // .result.id // null), error}' <<<"$out" 2>/dev/null \
    || printf '%s\n' "$out"
  return "$rc"
}
