# shellcheck shell=bash
# select [--check|--all]
# Print the PRs to review as a JSON array, limited to free slots: re-reviews
# first (someone is waiting on them), then new PRs, newest first.
#   --check   exit 0 if at least one PR would be dispatched, else 1 (automation precheck)
#   --all     ignore the slot limit (inspection only)
# Reasons for skipping or waiting are printed on stderr.
# Each entry: {number, url, title, headRefOid, baseRefName, updatedAt,
#   kind: review|rereview, round, prevSha, trigger, worktree, trusted, trust}

# Trust rule. A PR is trusted when its head branch is in this repo (pushing a
# branch here needs write access) or its author is an OWNER, MEMBER or
# COLLABORATOR of the repo. Everything else (a fork PR from an outside
# contributor, a first-time contributor, a NONE association) is untrusted: it
# is not selected unless REVIEW_UNTRUSTED_PRS=1, and when it is reviewed the
# session is told not to execute any code from the checkout.

# TRUST_JQ: a jq definition shared by select and dispatch --pr.
# trust($cross; $assoc) -> {trusted, trust}, where trust is a short reason.
TRUST_JQ='def trust($cross; $assoc):
  ($assoc // "NONE") as $a
  | if ($cross | not) then {trusted: true, trust: "same-repo head branch"}
    elif ($a | IN("OWNER", "MEMBER", "COLLABORATOR")) then {trusted: true, trust: "fork PR by a repo \($a | ascii_downcase)"}
    else {trusted: false, trust: "fork PR by an outside author (association \($a))"} end;'

# pr_associations: {"<pr number>": "<author_association>"} for every open PR.
# gh pr list --json has no authorAssociation, so this reads the REST list.
pr_associations() {
  local out
  out=$(gh_retry api --paginate "repos/$REPO_SLUG/pulls?state=open&per_page=100" \
    -q '.[] | {key: (.number | tostring), value: .author_association}') || return 1
  jq -s 'from_entries' <<<"$out"
}

# pr_trust <pr>: {trusted, trust} for one PR, from its REST view.
pr_trust() {
  local out
  out=$(gh_retry api "repos/$REPO_SLUG/pulls/$1") || return 1
  jq "$TRUST_JQ"' trust((.head.repo.full_name // "") != .base.repo.full_name; .author_association)' <<<"$out"
}

# Everything since `since` that counts as a response to the user's review.
REREVIEW_QUERY='query($owner:String!,$name:String!,$n:Int!){repository(owner:$owner,name:$name){pullRequest(number:$n){
  headRefOid
  reviewThreads(first:100){nodes{comments(last:50){nodes{author{__typename login} createdAt}}}}
  comments(last:50){nodes{author{__typename login} createdAt}}
  timelineItems(last:100,itemTypes:[PULL_REQUEST_COMMIT,HEAD_REF_FORCE_PUSHED_EVENT]){nodes{
    __typename
    ... on PullRequestCommit{commit{committedDate}}
    ... on HeadRefForcePushedEvent{createdAt actor{__typename login}}}}}}}'

# rereview_activity <pr> <since> <prev-sha> <me> -> {moved, last, counts}
rereview_activity() {
  gh_retry api graphql -F owner="${REPO_SLUG%%/*}" -F name="${REPO_SLUG#*/}" -F n="$1" \
    -f query="$REREVIEW_QUERY" \
    | jq --arg since "$2" --arg prev "$3" --arg me "$4" '
      def human: . != null and .__typename != "Bot" and .login != $me;
      .data.repository.pullRequest as $p
      # Replies count only on threads the user took part in.
      | [ $p.reviewThreads.nodes[] | select(any(.comments.nodes[]; .author.login == $me))
          | .comments.nodes[] | select((.author | human) and .createdAt > $since) | .createdAt ] as $replies
      | [ $p.comments.nodes[] | select((.author | human) and .createdAt > $since) | .createdAt ] as $comments
      | [ $p.timelineItems.nodes[]
          | if .__typename == "PullRequestCommit" then .commit.committedDate
            elif (.actor | human) then .createdAt else empty end
          | select(. > $since) ] as $pushes
      | ($p.headRefOid != $prev) as $moved
      | { moved: $moved,
          # A moved head with no dated push (an old commit pushed late) counts as
          # activity, dated by the latest other event or not at all.
          last: (($replies + $comments + $pushes) | max),
          counts: {pushes: ($pushes | length), replies: ($replies | length), comments: ($comments | length)} }'
}

