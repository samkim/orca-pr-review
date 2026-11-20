# shellcheck shell=bash
# Setup and maintenance commands. None of these needs --repo except where noted.

# record-root: remember where this plugin version lives, so the stable shim
# keeps working after the plugin updates. Run by the plugin's SessionStart hook.
cmd_record_root() {
  mkdir -p "$CONFIG_HOME"
  printf '%s\n' "$PLUGIN_ROOT" > "$CONFIG_HOME/plugin-root"
}

# plugin_cache_roots: every installed copy of this plugin in Claude Code's
# plugin cache, one root per line. Claude Code lays installs out as
# <home>/plugins/cache/<marketplace>/orca-pr-review/<version>/, where <home> is
# $CLAUDE_CONFIG_DIR (default ~/.claude). Only directories holding an
# executable bin/orca-pr-review count.
plugin_cache_roots() {
  local home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" d
  for d in "$home"/plugins/cache/*/orca-pr-review/*/; do
    d=${d%/}
    [ -x "$d/bin/orca-pr-review" ] && printf '%s\n' "$d"
  done
  return 0
}

# latest_plugin_root: the installed root with the highest version (sort -V on
# the version directory name). Prints nothing when none is installed.
latest_plugin_root() {
  local roots d
  roots=$(plugin_cache_roots) || return 1
  [ -n "$roots" ] || return 0
  while IFS= read -r d; do printf '%s\t%s\n' "${d##*/}" "$d"; done <<<"$roots" \
    | sort -V -k1,1 | tail -1 | cut -f2-
}

# install-shim [--latest]: write ~/.local/bin/orca-pr-review, the stable path
# Orca automations and review sessions call. Plugin install paths change per
# version. --latest hands off to the newest installed version's own
# install-shim, so the shim and plugin-root point at it even when this copy is
# the old one (as it is when run through the shim after an update).
cmd_install_shim() {
  case "${1:-}" in
    "") ;;
    --latest)
      local latest
      latest=$(latest_plugin_root) || die "cannot list the installed plugin versions"
      [ -n "$latest" ] || die "no installed orca-pr-review found under ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache"
      if [ "$latest" != "$PLUGIN_ROOT" ]; then
        echo "newest installed version: $latest"
        exec "$latest/bin/orca-pr-review" install-shim
      fi ;;
    *) die "usage: install-shim [--latest]" ;;
  esac
  cmd_record_root
  mkdir -p "$(dirname "$SHIM_PATH")"
  cat > "$SHIM_PATH" <<'EOF'
#!/usr/bin/env bash
# Stable entry point for the orca-pr-review Claude Code plugin. Written by
# `orca-pr-review install-shim`; the plugin's SessionStart hook keeps
# plugin-root pointing at the installed version.
root_file="${XDG_CONFIG_HOME:-$HOME/.config}/orca-pr-review/plugin-root"
root=$(cat "$root_file" 2>/dev/null)
if [ ! -x "$root/bin/orca-pr-review" ]; then
  echo "orca-pr-review: plugin not found at '$root' (from $root_file)." >&2
  echo "Start a Claude Code session with the plugin enabled to refresh it, or run" >&2
  echo "<installed plugin dir>/bin/orca-pr-review install-shim --latest." >&2
  exit 127
fi
exec "$root/bin/orca-pr-review" "$@"
EOF
  chmod +x "$SHIM_PATH"
  echo "installed $SHIM_PATH -> $PLUGIN_ROOT"
  case ":$PATH:" in *":$(dirname "$SHIM_PATH"):"*) ;; *)
    echo "note: $(dirname "$SHIM_PATH") is not on PATH; automations use the absolute path, so this only affects typing it yourself" ;;
  esac
}

# init --repo <owner/name> [--path <checkout>] [--force]
# Write the per-repo config, finding the repo in Orca by checkout path or remote.
cmd_init() {
  local path="" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --path) path="$2"; shift 2 ;;
      --force) force=1; shift ;;
      *) die "init: unknown arg $1" ;;
    esac
  done
  if [ -f "$REPO_CONFIG" ] && [ "$force" != 1 ]; then
    echo "$REPO_CONFIG already exists; pass --force to rewrite it"; return 0
  fi

  local repos match id rpath
  repos=$(orca repo list --json | jq -c '[.result.repos[]? | {id, path, name: .displayName}]') \
    || die "orca repo list failed; is Orca running? (orca open)"
  if [ -n "$path" ]; then
    path=$(cd "$path" && pwd -P)
    match=$(jq -c --arg p "$path" '[.[] | select(.path == $p)][0] // empty' <<<"$repos")
  else
    # Match by the origin remote of each Orca repo checkout.
    while read -r id rpath; do
      [ -d "$rpath" ] || continue
      if git -C "$rpath" remote -v 2>/dev/null | grep -qiE "[:/]${REPO_SLUG//./\\.}(\.git)?[[:space:]]"; then
        match=$(jq -c --arg id "$id" '[.[] | select(.id == $id)][0]' <<<"$repos"); break
      fi
    done < <(jq -r '.[] | "\(.id) \(.path)"' <<<"$repos")
  fi
  [ -n "${match:-}" ] || die "no Orca repo matches $REPO_SLUG; add it with \`orca repo add --path <checkout>\` or pass --path"

  id=$(jq -r .id <<<"$match"); rpath=$(jq -r .path <<<"$match")
  mkdir -p "$(dirname "$REPO_CONFIG")"
  # Values come from Orca and the filesystem, and this file is sourced: write
  # them single-quoted, then confirm the file parses and round-trips them.
  local tmp; tmp=$(mktemp)
  cat > "$tmp" <<EOF
