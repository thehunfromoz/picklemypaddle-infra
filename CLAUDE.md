# picklemypaddle-infra

Staging and production stacks, the home-server updater, shared CI workflows, runbooks, and the
guides for working with Claude. How we work: [docs/working-with-claude.md](docs/working-with-claude.md).
Where everything lives: [docs/as-built.md](docs/as-built.md). This repo is **public**: no secrets,
IP addresses or login addresses, ever.

## Checks (run before pushing)

```bash
shellcheck staging/*.sh staging/pmp-staging staging/pmp-staging-ssh production/*.sh tests/*.sh
python3 -m unittest discover -s tests -p '*_test.py'
bash tests/tailscale.test.sh
bash tests/claude-access.test.sh      # part 2 (real user and sudo) runs only in CI
```

The updater, production and backup tests (`tests/*-update.test.sh`, `tests/backup.test.sh`) need
Docker; on the Mac they run under Docker Desktop, otherwise CI runs them.

## Rules for this repo

- Any infra change updates `docs/as-built.md` and the matching runbook in the same PR.
- Changes to `staging/pmp-staging`, `staging/claude-access.sh` or `staging/install.sh` change what
  runs as root on home-server: flag them in the batch summary.
- Shared workflows (`.github/workflows/`) are called `@main` by the other repos: test a change from a
  branch ref first. Renaming a job changes its required check name.
- After merging a change under `staging/`, apply it with `ssh pmp-staging install` and check
  `ssh pmp-staging status`.
