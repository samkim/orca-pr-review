# How it works

orca-pr-review has three parts:

- a bash CLI (`bin/orca-pr-review`, with its logic in `lib/`) that selects pull
  requests, starts review sessions, posts reviews and tracks state
- skills and subagents that run inside Claude Code and do the reviewing
- an Orca automation that runs the CLI on a schedule

## The schedule

`orca-pr-review install-automation` creates one Orca automation per repo. It
fires hourly inside the review window (`WINDOW_DAYS`, `WINDOW_START_HOUR` to
`WINDOW_END_HOUR`, local time, Monday to Friday 9:00 to 15:00 by default) and
is created disabled.

Each run does two things:

1. **Precheck.** `orca-pr-review select --check` exits non-zero when no PR is
   waiting, and Orca skips the run without starting an agent.
2. **Dispatch.** A small agent (`DISPATCHER_AGENT`, Claude Code with haiku at
   low effort by default) runs
   `orca-pr-review dispatch` once and reports its output. The dispatcher
   creates one Orca worktree and one Claude Code session per selected PR, up to
   `MAX_IN_FLIGHT` at a time.

When a review finishes and frees a slot, it calls `orca-pr-review backfill`,
which starts the dispatcher again if more PRs are waiting and the window is
still open.

## Selecting pull requests

A PR is selected when it is:

- open and not a draft
- updated within `RECENCY_DAYS` (7)
- without any review yet
- not authored by you (`SKIP_OWN_PRS`) or by anyone in `EXCLUDE_AUTHORS`
- not from a bot, if `SKIP_BOT_AUTHORS=1` (bots are included by default)
- changing at most `MAX_FILES` files (80)
- not stacked on another open PR's branch (`SKIP_STACKED`); stacked PRs wait
  until their base merges
- trusted: its head branch is in the repo, or its author is an owner, member
  or collaborator. Untrusted PRs (outside fork PRs) are reviewed only with
  `REVIEW_UNTRUSTED_PRS=1`, and then statically, without running their code.
  See [Trust and PR code](#trust-and-pr-code).
- not already handled, according to the ledger

Re-reviews (below) take free slots before new PRs. Run
`orca-pr-review select` to see what would be picked now, or `select --all` to
ignore the slot limit. Reasons for skipping a PR are printed on stderr.

## The review session

Each PR's session runs the `orca-pr-review:review-pr` skill in its own
worktree. It works unattended and keeps scratch output in `.review/`.

| Stage | Who | What |
| --- | --- | --- |
| A | `pr-concerns` subagent (sonnet) | Reads the PR description and file list, not the diff, and writes what must hold for the PR to be correct. |
| B | `/code-review` at high effort | Reviews the diff, told which concerns to check. Repo focus text and extra skills apply here. |
| C | `pr-validator` subagent (sonnet) | Tries to refute each finding against the code, runs targeted tests, and drafts the review. |
| | the session | Re-checks any major finding the validator refuted before dropping it. |
| D | `orca-pr-review post` | Posts a pending review, updates the ledger, moves the Orca card to in-review, then runs backfill. |

The session is told not to submit a review, approve, request changes, resolve
a thread, or post a public comment; the only GitHub write it should make is
the pending review in stage D. Part of that is enforced and part is not:

- **Enforced by the CLI.** The session's prompt hands it the CLI as
  `orca-pr-review --unattended --repo owner/name`, and the skills require that
  exact string. In unattended mode (`--unattended`, or
  `ORCA_PR_REVIEW_UNATTENDED=1`) the CLI refuses every command that
  publishes, deletes, or changes setup: `review submit`, `review resolve`,
  `review comment delete`, `dispatch`, `config set` and the like. Posting the
  pending review, editing it, reading, the session's own `reviewed`/`failed`
  ledger write, and `backfill` still work. Orca cannot set environment
  variables for a launched agent, so the flag, not the variable, is what
  review sessions get.
- **Not enforced.** The session runs as you, with your gh token. Nothing stops
  it from calling `gh` or the GitHub API directly, or the CLI without the
  flag. The unattended mode guards against a model talked into publishing by
  instructions injected through the PR; it is not a sandbox.

Finalizing is different: when you return to the session and ask for a change
or a submit, the `finalize-review` skill runs the CLI without `--unattended`,
for the actions you asked for.

### Model routing

The session runs `REVIEW_MODEL_HIGH` (opus) when the PR touches a path matching
`RISKY_PATHS` or changes more than `LOW_MODEL_MAX_LINES` (250) lines of code
that is not a test (`TEST_PATHS`) or generated (`GENERATED_PATHS`). Otherwise
it runs `REVIEW_MODEL_LOW` (sonnet). Both use `REVIEW_EFFORT` (high).
`orca-pr-review route <pr>` prints the choice and why.

## Trust and PR code

The assumptions behind this section, and what it does and doesn't protect
against, are summarized in the [security model](security.md). This section
covers the mechanics.

The review session runs in a checkout of the PR head, as you, with your gh
token, SSH keys and Claude Code login. Three things follow from that.

**Running the PR's code.** The validator may run a targeted test to check a
finding. For a trusted PR that is allowed. For an untrusted PR the prompt says
so, and the skills and subagents are told to run nothing from the checkout:
no tests, builds, linters, type checkers or package scripts. This is an
instruction to the model, not a sandbox.

**Repo rules.** The concerns pass and the validator read `CLAUDE.md`,
`AGENTS.md` and `CONTRIBUTING.md` from the base branch with `git show`, and
treat the PR head's copies as part of the change, so a PR can't rewrite the
rules it is reviewed against.

**Session config in the checkout.** An agent started in the worktree loads
its project config from the PR head: Claude Code's `.claude/` (settings and
hooks, skills, agents, commands), `.mcp.json`, and memory files such as
`CLAUDE.md` and `AGENTS.md`. Claude Code has flags that would stop this
(`--setting-sources user`, `--strict-mcp-config`), but neither
`orca agent launch` nor `orca worktree create --agent` can pass extra
arguments to the agent, so the plugin can't set them.

