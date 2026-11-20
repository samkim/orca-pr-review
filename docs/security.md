# Security model

orca-pr-review is built for one setup: **your own laptop, reviewing a project
you trust, whose collaborators you trust.** It is not a sandbox and it is not
safe to point at arbitrary public repositories. This page states what it
assumes, what it guards against anyway, and what it does not.

## Assumptions

Everything below rests on these. If one doesn't hold for you, the plugin is the
wrong tool, or you need to add your own isolation (a VM, a separate account, a
scoped token).

1. **It runs on a machine you control, as you.** Review sessions run with your
   gh token, SSH keys, Claude Code login, environment, and filesystem access.
   Anything a session does, it does as you.
2. **The repository is trusted.** Its default branch, including
   `.orca-pr-review/` (focus, review prompt, extra skills, `pipeline.sh`) and
   any Claude Code config (`.claude/`, `CLAUDE.md`, `.mcp.json`), is treated
   like code you would run yourself. Anyone who can merge to it can shape your
   review sessions.
3. **PR authors are trusted collaborators.** By default only PRs from a branch
   in the repo itself, or by an owner, member or collaborator, are reviewed.
   Their PRs are checked out, read, and may have targeted tests run on your
   machine.
4. **The model is mostly obedient, not adversarial.** Several guards below are
   instructions to the model. They hold against mistakes and against
   instructions injected through PR text; they do not hold against a model
   that is determined to ignore them.
5. **Your gh token can already do what you can.** The plugin does not narrow
   its scopes. If you want a review session to be unable to approve or merge,
   that has to come from the token or the account, not from this plugin.

## What it guards against anyway

These are defence in depth for the trusted setup above: they catch mistakes,
prompt injection through PR content, and the occasional surprising PR. Each
says whether it is **enforced** (by the CLI or the dispatcher, whatever the
model does) or **instructed** (the model is told, and usually complies).

| Guard | Kind | What it does |
| --- | --- | --- |
| Pending reviews only | Enforced | Unattended sessions get the CLI with `--unattended`, which refuses submit, approve, resolve, delete, and setup changes. You submit later, in the conversation. |
| Untrusted PRs skipped | Enforced | Fork PRs from authors who aren't owners, members or collaborators are not selected unless you set `REVIEW_UNTRUSTED_PRS=1`. |
| No code from untrusted PRs | Instructed | If you do review them, the session is told to read only: no tests, builds or scripts. |
| Session config changes stop the review | Enforced, then instructed | `select` and `dispatch` don't start a PR that changes `.claude/`, `.mcp.json`, `CLAUDE.md`, `AGENTS.md` and similar, or adds a symlink. The session is told to check again at stage 0. `--pr N --allow-session-config` overrides it for one run. |
| Exact commit | Enforced, then instructed | `dispatch` skips a PR whose head moved while it was checking. The session is told to check out that exact commit and stop if the head moved since. |
| Rules come from the base branch | Instructed | Contributor docs are read from the base branch, so a PR can't rewrite the rules it is reviewed against. |
| Repo text is fenced | Enforced, then instructed | Stage and extra-skill names are validated by the CLI. Repo-supplied prompt text sits inside per-run random fences the model is told to respect. |
| Safe shell handling | Enforced | PR titles, file paths and config values are passed to shell, jq and GraphQL as data (quoted or as arguments), not spliced into code. Two review passes audited this; report anything they missed. |

## What it does not protect against

- **A malicious collaborator or a compromised default branch.** Both are inside
  the trust boundary by assumption 2 and 3.
- **A determined or jailbroken model.** The session holds your gh token and
  could call `gh` directly; `--unattended` only stops the plugin's own CLI.
- **Code that runs before the review's own checks.** Claude Code loads project
  config when the session starts. A first review's worktree is created at the
  PR's head at that moment, so a push that lands between the dispatcher's
  check and the worktree's creation can run its hooks before stage 0 notices.
  Config already on the base branch, including files pulled in by `@imports`,
  always loads.
- **A memory file in an unusual letter case.** `CLAUDE.md`, `AGENTS.md` and
  the other memory files are matched by their exact names, so a PR adding
  `claude.md` is not stopped, though on macOS's case-insensitive filesystem
  Claude Code would load it as `CLAUDE.md`. Matching any case skipped every PR
  that touched an ordinary page like `docs/agents.md`; under assumption 3 the
  narrower match is the accepted trade. Config directories (`.claude/` and the
  like) and `.mcp.json` still match in any case.
- **Running tests on a trusted PR.** That is allowed, and test setup code runs
  as you.
- **Extra skills.** Skills named in the repo's `extra-skills.txt` run with the
  session's full permissions. `EXTRA_SKILLS_ALLOW` limits them to a list you
  choose.

## If your setup differs

- **Public repo, or contributors you don't know:** keep
  `REVIEW_UNTRUSTED_PRS=0` (the default), and consider running the whole
  setup in a VM or under a separate OS account with its own gh token.
- **You want a hard limit on what a session can do on GitHub:** run the
  plugin under a GitHub account or token whose permissions you have narrowed
  yourself. The plugin can't narrow them for you.
- **Shared or CI machines:** not supported. The plugin assumes one person, one
  laptop, one set of credentials.

The mechanics behind each guard are in
[How it works: Trust and PR code](how-it-works.md#trust-and-pr-code).
