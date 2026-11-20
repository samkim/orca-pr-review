---
name: setup
description: Set up orca-pr-review for a GitHub repository - install the stable CLI shim, link the repo's Orca project, choose risky paths for model routing, preview which PRs would be reviewed, and create the scheduled dispatcher automation. Use when the user asks to set up, configure, or enable automated PR reviews with orca-pr-review, or to add another repo to it.
---

# Set up orca-pr-review for a repo

`ROOT` below is the plugin's install directory, `$CLAUDE_PLUGIN_ROOT`.

The CLI is `ROOT/bin/orca-pr-review` until the shim is installed, then
`~/.local/bin/orca-pr-review`. Below, `CLI` means whichever exists. Run each
step, show the user the result, and stop to ask only where a step says so.

1. **Shim.** `ROOT/bin/orca-pr-review install-shim`. Orca automations and
   review sessions call this stable path; the plugin's own path changes with
   every version.
2. **Repo.** Use the repo the user named, or the current directory's
   (`gh repo view --json nameWithOwner`). `CLI --repo <owner/name> doctor` and fix
   anything marked MISS or FAIL. Orca must know the repo: if `init` cannot find
   it, run `orca repo add --path <checkout>` with the user's checkout path.
3. **Config.** `CLI --repo <owner/name> init`. It writes
   `~/.config/orca-pr-review/repos/<owner>--<name>.sh`.
4. **Risky paths.** If the repo's `.orca-pr-review/pipeline.sh` already sets
   `RISKY_PATHS`, show it and skip this step unless the user wants a personal
   override: `config set` writes to the personal config, which wins over the
   repo's value. Otherwise propose a `RISKY_PATHS` regex: directories where a missed
   bug is expensive (auth and permissions, payments, persistence and migrations,
   concurrency-heavy code, public API surfaces, deploy and install config). Base
   it on the repo's layout and contributor docs (CLAUDE.md, AGENTS.md,
   CONTRIBUTING.md), not on guesses. Show the regex and why, ask the user to
   confirm or edit it, then save it with
   `CLI --repo <owner/name> config set RISKY_PATHS '<regex>'`. PRs touching these
   paths, or changing more than `LOW_MODEL_MAX_LINES` lines, get
   `REVIEW_MODEL_HIGH`.
5. **Other settings.** Show the defaults that matter from
   `ROOT/config/defaults.sh` (recency, concurrency, window,
   models, skipping own and stacked PRs, and whether to skip bot PRs, which
   are reviewed by default) and ask whether any should change
   for this repo. Save each with `CLI --repo <owner/name> config set <KEY> <VALUE>`.
6. **Preview.** `CLI --repo <owner/name> select --all` and
   `CLI --repo <owner/name> dispatch --dry-run`. Show which PRs would be
   reviewed, with which model, and which were skipped and why.
7. **Automation.** Ask before this step: it creates a scheduled automation in
   Orca. `CLI --repo <owner/name> install-automation` creates it disabled and
   records its id, which also turns on backfill. Tell the user how to enable it
   (the command it prints) and suggest testing first with
   `CLI --repo <owner/name> dispatch --pr <n>` on one PR, which posts a pending
   review that only they can see.

Reviews are posted as PENDING GitHub reviews under the user's own account. They
see them in the PR's "Finish your review" panel and decide whether to submit.