# select_complete_file_lists <candidates-json>: gh pr list stops at 100 files
# per PR. For each candidate it truncated that MAX_FILES still allows, read the
# full list with pr_files (lib/dispatch.sh, the list dispatch checks too) and
# check that instead. One extra paginated read per such PR, and only for those.
# If the full list cannot be read, the PR stays filesUnchecked and is skipped.
select_complete_file_lists() {
  local cands="$1" prs pr files hits
  prs=$(jq -r '.[] | select(.filesUnchecked and (.tooLarge | not)) | .number' <<<"$cands") || return 1
  for pr in $prs; do
    files=$(pr_files "$pr") || { log "#$pr: could not read its full file list"; continue; }
    hits=$(session_config_hits "$files") || { log "#$pr: could not check its full file list"; continue; }
    cands=$(jq --argjson n "$pr" --arg hits "$hits" '
      map(if .number == $n
          then .filesUnchecked = false
               | .sessionConfig = ($hits | split("\n") | map(select(. != "")))
          else . end)' <<<"$cands") || return 1
  done
  printf '%s' "$cands"
}

select_eligible() {
  local me raw assoc ledger_json existing_wt candidates first rereviews="[]" n i c act trigger hours
  # Without the login, SKIP_OWN_PRS and re-review detection silently stop working.
  me=$(gh_retry api user -q .login) || { log "cannot read the gh user"; return 1; }
  [ -n "$me" ] || { log "gh api user returned an empty login"; return 1; }
  raw=$(gh_retry pr list --repo "$REPO_SLUG" --state open --limit 200 \
    --json number,url,title,isDraft,author,updatedAt,headRefOid,headRefName,baseRefName,isCrossRepository,changedFiles,files,reviews,reviewRequests) \
    || { log "cannot list open PRs of $REPO_SLUG"; return 1; }
  assoc=$(pr_associations) || { log "cannot read PR author associations of $REPO_SLUG"; return 1; }
  ledger_json=$(cat "$LEDGER") || { log "cannot read $LEDGER"; return 1; }

  # Without the worktree list, a PR whose review worktree exists can look new;
  # that is refused rather than guessed.
  existing_wt=$(orca worktree list --repo "id:$ORCA_REPO_ID" --json \
    | jq '[.result.worktrees[]? | select(.displayName) | {id, displayName}]') \
    || { log "cannot list the Orca worktrees of $ORCA_REPO_ID"; return 1; }
  [ -n "$existing_wt" ] || existing_wt='[]'

  candidates=$(jq \
    --arg me "$me" \
    --arg skip_own "$SKIP_OWN_PRS" \
    --arg skip_bots "$SKIP_BOT_AUTHORS" \
    --arg skip_stacked "$SKIP_STACKED" \
    --arg excluded "$EXCLUDE_AUTHORS" \
    --arg rereview "$REREVIEW" \
    --argjson max_rounds "$MAX_REVIEW_ROUNDS" \
    --argjson days "$RECENCY_DAYS" \
    --argjson maxfiles "$MAX_FILES" \
    --arg untrusted "$REVIEW_UNTRUSTED_PRS" \
    --arg cfg "$SESSION_CONFIG_PATHS" \
    --argjson assoc "$assoc" \
    --argjson ledger "$ledger_json" \
    --argjson wts "$existing_wt" "$TRUST_JQ"'
    # Head branches of every same-repo open PR, drafts and the user own included.
    # Fork heads are left out: a fork branch named "main" is not this repo main.
    # A PR based on one of these is stacked; only the bottom of a stack is
    # reviewed, and the next one is picked up once it retargets.
    ([ .[] | select(.isCrossRepository | not) | .headRefName ]) as $heads
    | ($excluded | split(" ") | map(select(. != ""))) as $ex
    | [ .[]
      | . as $p
      | ($ledger[($p.number | tostring)]) as $l
      | ([$wts[] | select(.displayName == "pr-\($p.number)-review") | .id] | first) as $wt
      | ([$p.reviews[] | select(.author.login == $me)]) as $my_reviews
      | ([$my_reviews[] | select(.state != "PENDING")] | sort_by(.submittedAt) | last) as $mine
      | select($p.isDraft | not)
      | select($skip_own != "1" or $p.author.login != $me)
      | select($skip_bots != "1" or ($p.author.is_bot | not))
      | select(($ex | index($p.author.login)) == null)
      | select((now - ($p.updatedAt | fromdateiso8601)) < ($days * 86400))
      | {number, url, title, headRefOid, baseRefName, updatedAt, changedFiles,
         worktree: $wt, tooLarge: ($p.changedFiles > $maxfiles)}
        + trust($p.isCrossRepository; $assoc[($p.number | tostring)])
        + {untrustedSkip: false,
           # gh lists at most 100 files per PR; a truncated list is re-read in
           # full by select_complete_file_lists.
           # Case-sensitive: the pattern carries its own case rules.
           sessionConfig: ([$p.files[]?.path | select(test($cfg))]),
           filesUnchecked: (($p.files | length) < $p.changedFiles)}
      | .untrustedSkip = ((.trusted | not) and $untrusted != "1")
      # First review: never reviewed, and either never handled (no ledger
      # entry and no pr-N-review worktree) or a failed round-1 review whose
      # head moved since. A failed session leaves its worktree behind, so a
      # retry may have one; dispatch then launches into it.
      | if ($p.reviews | length) == 0
           and (($l == null and $wt == null)
                or ($l != null and $l.state == "failed"
                    and (($l.round // "1") | tonumber) <= 1
                    and $l.sha != $p.headRefOid)) then
          . + {kind: "review", round: 1, prevSha: null, trigger: "new",
               stackedOn: (if $skip_stacked == "1" and ($heads | index($p.baseRefName))
                           then $p.baseRefName else null end)}
        # Re-review: a PR this plugin reviewed, whose review the user submitted,
        # with no unsubmitted review from the user and no review in flight. A
        # failed re-review is retried at the same round.
        elif $rereview == "1" and $l != null and $mine != null
             and ([$my_reviews[] | select(.state == "PENDING")] | length) == 0
             and ($l.state == "reviewed" or $l.state == "submitted"
                  or ($l.state == "failed" and ($l.round // "1" | tonumber) >= 2)) then
          (($l.round // "1") | tonumber) as $r
          | (if $l.state == "failed" then $r else $r + 1 end) as $next
          # A failed re-review is retried on the activity that triggered it
          # (since = your last submitted review, not the failure), when its
          # head moved since the failure or it has not been retried at this
          # head yet (dispatch records attempt). Otherwise only activity after
          # the failure counts, and a re-request alone does not, so a round
          # that keeps failing at one head is not relaunched every hour.
          | ($l.state != "failed" or $l.sha != $p.headRefOid
             or ((($l.attempt // "1") | tonumber) < 2)) as $retry
          | (if $l.state == "failed" and $retry then $mine.submittedAt
             else ([$mine.submittedAt, ($l.at // "")] | max) end) as $since
          | ($retry and ([$p.reviewRequests[]? | .login] | index($me) != null)) as $rerequested
          | . + {kind: "rereview", round: $next, prevSha: ($mine.commit.oid // $l.sha),
                 since: $since, rerequested: $rerequested, stackedOn: null,
                 overRounds: ($next > $max_rounds)}
          | select(.rerequested or .updatedAt > $since)
        else empty end
    ]' <<<"$raw") || { log "cannot evaluate the open PRs of $REPO_SLUG"; return 1; }

  jq -r '.[] | select(.untrustedSkip) | "skip #\(.number): untrusted, \(.trust); set REVIEW_UNTRUSTED_PRS=1 to review it without running its code"' <<<"$candidates" >&2
  candidates=$(jq '[.[] | select(.untrustedSkip | not)]' <<<"$candidates") || return 1
  candidates=$(select_complete_file_lists "$candidates") || return 1
  # PRs that change session config are never reviewed automatically (see
  # SESSION_CONFIG_PATHS); one whose file list is incomplete is treated the same.
  # Paths are chosen by the PR author and this output reaches the dispatcher
  # agent, so they are sanitized and capped (as safe_paths in lib/common.sh).
  jq -r 'def clean: gsub("[^A-Za-z0-9._/-]"; "_") | .[0:80];
    .[] | select(.tooLarge | not)
    | if (.sessionConfig | length) > 0 then "skip #\(.number): changes agent session config (\(.sessionConfig[:5] | map(clean) | join(", "))\(if (.sessionConfig | length) > 5 then ", and \((.sessionConfig | length) - 5) more" else "" end)); review it by hand, or run dispatch --pr \(.number) --allow-session-config"
      elif .filesUnchecked then "skip #\(.number): its file list is incomplete, so it cannot be checked for session config changes"
      else empty end' <<<"$candidates" >&2
  candidates=$(jq '[.[] | select(.tooLarge or ((.sessionConfig | length) == 0 and (.filesUnchecked | not)))]' <<<"$candidates") || return 1
  jq -r '.[] | select(.stackedOn) | "skip #\(.number): stacked on \(.stackedOn | gsub("[^A-Za-z0-9._/-]"; "_") | .[0:80]); its base PR goes first"' <<<"$candidates" >&2
  jq -r --arg max "$MAX_FILES" '.[] | select(.tooLarge) | "skip #\(.number): \(.changedFiles) files > MAX_FILES=\($max)"' <<<"$candidates" >&2
  jq -r --arg max "$MAX_REVIEW_ROUNDS" '.[] | select(.overRounds and (.tooLarge | not)) | "skip #\(.number): round \(.round) would exceed MAX_REVIEW_ROUNDS=\($max)"' <<<"$candidates" >&2

  first=$(jq '[.[] | select(.kind == "review" and (.tooLarge | not) and .stackedOn == null)] | sort_by(.updatedAt) | reverse' <<<"$candidates") || return 1

  # Re-review candidates: decide from the actual responses, not updatedAt,
  # which bot comments and the user own activity also bump.
  c=$(jq -c '[.[] | select(.kind == "rereview" and (.tooLarge | not) and (.overRounds | not))]' <<<"$candidates") || return 1
  n=$(jq length <<<"$c") || return 1
  for ((i = 0; i < n; i++)); do
    local item pr
    item=$(jq -c ".[$i]" <<<"$c") || return 1
    pr=$(jq -r .number <<<"$item") || return 1
    act=$(rereview_activity "$pr" "$(jq -r .since <<<"$item")" "$(jq -r .prevSha <<<"$item")" "$me") || {
      log "skip #$pr: could not read its review activity"; continue; }
    trigger=$(jq -r --argjson a "$act" --argjson q "$REREVIEW_QUIET_HOURS" '
      ($a.counts | "\(.pushes) push(es), \(.replies) thread repl(ies), \(.comments) PR comment(s)") as $what
      | if .rerequested then "re-requested; \($what)"
        elif ($a.moved | not) and $a.last == null then "none"
        elif $a.last != null and (now - ($a.last | fromdateiso8601)) < ($q * 3600) then
          "wait:\(((now - ($a.last | fromdateiso8601)) / 3600 * 10 | floor) / 10)"
        else "activity: \($what)" end' <<<"$item") || trigger=""
    case "$trigger" in
      "") log "skip #$pr: could not evaluate its review activity" ;;
      none) log "skip #$pr: no response from others since your last review" ;;
      wait:*) hours=${trigger#wait:}
              log "wait #$pr: last activity ${hours}h ago; re-review after ${REREVIEW_QUIET_HOURS}h of quiet" ;;
      *) rereviews=$(jq --argjson it "$item" --arg t "$trigger" '. + [$it + {trigger: $t}]' <<<"$rereviews") || return 1 ;;
    esac
  done

  jq -n --argjson r "$rereviews" --argjson f "$first" '
    ($r | sort_by(.rerequested | not)) + $f
    | [.[] | {number, url, title, headRefOid, baseRefName, updatedAt, kind, round, prevSha, trigger, worktree, trusted, trust}]'
}

cmd_select() {
  require_repo_config
  repo_pipeline_apply
  local mode="${1:-}" eligible in_flight slots selected
  # cmd_select often runs inside $(...) with errexit off, so check each step.
  eligible=$(select_eligible) || die "select failed for $REPO_SLUG; see above"
  in_flight=$(ledger_in_flight) || die "cannot read in-flight reviews from $LEDGER"
  slots=$((MAX_IN_FLIGHT - in_flight)); [ "$slots" -lt 0 ] && slots=0
  log "$REPO_SLUG: eligible=$(jq length <<<"$eligible") (re-reviews=$(jq '[.[] | select(.kind == "rereview")] | length' <<<"$eligible")) in_flight=$in_flight slots=$slots"
  if [ "$mode" = "--all" ]; then echo "$eligible"; return 0; fi
  selected=$(jq --argjson n "$slots" '.[:$n]' <<<"$eligible") || die "cannot limit the selection to $slots slot(s)"
  if [ "$mode" = "--check" ]; then
    [ "$(jq length <<<"$selected")" -gt 0 ]; return $?
  fi
  echo "$selected"
}
