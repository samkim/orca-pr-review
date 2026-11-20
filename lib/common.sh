# shellcheck shell=bash
# Sourced by bin/orca-pr-review. Loads defaults, global and per-repo config,
# and defines shared helpers. Expects PLUGIN_ROOT to be set.

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/orca-pr-review"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/orca-pr-review"
SHIM_PATH="${ORCA_PR_REVIEW_SHIM:-$HOME/.local/bin/orca-pr-review}"

log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }
die() { echo "orca-pr-review: $*" >&2; exit 1; }

# Retry gh on transient (5xx / network) failures. Usage: gh_retry <args...>
gh_retry() {
  local i out
  for i in 1 2 3; do
    if out=$(gh "$@" 2>&1); then printf '%s' "$out"; return 0; fi
    log "gh $1 failed (attempt $i): $(echo "$out" | head -1)"
    sleep $((i * 5))
  done
  echo "$out" >&2
  return 1
}

# gh_write <stdin-body|""> <gh args...>: one GitHub write. It is retried only
# when gh could not connect, so the request never reached GitHub; any other
# failure returns at once, because the write may have landed. A non-empty
# body goes to gh on stdin, again on every attempt.
gh_write() {
  local body="$1" i out; shift
  for i in 1 2 3; do
    if [ -n "$body" ]; then
      out=$(gh "$@" --input - <<<"$body" 2>&1) && { printf '%s' "$out"; return 0; }
    else
      out=$(gh "$@" 2>&1) && { printf '%s' "$out"; return 0; }
    fi
    case "$out" in
      *"error connecting"*|*"dial tcp"*|*"no such host"*|*"connection refused"*) ;;
      *) break ;;
    esac
    log "gh $1 could not connect (attempt $i): $(echo "$out" | head -1)"
    sleep $((i * 5))
  done
  echo "$out" >&2
  return 1
}

# owner/name -> owner--name, safe as a file name.
repo_key() { printf '%s' "${1/\//--}"; }

