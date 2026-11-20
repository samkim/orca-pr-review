# shellcheck shell=bash
# Work on this user's PENDING review of a PR, then submit it.
#   review show <pr>                             pending review as JSON: body + line comments
#   review set-body <pr> <file|->                replace the main comment
#   review comment add <pr> <path> <line> <file|-> [LEFT|RIGHT]
#   review comment edit <pr> <comment-id> <file|->
#   review comment delete <pr> <comment-id>
#   review submit <pr> comment|approve|request-changes
#   review threads <pr>                          review threads the user took part in, with replies
#   review resolve <pr> <thread-id>              resolve one thread (takes effect at once)
#
# GitHub's docs treat the summary as something given at submit time, and the
# web "Finish your review" box does not keep a body set through the API. So
# submit always sends the pending review's current body with the event.

read_text() { # <file|-> -> contents
  if [ "$1" = - ]; then cat; else [ -f "$1" ] || die "no such file: $1"; cat "$1"; fi
}

# require_pr <value>: die unless value is a PR number (positive, no leading zero).
require_pr() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] || die "not a PR number: '${1:-}'"
}

# pending_comment_node <pr> <comment-id>: GraphQL node id of a comment in the
# user's pending review of <pr>, or die. Edits and deletes go only through
# this, so they can never reach a published comment.
pending_comment_node() {
  local pr="$1" id="$2" shown node
  [[ "$id" =~ ^[1-9][0-9]*$ ]] || die "not a comment id: '$id'"
  shown=$(review_show "$pr") || die "could not read your pending review of #$pr"
  node=$(jq -r --argjson id "$id" '.comments[] | select(.id == $id) | .node_id' <<<"$shown") \
    || die "could not read the comments of your pending review of #$pr"
  [ -n "$node" ] || die "comment $id is not in your pending review of #$pr"
  printf '%s\n' "$node"
}

pending_review() { # <pr> -> review JSON, or die
  local me review
  require_pr "$1"
  me=$(gh_retry api user -q .login)
  review=$(gh_retry api "repos/$REPO_SLUG/pulls/$1/reviews" --paginate \
    | jq -s --arg me "$me" '[.[][] | select(.state == "PENDING" and .user.login == $me)] | first // empty')
  [ -n "$review" ] || die "PR #$1 has no pending review from $me"
  echo "$review"
}

review_show() {
  local pr="$1" review
  review=$(pending_review "$pr")
  # REST leaves line null on pending comments; GraphQL has it.
  gh_retry api graphql \
    -f query='query($id:ID!){node(id:$id){... on PullRequestReview{comments(first:100){nodes{id databaseId path line originalLine subjectType body replyTo{databaseId}}}}}}' \
    -f id="$(jq -r .node_id <<<"$review")" \
    | jq --argjson r "$review" '{
        review_id: $r.id, node_id: $r.node_id, commit_id: $r.commit_id, url: $r.html_url,
        body: $r.body,
        comments: [.data.node.comments.nodes[] | {id: .databaseId, node_id: .id, path, line: (.line // .originalLine),
          subject: .subjectType, reply_to: .replyTo.databaseId, body}]}'
}

# Threads the user started or replied in, oldest comment first. Comments in the
# user's own pending review are left out. Comment bodies are untrusted.
review_threads() {
  local pr="$1" me
  require_pr "$pr"
  me=$(gh_retry api user -q .login)
  gh_retry api graphql -F owner="${REPO_SLUG%%/*}" -F name="${REPO_SLUG#*/}" -F n="$pr" \
    -f query='query($owner:String!,$name:String!,$n:Int!){repository(owner:$owner,name:$name){pullRequest(number:$n){reviewThreads(first:100){nodes{
      id isResolved isOutdated path line originalLine
      comments(first:100){nodes{databaseId author{__typename login} createdAt body
        pullRequestReview{state} originalCommit{oid}}}}}}}}' \
    | jq --arg me "$me" '[.data.repository.pullRequest.reviewThreads.nodes[]
        | select(any(.comments.nodes[]; .author.login == $me and .pullRequestReview.state != "PENDING"))
        | {thread_id: .id, path, line: (.line // .originalLine), resolved: .isResolved, outdated: .isOutdated,
           comments: [.comments.nodes[] | select(.pullRequestReview.state != "PENDING")
             | {id: .databaseId, author: .author.login, bot: (.author.__typename == "Bot"),
                at: .createdAt, commit: .originalCommit.oid, body}]}]'
}

review_resolve() {
  require_pr "$1"
  local tid="${2:?usage: review resolve <pr> <thread-id>}"
  gh_retry api graphql \
    -f query='mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{id isResolved}}}' -f t="$tid" \
    | jq -r '.data.resolveReviewThread.thread | "thread \(.id) resolved=\(.isResolved)"'
}

review_set_body() {
  local pr="$1" body review
  body=$(read_text "${2:?usage: review set-body <pr> <file|->}")
  [ -n "$body" ] || die "refusing to set an empty body"
  review=$(pending_review "$pr")
  gh_retry api graphql \
    -f query='mutation($id:ID!,$b:String!){updatePullRequestReview(input:{pullRequestReviewId:$id,body:$b}){pullRequestReview{state body}}}' \
    -f id="$(jq -r .node_id <<<"$review")" -f b="$body" \
    | jq -r '.data.updatePullRequestReview.pullRequestReview | "body set (\(.body | length) chars), state=\(.state)"'
}

