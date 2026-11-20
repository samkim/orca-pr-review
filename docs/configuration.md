# Configuration

Settings are bash variables. They load in this order, and later files win:

1. `config/defaults.sh` in the plugin. Don't edit it: updates replace it.
2. `~/.config/orca-pr-review/config.sh`, for every repo (optional).
3. `~/.config/orca-pr-review/repos/<owner>--<name>.sh`, for one repo. Written by
   `orca-pr-review init`.

`$XDG_CONFIG_HOME` replaces `~/.config` when set.

Change a per-repo setting with the CLI, which quotes the value safely:

```bash
orca-pr-review --repo owner/name config set RISKY_PATHS '^(src/auth|migrations)/'
orca-pr-review --repo owner/name config get MAX_IN_FLIGHT
orca-pr-review --repo owner/name config show
```

## Settings

### Which PRs are reviewed

| Setting | Default | Meaning |
| --- | --- | --- |
| `RECENCY_DAYS` | `7` | Only PRs updated within this many days. |
| `MAX_IN_FLIGHT` | `3` | Concurrent reviews per repo. |
| `MAX_FILES` | `80` | Skip PRs that change more files than this. |
| `STALE_HOURS` | `2` | A dispatched review older than this stops holding a slot. |
| `SKIP_OWN_PRS` | `1` | Skip PRs authored by the gh user. |
| `SKIP_BOT_AUTHORS` | `0` | `1` skips PRs from bot accounts. |
| `EXCLUDE_AUTHORS` | `""` | Space-separated logins to skip. |
| `SKIP_STACKED` | `1` | Skip PRs based on another open PR's branch. |
| `REVIEW_UNTRUSTED_PRS` | `0` | `1` also reviews untrusted PRs (see below), statically: the session is told not to run any code from the checkout. Personal config only: a repo's `pipeline.sh` can't set it. |

