# Repo conventions for agents

`CLAUDE.md` is a symlink to this file. Edit `AGENTS.md`.

## What this is

orca-pr-review is a Claude Code plugin: a bash CLI plus skills and subagents. User docs live in `README.md` and
`docs/`; read `docs/how-it-works.md` before changing behavior.

The security model is in `docs/security.md`: the plugin assumes your own
laptop, a trusted repo and trusted collaborators, and its guards are defence
in depth within that, not a sandbox. A change that adds a guard, removes one,
or moves one between "enforced" and "instructed" updates that page's table.

| Path | What |
| --- | --- |
| `bin/orca-pr-review` | CLI entry point. Sources `lib/*.sh`. |
| `lib/` | CLI logic, one file per area (select, dispatch, post, review, ledger, setup). |
| `config/defaults.sh` | Every setting and its default. The settings reference is `docs/configuration.md`. |
| `skills/` | Skills. |
| `agents/` | Subagents (`pr-concerns`, `pr-validator`). |
| `hooks/hooks.json` | Claude Code SessionStart hook that records the plugin root for the shim. |
| `.claude-plugin/` | Claude Code plugin manifest and marketplace. |

## Codex

The plugin is Claude Code only. Codex can already run the scheduled
dispatcher (`DISPATCHER_AGENT=codex`), since that agent only runs a shell
command. Running the reviews themselves in Codex is planned, not built;
`REVIEW_AGENT=codex` is refused with a message until it is. An earlier Codex
packaging (`.codex-plugin/`, `.agents/plugins/marketplace.json`) was removed
because a Codex install could not run reviews; it is in git history.

What a Codex review path needs, from research against Codex CLI 0.164
(verify again before building):

- Stage B: `codex exec review --base <branch> --json` (or `--output-schema`)
  in place of `/code-review`. Review targets and custom instructions are
  mutually exclusive, so concerns and repo prompts need another way in.
- Stages A and C: Codex agents are TOML files in `~/.codex/agents/`
  (`name`, `description`, `developer_instructions`, optional `model`,
  `model_reasoning_effort`). Plugins don't appear to ship agents, so `setup`
  would install them. How the model spawns one is undocumented.
- Dispatch: launch with `--agent "$REVIEW_AGENT"` (already wired) and a model
  map, since `opus`/`sonnet` mean nothing to Codex.
- Hooks: Codex plugin hooks exist but need user trust and expose
  `PLUGIN_ROOT` rather than `CLAUDE_PLUGIN_ROOT`.
- Skills: confirm how a prompt invokes a plugin skill by name.

Don't half-add it by branching inside the skills: build the path, then add
the packaging back.

## Checks

Run after any change:

```bash
shellcheck bin/orca-pr-review lib/*.sh config/defaults.sh
claude plugin validate .
```

- **Docs follow behavior.** A changed setting goes in `config/defaults.sh` and
  `docs/configuration.md`; a changed CLI command goes in `usage()` in
  `bin/orca-pr-review` and the CLI block in `README.md`.

## The shim and plugin root

Claude Code installs each version under a new path. Automations and sessions
call `~/.local/bin/orca-pr-review`, which reads
`~/.config/orca-pr-review/plugin-root`. Claude Code's SessionStart hook keeps
that file current. `install-shim --latest` refreshes it by hand: plain
`install-shim` run through the shim re-records the old version, so `--latest`
looks up the newest installed version in Claude Code's plugin cache and hands
off to it. Never hardcode a plugin cache path anywhere.

## Code conventions

- Bash with `set -euo pipefail`. Keep shellcheck clean; `.shellcheckrc` holds
  the repo settings, and every `# shellcheck disable=` needs a reason beside it:

  ```bash
  shellcheck bin/orca-pr-review lib/*.sh config/defaults.sh
  ```

- Don't write `local x=$(cmd)`: `local` hides the failure of `cmd`. Declare it,
  then assign it with `x=$(cmd) || return 1`.
- Never drop an error silently: `die` with a message, or `log` it and say why
  continuing is safe.
- GitHub reads go through `gh_retry` where a transient failure is possible.
- Settings are `UPPER_SNAKE` in `config/defaults.sh`, with a comment. A repo's
  `.orca-pr-review/pipeline.sh` can set only the keys in `REPO_PIPELINE_KEYS`;
  adding one is a security decision, because the repo's committers control it.
  Trust settings (`REVIEW_UNTRUSTED_PRS`, `EXTRA_SKILLS_ALLOW`, `REVIEW_AGENT`)
  must never be added.
- Repo-supplied text reaches the review prompt only through
  `repo_review_brief` in lib/dispatch.sh, fenced with a per-run nonce and
  validated (stage names, skill names). Don't print repo text into a prompt
  any other way.
- An untrusted PR's code is never run: the trust signal goes into the prompt,
  and the skills and subagents must keep honoring it.
- The review sessions never submit a review, approve, or post a public comment.
  The only GitHub write in an unattended run is the pending review from
  `post`. Keep it that way. What enforces it: sessions get the CLI with
  `--unattended` (or `ORCA_PR_REVIEW_UNATTENDED=1`), and in that mode
  bin/orca-pr-review refuses every command that publishes, deletes, or
  changes setup (`unattended_guard`). A new command that writes to GitHub
  or changes setup must be refused there. What does not enforce it: the
  session holds the user's gh token and could call `gh` directly. The guard
  stops a model talked into using the CLI by injected PR text; it is not a
  sandbox.