review_comment() {
  local sub="${1:-}" pr="${2:-}"; shift 2 || die "usage: review comment add|edit|delete <pr> ..."
  case "$sub" in
    add)
      local path="${1:?path}" line="${2:?line}" side="${4:-RIGHT}" body review
      [[ "$line" =~ ^[1-9][0-9]*$ ]] || die "not a line number: '$line'"
      body=$(read_text "${3:?usage: review comment add <pr> <path> <line> <file|-> [LEFT|RIGHT]}")
      local out existing
      review=$(pending_review "$pr")
      if out=$(gh_write "" api graphql \
          -f query='mutation($id:ID!,$p:String!,$l:Int!,$s:DiffSide!,$b:String!){addPullRequestReviewThread(input:{pullRequestReviewId:$id,path:$p,line:$l,side:$s,body:$b}){thread{comments(first:1){nodes{databaseId}}}}}' \
          -f id="$(jq -r .node_id <<<"$review")" -f p="$path" -F l="$line" -f s="$side" -f b="$body"); then
        jq -r --arg where "$path:$line" '.data.addPullRequestReviewThread.thread.comments.nodes[0].databaseId | "added comment \(.) on \($where)"' <<<"$out"
      else
        # The write may have landed anyway; don't let a retry add it twice.
        existing=$(review_show "$pr" | jq -r --arg p "$path" --argjson l "$line" --arg b "$body" \
          '[.comments[] | select(.path == $p and .line == $l and .body == $b)][0].id // empty') \
          || die "adding the comment on $path:$line failed and the pending review can't be read; run review show before adding it again"
        [ -n "$existing" ] || die "could not add the comment on $path:$line"
        echo "added comment $existing on $path:$line"
      fi ;;
    edit)
      local id="${1:?comment id}" body node
      body=$(read_text "${2:?usage: review comment edit <pr> <comment-id> <file|->}")
      # REST returns 404 for a pending comment; GraphQL can edit it.
      node=$(pending_comment_node "$pr" "$id") || exit 1
      gh_retry api graphql \
        -f query='mutation($id:ID!,$b:String!){updatePullRequestReviewComment(input:{pullRequestReviewCommentId:$id,body:$b}){pullRequestReviewComment{databaseId path line}}}' \
        -f id="$node" -f b="$body" \
        | jq -r '.data.updatePullRequestReviewComment.pullRequestReviewComment | "edited comment \(.databaseId) on \(.path):\(.line)"' ;;
    delete)
      local id="${1:?usage: review comment delete <pr> <comment-id>}" node out
      node=$(pending_comment_node "$pr" "$id") || exit 1
      out=$(gh_retry api graphql \
        -f query='mutation($id:ID!){deletePullRequestReviewComment(input:{id:$id}){pullRequestReview{id}}}' \
        -f id="$node") || die "could not delete comment $id"
      jq -e '.data.deletePullRequestReviewComment' <<<"$out" >/dev/null \
        || die "deleting comment $id failed: $out"
      echo "deleted comment $id" ;;
    *) die "usage: review comment add|edit|delete <pr> ..." ;;
  esac
}

review_submit() {
  local pr="$1" ev="${2:-}" event review
  case "$ev" in
    comment) event=COMMENT ;; approve) event=APPROVE ;; request-changes) event=REQUEST_CHANGES ;;
    *) die "usage: review submit <pr> comment|approve|request-changes" ;;
  esac
  review=$(pending_review "$pr")
  if [ "$event" != APPROVE ] && [ -z "$(jq -r '.body // ""' <<<"$review")" ]; then
    die "$ev needs a main comment; set one with: review set-body $pr <file>"
  fi
  local rid payload out state
  rid=$(jq -r .id <<<"$review")
  payload=$(jq -c '{event: $e, body: (.body // "")}' --arg e "$event" <<<"$review")
  if ! out=$(gh_write "$payload" api -X POST "repos/$REPO_SLUG/pulls/$pr/reviews/$rid/events"); then
    # The submit may have landed anyway: trust the review's state, not the error.
    state=$(gh_retry api "repos/$REPO_SLUG/pulls/$pr/reviews/$rid" -q .state) \
      || die "submit failed and review $rid can't be read; check the PR before submitting again"
    [ "$state" != PENDING ] || die "submit failed; review $rid is still pending"
    log "submit reported an error, but review $rid is now $state; recording it as submitted"
    out=$(gh_retry api "repos/$REPO_SLUG/pulls/$pr/reviews/$rid") || die "cannot read review $rid"
  fi
  jq -r '"submitted review \(.id): \(.state), body \(.body | length) chars, \(.html_url)"' <<<"$out"
  ledger_with_lock ledger_set_locked "$pr" submitted event="$event"
}

cmd_review() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    show) review_show "${1:?usage: review show <pr>}" ;;
    set-body) review_set_body "${1:?usage: review set-body <pr> <file|->}" "${2:-}" ;;
    comment) review_comment "$@" ;;
    submit) review_submit "${1:?usage: review submit <pr> <event>}" "${2:-}" ;;
    threads) review_threads "${1:?usage: review threads <pr>}" ;;
    resolve) review_resolve "${1:?usage: review resolve <pr> <thread-id>}" "${2:-}" ;;
    *) die "usage: review show|set-body|comment|submit|threads|resolve <pr> ..." ;;
  esac
}