So a PR that changes session config is **not reviewed automatically, whether
or not its author is trusted**. The paths are `SESSION_CONFIG_PATHS` in
`lib/common.sh`: `.claude`, `.agents` and `.codex` (as directories or as a
bare name, so a symlink called `.claude` counts), `.mcp.json`, and
`CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md` and `AGENTS.override.md` at any
depth. The directory names and `.mcp.json` match in any letter case, because
on a case-insensitive filesystem such as macOS's `.Claude/settings.json` loads
like `.claude/settings.json`. The memory files match only with exactly that
case, so ordinary doc pages such as `docs/agents.md` are not caught (see the
residual risk below). Nested `CLAUDE.md` files count because Claude Code loads
them when it reads files in their directory; nested `AGENTS.md` files count
because a `CLAUDE.md` is often a symlink to, or an `@import` of, the
`AGENTS.md` beside it. A PR that adds or changes a symlink anywhere is
treated the same way, since a symlink can point a config path at a file with
an innocent name. The check runs three times:

1. `select` skips the PR and prints the files. Its file list comes from
   `gh pr list`, which stops at 100 files per PR; for a PR with more (when
   `MAX_FILES` allows it) select reads the full list the way dispatch does,
   and skips the PR only if that fails. Symlinks aren't checked at this step.
2. `dispatch` checks again right before launching, which covers `--pr` runs
   and pushes made after selection. It reads the full file list through the
   paginated REST API (which stops at 3000 files; a PR with more, or any list
   shorter than the PR's `changedFiles`, is skipped), finds symlinks by
   reading the head commit's file tree (for a tree too large for GitHub to
   list in full, only the listed part is checked here), and skips the PR if
   its head moved while it was checking.
3. The session checks again in stage 0, with the two commands the prompt hands
   it: `git diff --name-only` matched against the same pattern, and `git diff --raw`
   for new mode `120000` (a symlink). It stops with a failure if either lists
   a file the user didn't allow.

**The session reviews exactly the commit dispatch checked.** The prompt
carries the head SHA. In stage 0 the session checks that SHA out detached and
compares it with the PR's live head; if the head moved, it records a failure
(`head moved since dispatch`) and stops, and the next run checks the new head
and dispatches it again. It never continues on a head nobody checked.

To review such a PR anyway, read the config changes yourself, then run
`dispatch --pr N --allow-session-config`. The session is told which files you
allowed, ignores any instruction they add, and names them in the review.
Allowing applies to that one run: a later push that changes more config is
skipped again. Before any later session starts in the PR's existing worktree,
the dispatcher checks out there the commit it just checked, so no session
starts at the commit you allowed once. If the worktree has uncommitted
changes to tracked files, the PR is skipped rather than moved.

Residual risk:

