# Troubleshooting

Start with `doctor`. It checks the dependencies, gh login, the Orca runtime,
the shim, and, with `--repo`, the repo's config and automation:

```bash
orca-pr-review --repo owner/name doctor
```

## Nothing is being reviewed

- **The automation is disabled.** It is created disabled. Enable it with
  `orca automations edit --id <id> --enabled`. The id is `AUTOMATION_ID` in
  `config show`.
- **Outside the window.** `orca-pr-review in-window` exits 0 inside it. Check
  `WINDOW_DAYS`, `WINDOW_START_HOUR` and `WINDOW_END_HOUR`, in local time.
- **No PR qualifies.** `orca-pr-review --repo owner/name select --all` lists
  eligible PRs, ignoring the slot limit, and prints why others were skipped on
  stderr.
- **Slots are full.** `ledger in-flight` counts dispatched reviews. One stuck
  in `dispatched` frees its slot after `STALE_HOURS`.

## "plugin not found" from the shim

The shim reads the plugin path from `~/.config/orca-pr-review/plugin-root`,
which the plugin's SessionStart hook refreshes. Start a Claude Code session
with the plugin enabled, or run `install-shim --latest` from any installed
copy's `bin/` (for example
`~/.claude/plugins/cache/<marketplace>/orca-pr-review/<version>/bin/orca-pr-review install-shim --latest`).
It finds the newest installed version and points the shim at it.

## `init` can't find the repo in Orca

`init` matches the GitHub repo against the `origin` remote of each repo Orca
knows. Add the checkout to Orca (`orca repo add --path <checkout>`) or pass
`--path <checkout>` to `init`.

## The main comment disappeared after submitting

It was submitted from GitHub's "Finish your review" box, which replaces a main
comment set through the API. Submit from the PR's Orca session instead (the
`finalize-review` skill), or with
`orca-pr-review review submit <pr> comment|approve|request-changes`.

## Reviewing a PR again by hand

```bash
orca-pr-review --repo owner/name dispatch --pr 123
```

To start over on a PR, inspect its entry with `ledger get 123` and change its
state with `ledger set`. A PR whose `pr-123-review` worktree still exists (for
example after a failed first review) is reviewed in that worktree, in a new
session, rather than in a new one.

A failed first review is retried automatically once the PR's head moves. To
retry it without a push, mark it failed (it already is) and dispatch it:

```bash
orca-pr-review --repo owner/name dispatch --pr 123
```

## A repo's `pipeline.sh` RISKY_PATHS is ignored

Any `KEY=` line in your personal repo config overrides the same key in the
repo's `.orca-pr-review/pipeline.sh`, even an empty one. Configs written by
older versions of `init` contain `RISKY_PATHS=""`, which silently wins over
the repo's value. Check with:

```bash
grep -n '^RISKY_PATHS=' ~/.config/orca-pr-review/repos/<owner>--<name>.sh
```

If the line is there and you want the repo's value, delete it or comment it out
(`# RISKY_PATHS=...`). Keep it only if you mean to override the repo for
yourself.

## A PR is stuck as "review in flight"

A review session that died without writing `reviewed` or `failed` leaves its
ledger entry at `dispatched`. Every dispatch run (scheduled or `--pr`, but not
`--dry-run`) marks entries older than `STALE_HOURS` as `failed`, so the PR is
retried at the next run (a first review only once its head has moved; a
re-review once at the same head, then again when its head moves or someone
responds after the failure). To
retry sooner, mark it failed by hand, then dispatch it; the new session runs
in the PR's existing worktree:

```bash
orca-pr-review --repo owner/name ledger get 123
orca-pr-review --repo owner/name ledger set 123 failed stage=session reason=manual
orca-pr-review --repo owner/name dispatch --pr 123
```

## Applying a new automation prompt to an existing automation

`update-automation` re-applies the dispatcher agent, its arguments, the
precheck and the prompt from the current plugin version. Run it after a plugin
update that changes them:

```bash
orca-pr-review --repo owner/name update-automation
```

## A PR is skipped as "untrusted"

By default only PRs from a branch in the repo itself, or by an owner, member or
collaborator, are reviewed, because the review checks out and reads the PR's
code. `select` prints the reason on stderr. To review outside contributors'
PRs too, set `REVIEW_UNTRUSTED_PRS=1`; their reviews are then static only.
See [Trust and PR code](how-it-works.md#trust-and-pr-code).

## A PR is skipped for "agent session config"

A PR that changes `.claude/` (settings, hooks, skills, agents, commands),
`.mcp.json`, `CLAUDE.md`, `AGENTS.md` or Codex's `.agents/` or `.codex/` (the
directories and `.mcp.json` in any letter case, the memory files by their exact
names), or that adds or changes a symlink, is never reviewed
automatically, even from a trusted author: the review session would load
those files from the PR. The skip line lists at most five names, with unusual
characters replaced by `_`. Read those changes yourself, then:

```bash
orca-pr-review --repo owner/name dispatch --pr 123 --allow-session-config
```

The full path list is `SESSION_CONFIG_PATHS` in `lib/common.sh`.

## "cannot read the gh user" or the Orca worktree list

`select` and `dispatch` now stop rather than guess when GitHub or Orca can't
answer: guessing would review your own PRs or treat a reviewed PR as new.
Check `gh auth status` and that Orca is running (`orca status`), then run
again.