# load_repo <owner/name>: source config for one repo and set its state paths.
load_repo() {
  REPO_SLUG="$1"
  [[ "$REPO_SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "repo must be owner/name, got '$REPO_SLUG'"
  local key; key=$(repo_key "$REPO_SLUG")
  # shellcheck source=/dev/null
  source "$PLUGIN_ROOT/config/defaults.sh"
  # shellcheck source=/dev/null
  [ -f "$CONFIG_HOME/config.sh" ] && source "$CONFIG_HOME/config.sh"
  REPO_CONFIG="$CONFIG_HOME/repos/$key.sh"
  # shellcheck source=/dev/null
  [ -f "$REPO_CONFIG" ] && source "$REPO_CONFIG"
  STATE_DIR="$STATE_HOME/$key"
  LEDGER="$STATE_DIR/ledger.json"
  # shellcheck disable=SC2034  # used by lib/ledger.sh and lib/dispatch.sh
  LOCK_DIR="$STATE_DIR/lock"
  mkdir -p "$STATE_DIR"
  [ -f "$LEDGER" ] || echo '{}' > "$LEDGER"
}

require_repo_config() {
  [ -f "$REPO_CONFIG" ] || die "$REPO_SLUG is not set up; run: orca-pr-review init --repo $REPO_SLUG"
  [ -n "${ORCA_REPO_ID:-}" ] || die "ORCA_REPO_ID is empty in $REPO_CONFIG"
}

# The command a review session or automation should call back into: the stable
# shim when installed, otherwise this plugin version's binary.
cli_path() {
  if [ -x "$SHIM_PATH" ]; then echo "$SHIM_PATH"; else echo "$PLUGIN_ROOT/bin/orca-pr-review"; fi
}

# SESSION_CONFIG_PATHS: files an agent session loads from its working tree:
# Claude Code settings, hooks, skills, agents and commands (.claude/), MCP
# servers (.mcp.json), memory files (CLAUDE.md, CLAUDE.local.md, AGENTS.md,
# AGENTS.override.md at any depth), and Codex's .agents/ and .codex/. A review
# session runs in a checkout of the PR head and Orca cannot pass flags such as
# claude --setting-sources, so a PR changing any of these would configure its
# own review. Such PRs are not reviewed, trusted or not; dispatch --pr N
# --allow-session-config overrides that for one PR. One list, used by select,
# dispatch and the session's own stage 0 check (it is passed in the prompt).
#
# Every consumer matches it CASE-SENSITIVELY (jq test($re), grep -E); the
# letter case rules live in the pattern itself, so no consumer can apply the
# wrong flag:
# - The dot-directories and .mcp.json are spelled with [xX] classes, so they
#   match in any letter case: on a case-insensitive filesystem (macOS APFS)
#   .Claude/settings.json loads like .claude/settings.json, and nobody names an
#   ordinary file .Claude.
# - The memory files match only their exact names. Matching them in any case
#   flagged ordinary doc pages (docs/agents.md, site/content/claude.md) and
#   skipped those PRs. On APFS Claude Code would open a claude.md as CLAUDE.md;
#   that residual is accepted under the trusted-collaborator model and listed
#   in docs/security.md.
# - Nested files count. Claude Code loads a nested CLAUDE.md when it reads
#   files in that directory. AGENTS.md is not loaded by Claude Code itself,
#   and Codex reads it only along the root-to-cwd path, but it stays matched
#   at any depth: a CLAUDE.md is commonly a symlink to, or an @import of, the
#   AGENTS.md beside it, so editing AGENTS.md edits what Claude Code loads.
# The directories match as bare names too ((/|$)), so a PR that adds a symlink
# named .claude is caught by name; PRs that add or change any symlink are
# refused separately (pr_symlink_hits in lib/dispatch.sh, and the skills'
# stage 0 symlink check).
# shellcheck disable=SC2034  # used by lib/select.sh and lib/dispatch.sh
SESSION_CONFIG_PATHS='(^|/)\.([cC][lL][aA][uU][dD][eE]|[aA][gG][eE][nN][tT][sS]|[cC][oO][dD][eE][xX])(/|$)|(^|/)\.[mM][cC][pP]\.[jJ][sS][oO][nN]$|(^|/)CLAUDE(\.local)?\.md$|(^|/)AGENTS(\.override)?\.md$'

# safe_paths: read paths (one per line) on stdin and print them as one short
# line that is safe to show an LLM: characters outside [A-Za-z0-9._/-] become
# _, each path is cut to 80 characters, and at most 5 are listed. PR authors
# choose these names, and dispatch output is read by the dispatcher agent.
safe_paths() {
  local line n=0 out=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    [ "$n" -le 5 ] || continue
    line=${line//[^A-Za-z0-9._\/-]/_}
    out+="${out:+, }${line:0:80}"
  done
  [ "$n" -le 5 ] || out+=", and $((n - 5)) more"
  printf '%s' "$out"
}

# dispatcher_agent_args: the extra arguments for the automation's agent.
dispatcher_agent_args() {
  if [ -n "$DISPATCHER_AGENT_ARGS" ]; then printf '%s' "$DISPATCHER_AGENT_ARGS"; return 0; fi
  case "$DISPATCHER_AGENT" in
    claude) printf '%s' "--model haiku --effort low" ;;
    codex) printf '%s' "-c model_reasoning_effort=low" ;;
    *) ;;
  esac
}