- Config that already exists on the PR's base branch is loaded as it would be
  for any session you start in that repo. That includes `@imports` in a base
  branch `CLAUDE.md`: an imported file whose name matches no pattern above is
  read from the PR's checkout, so a PR that edits it changes what the session
  loads. The same holds for a symlink already on the base branch whose target
  the PR edits.
- Config is loaded when the session starts, from whatever the worktree had
  checked out then, before stage 0 runs. A first review's worktree is created
  by `orca worktree create --pr`, which checks out the PR's head at that
  moment and takes no SHA. So if the PR moves between dispatch's check and
  the worktree's creation, the session starts on an unchecked head: stage 0
  catches it and stops, but that head's hooks and settings may already have
  run. A re-review (or a retried first review) starts in the existing
  worktree, on the commit the previous session checked out.
- With `--allow-session-config` the PR's config, hooks included, runs before
  the session's own check.
- A memory file named in another letter case (`claude.md`) is not matched, but
  on a case-insensitive filesystem Claude Code would open it as `CLAUDE.md`.
  A trusted collaborator has no reason to do that, so the plugin accepts it
  rather than skipping every PR that touches an ordinary `docs/agents.md`.
- The static-only rule for untrusted PRs depends on the model following it.
Leave `REVIEW_UNTRUSTED_PRS=0` on public repos unless you accept that.

## What the review looks like

The review has two audiences.

- **The main comment** is for a person: what the PR does, a verdict, the issues
  ranked by impact, and questions only the author can answer.
- **Each inline comment** is a self-contained work order a coding agent can act
  on: Problem, Fix, Test, and Constraints when a repo rule applies.

## Finishing a review

The review stays pending, visible only to you, until you submit it. Read it on
GitHub, then return to the PR's session in Orca and tell Claude what to change
("drop comment 2", "tone down the verdict"). When it reads right, ask Claude to
submit it. This runs the `orca-pr-review:finalize-review` skill, which submits
through the API with the main comment attached.

Don't submit from GitHub's "Finish your review" box. It doesn't show a main
comment set through the API, and submitting there replaces it with whatever is
in the box, usually nothing.

## Re-reviews

After you submit a review, the PR is watched. It is reviewed again when:

- you are re-requested as a reviewer (picked up at the next run), or
- someone other than you pushes, replies on one of your threads, or comments on
  the PR, and then nothing happens for `REREVIEW_QUIET_HOURS` (1 hour)

Bot activity doesn't count. The last verdict doesn't matter: an approved PR
that changes is re-reviewed too. A PR gets at most `MAX_REVIEW_ROUNDS` (3)
reviews, the first included. A PR with an unsubmitted review from you is left
alone. Set `REREVIEW=0` to turn re-reviews off, or run
`orca-pr-review dispatch --pr N` to re-review one now.

A re-review runs in the PR's existing worktree, in a new session, with the
`orca-pr-review:re-review-pr` skill. It checks each earlier thread against the
new code (verified, not fixed, fixed differently, deferred, disputed), reviews
only the code changed since your last review, and posts a pending review whose
replies sit in the original threads. Finalize and submit it as usual. The
session then offers to resolve the threads it verified.

## State

Review state lives in a per-repo ledger at
`~/.local/state/orca-pr-review/<owner>--<name>/ledger.json`. Each PR entry has
a state and a timestamp. The states are `dispatched` (a session was started),
`reviewed` (it posted a pending review), `failed` (it, or the launch, stopped
early) and `submitted` (you submitted the review through `review submit`, which
the `finalize-review` skill runs). A `dispatched` entry older than
`STALE_HOURS` (2) stops holding a slot and is recorded as `failed`.

A failed re-review is retried at the same round on the activity that
triggered it: at the next run once its head has moved, and once more at an
unchanged head (dispatch counts attempts in the entry's `attempt`). After that,
only new activity since the failure starts it again. Inspect it with
`orca-pr-review ledger dump`.

## The shim

Claude Code installs each plugin version at a different path. Orca automations
and review sessions call the stable shim at `~/.local/bin/orca-pr-review`,
which reads the current plugin location from
`~/.config/orca-pr-review/plugin-root`. A SessionStart hook in the plugin
rewrites that file each time Claude Code starts, so updates take effect without
touching the automation. To refresh it by hand, run
`orca-pr-review install-shim --latest`, which finds the newest installed
version in Claude Code's plugin cache and lets it rewrite the file.