# orca-pr-review settings for $REPO_SLUG. Any value from
# the plugin's config/defaults.sh can be overridden here.
ORCA_REPO_ID=$(sh_single_quote "$id")
REPO_PATH=$(sh_single_quote "$rpath")
AUTOMATION_ID=''          # written by install-automation; empty disables backfill

# Extended regex over repo-relative paths whose changes get the high model.
# Left commented so the repo's .orca-pr-review/pipeline.sh can set it: any
# KEY= line here overrides that file. Uncomment to override it for yourself.
# RISKY_PATHS='^(src/auth|src/billing|migrations)/'
EOF
  # shellcheck source=/dev/null
  if ! ( source "$tmp" 2>/dev/null && [ "$ORCA_REPO_ID" = "$id" ] && [ "$REPO_PATH" = "$rpath" ] ); then
    rm -f "$tmp"; die "could not write $REPO_CONFIG safely for repo id '$id' at '$rpath'"
  fi
  mv "$tmp" "$REPO_CONFIG"
  echo "wrote $REPO_CONFIG (orca repo $id at $rpath)"
}

# install-automation --repo <owner/name>
# Create the hourly dispatcher automation, disabled, and record its id.
cmd_install_automation() {
  require_repo_config
  [ -z "${AUTOMATION_ID:-}" ] || { echo "automation already recorded: $AUTOMATION_ID"; return 0; }
  [ -x "$SHIM_PATH" ] || die "run install-shim first; automations call $SHIM_PATH"
  local cron out id
  cron="0 $WINDOW_START_HOUR-$WINDOW_END_HOUR * * $WINDOW_DAYS"
  out=$(orca automations create \
    --name "PR review: $REPO_SLUG" \
    --trigger "$cron" \
    --provider "$DISPATCHER_AGENT" \
    --extra-agent-args="$(dispatcher_agent_args)" \
    --workspace "path:$REPO_PATH" \
    --precheck "$(automation_precheck)" \
    --prompt "$(automation_prompt)" \
    --disabled --json) || die "orca automations create failed: $out"
  id=$(jq -r '.result.automation.id // .result.id // empty' <<<"$out")
  [ -n "$id" ] || die "could not read the automation id from: $out"
  config_write_key AUTOMATION_ID "$id" \
    || die "created automation $id but could not record it in $REPO_CONFIG; record it with: config set AUTOMATION_ID $id"
  echo "created automation $id ($cron), disabled. Enable it with: orca automations edit --id $id --enabled"
}

# update-automation --repo <owner/name>
# Apply DISPATCHER_AGENT, its arguments, and the current precheck and prompt to
# the existing automation. Schedule and enabled are left as they are.
cmd_update_automation() {
  require_repo_config
  [ -n "${AUTOMATION_ID:-}" ] || die "no automation recorded for $REPO_SLUG; run install-automation"
  local args out
  args=$(dispatcher_agent_args)
  out=$(orca automations edit --id "$AUTOMATION_ID" --provider "$DISPATCHER_AGENT" \
    --extra-agent-args="$args" --precheck "$(automation_precheck)" --prompt "$(automation_prompt)" \
    --json 2>&1) || die "orca automations edit failed: $out"
  echo "automation $AUTOMATION_ID now starts $DISPATCHER_AGENT${args:+ with $args}; precheck and prompt refreshed"
}

