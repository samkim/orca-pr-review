# orca-pr-review

Automated pull request reviews for [Orca](https://www.onorca.dev/), the
desktop environment for running coding agents in parallel worktrees.

orca-pr-review is a Claude Code plugin. An Orca **automation** checks your
GitHub repo on a schedule, creates an Orca **worktree** for each PR that needs
a review, and launches a Claude Code session in it. Each session reviews its
PR and leaves the result as a **pending** review under your account. Nothing
is published until you read it and submit it.

Because every review lives in its own worktree, you can open any PR's
worktree in Orca later, talk to the session that wrote the review, and have it
revise or submit.

> [!IMPORTANT]
> It is meant for **your own laptop and a project you trust**. Review sessions
> run as you, with your gh token and SSH keys, and may run a trusted PR's
> tests. Read the [security model](docs/security.md) before pointing it at a
> repo with contributors you don't know.

## What you get

- **Reviews that check intent, not just the diff.** A first pass reads only the
  PR description and file list and writes down what must be true for the PR to
  be correct. `/code-review` then checks the diff against that list.
- **Findings that survived a skeptic.** A validator tries to refute each
  finding against the code and runs targeted tests. What it can't refute is
  what you see.
- **A review written for two readers.** The main comment is a short overview
  for the author: what the PR does, a verdict, issues by impact, open
  questions. Each inline comment is a work order a coding agent can act on:
  Problem, Fix, Test.
- **Follow-up reviews.** When the author pushes or replies, the PR is reviewed
  again in the same Orca worktree: each earlier thread is checked against the new
  code, and only the changed code is reviewed.
- **You stay in control.** Reviews are pending until you submit them. Revise
  one by talking to the session that wrote it, then ask it to submit.

## How a review runs

```
Orca automation (hourly, in your review window)
  precheck    orca-pr-review select --check    skip the run if nothing waits
  dispatch    orca-pr-review dispatch          one Orca worktree + Claude
                                               Code session per PR
                     │
                     ▼  per PR (skill: review-pr)
  A  pr-concerns     what must hold for this PR to be correct
  B  /code-review    high effort, focused on those concerns
  C  pr-validator    refute each finding, run tests, draft the review
  D  post            pending review, ledger update, start the next PR
     finalize        with you, later: revise, then submit
     re-review       after the author responds
```

See [How it works](docs/how-it-works.md) for selection rules, model routing,
re-reviews and state.

## Requirements

- [Orca](https://www.onorca.dev/), running, with its `orca` CLI on your `PATH`,
  and the repo added to Orca as a project
- Claude Code
- `gh`, logged in
- `jq`, `git`, `bash`

Tested on macOS.

## Install

```bash
claude plugin marketplace add samkim/orca-pr-review
claude plugin install orca-pr-review@orca-pr-review
```

To install from a local checkout instead, pass its path in place of
`samkim/orca-pr-review`.

orca-pr-review is a Claude Code plugin. Running reviews in Codex is planned;
the scheduled dispatcher can already run in Codex with `DISPATCHER_AGENT=codex`
(see [Configuration](docs/configuration.md)).

Then open the repo in Orca, start a Claude Code session in it, and ask it to
set up orca-pr-review. The `orca-pr-review:setup` skill walks you through it:

1. installs the stable `~/.local/bin/orca-pr-review` shim
2. links the GitHub repo to its Orca project (`init`)
3. helps choose risky paths that get the stronger model
4. previews which PRs would be reviewed now
5. creates the hourly Orca automation, **disabled**

Enable the automation in Orca, or from the CLI, when the preview looks right:

```bash
orca automations edit --id <automation-id> --enabled
```

## Finishing a review

Read the pending review on GitHub. Then open the PR's worktree in Orca
(`pr-<number>-review`), go to its Claude Code session, and tell it what to
change ("drop comment 2", "soften the verdict"). When
it reads right, ask it to submit.

> [!WARNING]
> Don't submit from GitHub's "Finish your review" box. It replaces the main
> comment with whatever is in the box, which is usually nothing.

Review sessions run the CLI in unattended mode, where it refuses to submit,
approve, resolve threads, delete comments, or change setup, so instructions
injected into a PR can't make the CLI publish under your account. Finalizing
runs without that mode, and only on your request in the session. This is a
guard, not a sandbox: the session holds your gh token and could still call
`gh` directly.

## Configuration

The defaults: weekdays 9:00 to 15:00 local time, PRs updated in the last 7
days and not yours, at most 80 changed files, 3 reviews at a time, 3 reviews
per PR. Change any of them per repo:

```bash
orca-pr-review --repo owner/name config set MAX_IN_FLIGHT 2
```

A repo can also commit its own review focus, prompt, extra review skills and
risky paths in `.orca-pr-review/`, read from the default branch only.

Fork PRs from outside contributors are skipped by default, because a review
can run the PR's tests with your credentials. See
[Trust and PR code](docs/how-it-works.md#trust-and-pr-code).

See [Configuration](docs/configuration.md) for every setting.

## CLI

```
orca-pr-review [--repo owner/name] [--unattended] <command>
  init | config show|get|set | install-automation | update-automation | select [--check|--all] | route <pr>
  dispatch [--pr N [--allow-session-config]] [--dry-run] [--close-when-done] | post <pr> <review.json>
  review show|set-body|comment add|edit|delete|submit|threads|resolve <pr> ...
  ledger get|set|in-flight|dump | backfill | in-window | doctor | session-checks <base>
  install-shim [--latest] | record-root | repos
```

`orca-pr-review help` describes each command.

## Documentation

- [How it works](docs/how-it-works.md)
- [Configuration](docs/configuration.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Security model](docs/security.md)

## License

MIT. See [LICENSE](LICENSE).
