# AGENTS.md

## What this repo is
- This is a Zensical-powered documentation site. The real site entry is `docs/index.md`; `README.md` only points there.
- Main docs live under `docs/`; slides live under `slides/`; lab reference implementations live under `build/`.

## Build / verify
- Sync Python deps with `uv sync`.
- Build the website with `uv run zensical build -f zensical.toml`.
- Build slides with `uv run mkslides build slides/ -d site-slides`.
- The CI workflow also expects `PYTHONPATH=.` when running Zensical.
- CI builds on `push`, `pull_request`, and `workflow_dispatch`; deployment happens only on `main` pushes.

## Repo quirks
- `zensical.toml` is the source of truth for nav, theme, and plugin setup.
- `mkslides.yml` controls the slide build.
- `site/` and `site-slides/` are generated artifacts; do not hand-edit them.
- `site-slides/index.html` is moved into `docs/slides/index.md` in CI, so slide output is part of the docs tree.
- `MKDOCS_GIT_COMMITTERS_APIKEY` is wired to `GITHUB_TOKEN` in CI for the git committers/revision-date plugins.

## Editing guidance
- Prefer changing source markdown, config, or scripts rather than generated output.
- Keep docs changes small and localized; avoid rewriting unrelated sections.
- When adjusting lab docs, preserve the existing tab/admonition structure unless you have a clear reason to change it.

## Git workflow
- Before sending changes upstream, first check whether the remote branch has moved.
- Prefer ordinary additive commits; do not rewrite published history.
- Avoid forceful overwrite or hard-reset style operations.