# Exit 0 inside WINDOW_DAYS / WINDOW_START_HOUR..WINDOW_END_HOUR (local time).
# FORCE=1 bypasses it.
in_window() {
  [ "${FORCE:-0}" = "1" ] && return 0
  local dow hour d lo hi ok=1
  dow=$(date +%u); [ "$dow" = 7 ] && dow=0   # cron numbering: Sunday = 0
  hour=$((10#$(date +%H)))
  if [ "$WINDOW_DAYS" = "*" ]; then ok=0; else
    for d in ${WINDOW_DAYS//,/ }; do
      if [[ "$d" == *-* ]]; then lo=${d%-*}; hi=${d#*-}; else lo=$d; hi=$d; fi
      [ "$hi" = 7 ] && [ "$dow" = 0 ] && ok=0
      [ "$dow" -ge "$lo" ] && [ "$dow" -le "$hi" ] && ok=0
    done
  fi
  [ "$ok" = 0 ] && [ "$hour" -ge "$WINDOW_START_HOUR" ] && [ "$hour" -le "$WINDOW_END_HOUR" ]
}

# --- Repo-owned review config -------------------------------------------------
# The repo keeps its review settings in .orca-pr-review/ on its default branch:
#   pipeline.sh        allowlisted settings (see REPO_PIPELINE_KEYS), KEY='value' lines
#   focus.md           what the reviews should emphasize; added to the review
#   review-prompt.md   replaces the instructions of the /code-review step
#   extra-skills.txt   other review skills to run, one name per line; each must
#                      match ^[a-z0-9][a-z0-9:_-]*$ and EXTRA_SKILLS_ALLOW
# Everything is read through the API from the default branch, so a PR cannot
# change the rules its own review runs under. A personal file in
# CONFIG_HOME/repos/<owner>--<repo>/ with the same name replaces the repo's text
# file; a personal KEY= line in repos/<owner>--<repo>.sh wins over pipeline.sh.
# Trust settings (REVIEW_UNTRUSTED_PRS, EXTRA_SKILLS_ALLOW, REVIEW_AGENT) are
# deliberately absent from REPO_PIPELINE_KEYS: the repo's committers must not
# be able to widen what a review session runs.
REPO_CONFIG_DIR=".orca-pr-review"
REPO_TEXT_MAX=8000   # bytes of each text file that reach a review prompt
REPO_PIPELINE_KEYS="RISKY_PATHS EXCLUDE_AUTHORS REVIEW_STAGES SKIP_BOT_AUTHORS TEST_PATHS GENERATED_PATHS"

# repo_default_branch: set REPO_DEFAULT_BRANCH (one API call per run). It sets
# the global and prints nothing, so it must be called directly, never in
# $(...): a subshell would drop the memo and every caller would refetch.
# repo_has_config calls it, so callers that run in a subshell inherit it once
# repo_has_config has run in the parent. Returns 1 (and prints why) when GitHub
# cannot say; callers stop, they never fall back to a guessed branch.
repo_default_branch() {
  [ -z "${REPO_DEFAULT_BRANCH:-}" ] || return 0
  local out
  if ! out=$(gh api "repos/$REPO_SLUG" -q .default_branch 2>&1) || [ -z "$out" ]; then
    echo "orca-pr-review: cannot read the default branch of $REPO_SLUG: ${out:-empty answer}" >&2
    return 1
  fi
  REPO_DEFAULT_BRANCH="$out"
}

# repo_has_config: whether the default branch has a .orca-pr-review/ folder. One
# API call, memoized in REPO_HAS_CONFIG for the run. Callers that run in a
# subshell ($(...)) must call it in the parent first so the memo is inherited.
repo_has_config() {
  if [ "${REPO_CONFIG_LOOKUP:-1}" = 0 ]; then REPO_HAS_CONFIG=0; return 0; fi
  if [ -z "${REPO_HAS_CONFIG:-}" ]; then
    local out
    repo_default_branch || return 1
    if out=$(gh api "repos/$REPO_SLUG/contents/$REPO_CONFIG_DIR?ref=$REPO_DEFAULT_BRANCH" 2>&1); then
      REPO_HAS_CONFIG=1
    elif grep -q 'HTTP 404' <<<"$out"; then
      REPO_HAS_CONFIG=0
    else
      echo "$out" >&2; return 1
    fi
  fi
  return 0   # 0 = known (REPO_HAS_CONFIG is 1 or 0); 1 = GitHub could not say
}

# repo_file <name>: .orca-pr-review/<name> on the default branch. Prints nothing
# when the file does not exist; any other failure is an error, not an absence.
# With no .orca-pr-review/ folder on the branch, no per-file lookup is made.
repo_file() {
  repo_has_config || return 1
  [ "$REPO_HAS_CONFIG" = 1 ] || return 0
  local out path
  repo_default_branch || return 1   # memoized by repo_has_config above
  path="repos/$REPO_SLUG/contents/$REPO_CONFIG_DIR/$1?ref=$REPO_DEFAULT_BRANCH"
  if out=$(gh api -H 'Accept: application/vnd.github.raw' "$path" 2>&1); then
    printf '%s' "$out"; return 0
  fi
  if grep -q 'HTTP 404' <<<"$out"; then return 0; fi
  echo "$out" >&2
  return 1
}

# repo_text <name>: the text a review prompt carries for <name>. A personal file
# replaces the repo's; the result is capped at REPO_TEXT_MAX bytes.
repo_text() {
  local personal text
  personal="$CONFIG_HOME/repos/$(repo_key "$REPO_SLUG")/$1"
  if [ -f "$personal" ]; then
    text=$(cat "$personal")
  else
    text=$(repo_file "$1") || return 1
  fi
  if [ "${#text}" -gt "$REPO_TEXT_MAX" ]; then
    log "$1 is over $REPO_TEXT_MAX bytes; the review sees only the start"
    text="${text:0:$REPO_TEXT_MAX}"
  fi
  printf '%s' "$text"
}

# repo_pipeline_apply: set the allowlisted settings from pipeline.sh. Lines are
# parsed, never sourced: only KEY='value' with KEY in REPO_PIPELINE_KEYS is
# accepted. A key the user sets in either personal config (global config.sh or
# the per-repo file) is left alone.
repo_pipeline_apply() {
  local text line key val f mine
  repo_has_config || die "cannot read $REPO_CONFIG_DIR/ for $REPO_SLUG"   # memoizes for subshells
  text=$(repo_file pipeline.sh) || die "cannot read $REPO_CONFIG_DIR/pipeline.sh for $REPO_SLUG"
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if ! [[ "$line" =~ ^([A-Z_]+)=\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then
      log "pipeline.sh: ignored line: $line"; continue
    fi
    key=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}
    case " $REPO_PIPELINE_KEYS " in
      *" $key "*) ;;
      *) log "pipeline.sh: $key is not a repo setting; ignored"; continue ;;
    esac
    mine=0
    for f in "$CONFIG_HOME/config.sh" "$REPO_CONFIG"; do
      if [ -f "$f" ] && grep -q "^$key=" "$f"; then mine=1; fi
    done
    [ "$mine" = 1 ] && continue
    if [ "$key" = REVIEW_STAGES ] && ! review_stages_valid "$val"; then
      log "pipeline.sh: REVIEW_STAGES='$val' names an unknown stage (allowed: $KNOWN_REVIEW_STAGES); ignored"
      continue
    fi
    printf -v "$key" '%s' "$val"
  done <<<"$text"
  review_stages_valid "$REVIEW_STAGES" \
    || die "REVIEW_STAGES='$REVIEW_STAGES' names an unknown stage (allowed: $KNOWN_REVIEW_STAGES)"
}

# review_stages_valid <list>: exit 0 when every space-separated token is a
# known stage name. The list reaches the review prompt, so nothing else may.
KNOWN_REVIEW_STAGES="concerns review validate"
review_stages_valid() {
  local t
  [[ "$1" =~ ^[a-z\ ]*$ ]] || return 1
  for t in $1; do
    case " $KNOWN_REVIEW_STAGES " in *" $t "*) ;; *) return 1 ;; esac
  done
}

# prompt_nonce: 16 random hex characters, used to fence repo text in a prompt
# so the text cannot close its own fence.
prompt_nonce() {
  local n
  n=$(od -An -N8 -tx1 /dev/urandom) || return 1
  n=${n//[^0-9a-f]/}
  [ "${#n}" -eq 16 ] || { log "prompt_nonce: short read from /dev/urandom"; return 1; }
  printf '%s' "$n"
}