# doctor [--repo <owner/name>]: check dependencies and setup.
cmd_doctor() {
  local bad=0 c
  for c in orca gh jq git claude; do
    if command -v "$c" >/dev/null; then echo "ok    $c"; else echo "MISS  $c"; bad=1; fi
  done
  if gh auth status >/dev/null 2>&1; then echo "ok    gh auth"; else echo "FAIL  gh auth status"; bad=1; fi
  if orca status --json >/dev/null 2>&1; then echo "ok    orca runtime"; else echo "FAIL  orca status (run: orca open)"; bad=1; fi
  if [ -x "$SHIM_PATH" ]; then echo "ok    shim $SHIM_PATH"; else echo "MISS  shim (run: install-shim)"; bad=1; fi
  echo "info  plugin root $(cat "$CONFIG_HOME/plugin-root" 2>/dev/null || echo unset)"
  if [ -n "${REPO_SLUG:-}" ]; then
    if review_agent_supported 2>/dev/null; then echo "ok    review agent $REVIEW_AGENT"
    else echo "FAIL  REVIEW_AGENT=$REVIEW_AGENT is not supported (use claude)"; bad=1; fi
    if [ -f "$REPO_CONFIG" ]; then echo "ok    config $REPO_CONFIG"; else echo "MISS  config (run: init --repo $REPO_SLUG)"; bad=1; fi
    if [ -n "${AUTOMATION_ID:-}" ]; then
      local shown agent
      if shown=$(orca automations show --id "$AUTOMATION_ID" --json 2>/dev/null); then
        echo "ok    automation $AUTOMATION_ID"
        agent=$(jq -r '.result.automation.agentId // .result.agentId // empty' <<<"$shown")
        if [ -n "$agent" ] && [ "$agent" != "$DISPATCHER_AGENT" ]; then
          echo "FAIL  automation starts $agent but DISPATCHER_AGENT=$DISPATCHER_AGENT (run: update-automation)"; bad=1
        fi
      else echo "FAIL  automation $AUTOMATION_ID not found in Orca"; bad=1; fi
    else echo "info  no automation yet (install-automation)"; fi
    echo "info  in flight: $(ledger_in_flight), ledger: $LEDGER"
  fi
  return $bad
}

cmd_repos() {
  local f
  for f in "$CONFIG_HOME"/repos/*.sh; do
    [ -f "$f" ] || continue
    basename "$f" .sh | sed 's/--/\//'
  done
}

# config set <KEY> <VALUE> | config get <KEY> | config show  (per repo)
# Writes KEY='VALUE' into the repo config, quoting the value safely for bash.
# config_require_key <KEY>: die unless KEY is UPPER_SNAKE and a setting in
# defaults.sh or the repo config. get expands the name indirectly, so this is
# what keeps `config get` from evaluating subscripts or printing GH_TOKEN.
config_require_key() {
  [[ "$1" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "bad setting name '$1' (UPPER_SNAKE)"
  grep -qE "^$1=" "$PLUGIN_ROOT/config/defaults.sh" "$REPO_CONFIG" 2>/dev/null \
    || die "unknown setting $1 (see $PLUGIN_ROOT/config/defaults.sh)"
}

cmd_config() {
  case "${1:-}" in
    show) cat "$REPO_CONFIG" ;;
    get) [ -n "${2:-}" ] || die "usage: config get <KEY>"
         config_require_key "$2"; printf '%s\n' "${!2-}" ;;
    set)
      local key="${2:-}" val="${3-}"
      [ -n "$key" ] || die "usage: config set <KEY> <VALUE> (KEY in UPPER_SNAKE)"
      config_require_key "$key"
      require_repo_config
      config_write_key "$key" "$val" || die "could not write $key safely; $REPO_CONFIG left unchanged"
      echo "$key=$(sh_single_quote "$val")" ;;
    *) die "usage: config show | get <KEY> | set <KEY> <VALUE>" ;;
  esac
}

# sh_single_quote <value>: print value as one single-quoted bash word, safe to
# write into a file that is later sourced.
sh_single_quote() {
  local sq="'" rep
  rep="${sq}\\${sq}${sq}"
  printf '%s' "${sq}${1//$sq/$rep}${sq}"
}

# config_write_key <KEY> <VALUE>: set KEY='VALUE' in REPO_CONFIG, replacing the
# first KEY= line or appending one. The file is replaced only once the new one
# parses and round-trips the value; returns 1 (file untouched) otherwise.
config_write_key() {
  local key="$1" val="$2" tmp
  tmp=$(mktemp)
  KEY="$key" LINE="$key=$(sh_single_quote "$val")" awk '
    BEGIN { k = ENVIRON["KEY"]; line = ENVIRON["LINE"] }
    index($0, k "=") == 1 { if (!done) print line; done = 1; next }
    { print }
    END { if (!done) print line }' "$REPO_CONFIG" > "$tmp" || { rm -f "$tmp"; return 1; }
  # shellcheck source=/dev/null
  if ! ( source "$tmp" 2>/dev/null && [ "${!key}" = "$val" ] ); then
    rm -f "$tmp"; return 1
  fi
  mv "$tmp" "$REPO_CONFIG"
}

# automation_cli: the shim invocation for this repo, quoted for the shell that
# runs the precheck or the dispatcher agent's command.
automation_cli() { printf '%q --repo %q' "$SHIM_PATH" "$REPO_SLUG"; }
automation_precheck() { printf '%s select --check' "$(automation_cli)"; }
automation_prompt() {
  # --close-when-done waits (up to hours) for the reviews to finish so their
  # tabs can be closed, so the agent runs it in the background.
  printf 'Run `%s dispatch --close-when-done` in the background, because it can run for hours. Wait for it to finish, then report its output verbatim. Do not do anything else.' "$(automation_cli)"
}