A PR is **trusted** when its head branch is in the repo itself (pushing a
branch there needs write access) or its author's association with the repo is
`OWNER`, `MEMBER` or `COLLABORATOR`. Every other PR, typically a fork PR from
an outside contributor, is untrusted. Untrusted PRs are skipped by default
because a review session may run the PR's tests, and test setup code
(`init()`, `conftest.py`, a vitest setup file) runs with your gh token and SSH
keys. With `REVIEW_UNTRUSTED_PRS=1` they are reviewed without running anything,
and, like every PR, one that changes agent session config (`.claude/`,
`.mcp.json`, `CLAUDE.md`, `AGENTS.md` and the like; directories in any letter
case, memory files by exact name) or
adds or changes a symlink is never started automatically, since the session
would load that config. See
[Trust and PR code](how-it-works.md#trust-and-pr-code).
`dispatch --pr N` always dispatches the PR you name, with the same static-only
rule when it is untrusted.

### Re-reviews

| Setting | Default | Meaning |
| --- | --- | --- |
| `REREVIEW` | `1` | `0` turns re-reviews off. |
| `REREVIEW_QUIET_HOURS` | `1` | Wait this long after the last activity. Re-requests skip the wait. |
| `MAX_REVIEW_ROUNDS` | `3` | Total reviews per PR, the first included. |

### Schedule

| Setting | Default | Meaning |
| --- | --- | --- |
| `WINDOW_DAYS` | `1-5` | Cron day-of-week field. `*` is every day. |
| `WINDOW_START_HOUR` | `9` | First hour of the window, inclusive, local time. |
| `WINDOW_END_HOUR` | `15` | Last hour a run starts, inclusive. |

The automation's cron line is built from these when it is created. If you
change them later, recreate the automation or edit its trigger in Orca. The
dispatcher and backfill also check the window on every run; `FORCE=1` bypasses
that check.

### Dispatcher agent

| Setting | Default | Meaning |
| --- | --- | --- |
| `DISPATCHER_AGENT` | `claude` | The agent the scheduled automation starts. It only runs `dispatch`, so `codex` or any other agent Orca can launch works. |
| `DISPATCHER_AGENT_ARGS` | `""` | Extra arguments for that agent. Empty picks a cheap default: `--model haiku --effort low` for claude, `-c model_reasoning_effort=low` for codex, none for others. |

The automation is created with these values. After changing either, run
`orca-pr-review --repo owner/name update-automation` to apply them to the
existing automation; `doctor` reports a mismatch. Personal config only.

### Review agent

| Setting | Default | Meaning |
| --- | --- | --- |
| `REVIEW_AGENT` | `claude` | The agent review sessions run in. Only `claude` works today; with `codex`, `dispatch` prints why and starts nothing. Personal config only: a repo's `pipeline.sh` can't set it. |

### Stages and models

| Setting | Default | Meaning |
| --- | --- | --- |
| `REVIEW_STAGES` | `concerns review validate` | Remove `concerns` to skip stage A. Review and validation always run. Only `concerns`, `review` and `validate` are accepted; a `pipeline.sh` value with anything else is ignored, and a bad personal value stops the run. |
| `EXTRA_SKILLS_ALLOW` | `""` | Space-separated skill names that `extra-skills.txt` may name. Empty allows any valid skill name. Personal config only. |
| `REVIEW_MODEL_HIGH` | `opus` | Model for risky or large PRs. |
| `REVIEW_MODEL_LOW` | `sonnet` | Model for everything else. |
| `REVIEW_MODEL_OVERRIDE` | `""` | Force one model for every PR. |
| `REVIEW_EFFORT` | `high` | Effort for the review session. |
| `LOW_MODEL_MAX_LINES` | `250` | Lines of non-test, non-generated code above which the high model is used. |
| `RISKY_PATHS` | `""` | Extended regex over repo-relative paths that get the high model. Empty routes by size only. |
| `TEST_PATHS` | (see defaults) | Paths that don't count toward size or risk. |
| `GENERATED_PATHS` | (see defaults) | Same, for lock files, generated code and vendored code. |

The concerns and validator subagents use the model in their own definitions
(sonnet), not these settings.

### Other

| Setting | Default | Meaning |
| --- | --- | --- |
| `REPO_CONFIG_LOOKUP` | `1` | `0` stops reading `.orca-pr-review/` from the repo. Only local settings apply. |
| `ORCA_REPO_ID`, `REPO_PATH` | (written by `init`) | The Orca repo and its checkout. |
| `AUTOMATION_ID` | (written by `install-automation`) | Empty disables backfill. |

Environment variables: `ORCA_PR_REVIEW_REPO` sets the default `--repo`, and
`ORCA_PR_REVIEW_SHIM` moves the shim from `~/.local/bin/orca-pr-review`.

## Repo-owned settings

A repo can commit review settings in a `.orca-pr-review/` folder. They are
read through the GitHub API from the **default branch only**, so a PR can't
change the rules its own review runs under.

| File | Effect |
| --- | --- |
| `pipeline.sh` | A subset of settings, as `KEY='value'` lines. |
| `focus.md` | What reviews should emphasize. Each item becomes a question the review answers with `file:line` evidence. |
| `review-prompt.md` | Replaces the instructions for the `/code-review` step. The rest of stage B still applies. |
| `extra-skills.txt` | Other review skills to run after stage B, one name per line. Their findings are merged and validated with the rest. Each line must be a skill name matching `^[a-z0-9][a-z0-9:_-]*$` (and be in `EXTRA_SKILLS_ALLOW` when that is set); other lines are logged and dropped. The session runs each one as a skill with the review session's full permissions, so treat this file as code you trust. |

`pipeline.sh` is parsed, never sourced. Only single-quoted `KEY='value'` lines
are read, and only these keys: `RISKY_PATHS`, `EXCLUDE_AUTHORS`,
`REVIEW_STAGES`, `SKIP_BOT_AUTHORS`, `TEST_PATHS`, `GENERATED_PATHS`. Anything
else is logged and ignored.

```bash
# .orca-pr-review/pipeline.sh
RISKY_PATHS='^(pkg/authz|migrations)/'
EXCLUDE_AUTHORS='release-bot'
```

Each text file is capped at 8000 bytes in the prompt. In the prompt, each
file's text sits between fence lines carrying a random nonce made fresh for
each dispatch, so the text cannot close its own fence; text that contains the
nonce is refused.

None of these files can lift the review's safety rules: no edits, no commits,
no submitted reviews, no public comments.

### Personal overrides

Your local settings win over the repo's:

- A `KEY=` line in `~/.config/orca-pr-review/config.sh` or
  `~/.config/orca-pr-review/repos/<owner>--<name>.sh` wins over the same key
  in `pipeline.sh`.
- A file with the same name in `~/.config/orca-pr-review/repos/<owner>--<name>/`
  (for example `focus.md`) replaces the repo's file.
