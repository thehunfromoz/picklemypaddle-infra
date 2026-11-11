# PickleMyPaddle workspace (Claude Code on the Mac)

This folder (`~/Projects/picklemypaddle`) holds the four repos. It is set up by
`picklemypaddle-infra/runbooks/claude-code-mac.md`; this file and `.claude/` are symlinks into
`picklemypaddle-infra/workspace/`, so changes to them go through an infra PR.

Read these first, every session, and follow them:

@picklemypaddle-infra/docs/working-with-claude.md
@picklemypaddle-infra/docs/qa-gates.md

`picklemypaddle-infra/docs/as-built.md` says where every account, server and secret lives: read it
before any infra or account work.

The essentials, in case of doubt:

- The loop is **refine → batch approval → build and merge → staging → UAT → next batch**. Nothing is
  built before Attila approves the batch summary; nothing is Done before his UAT OK.
- Merge only PRs inside the approved batch, after green checks that actually ran and a
  pr-review-toolkit review. Never tag, release, or change repo settings or rulesets.
- home-server only through `ssh pmp-staging <command>` (`ssh pmp-staging help` lists them). Never
  try to get around its limits; if something is needed that it can't do, ask Attila.
- Every acceptance criterion gets a regression test, seen failing once; update `qa-gates.md`.
- Unknown facts are written `[To confirm: …]`, never guessed.
- Each repo has its own `CLAUDE.md` with its commands.
- Never edit an agreement version that has been sent (even to a staging test club): add a new one.
- Never put a drive-time starting point, home suburb or address anywhere (code, copy, comments,
  commits); describe the area only.
- Practical: macOS has no `timeout`; BSD `sed -i` needs a suffix (use python for edits); don't run
  staging commands in parallel; `ssh pmp-staging status` still lists old known-bad builds after
  earlier failures (read the live commit, not that list).
