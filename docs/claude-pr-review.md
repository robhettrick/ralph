# Claude PR review: noise gate

Adversarial PR review by Claude, with the noise removed before anyone reads it. This kit replaces the ad-hoc "run a review prompt, paste the result" flow with one prompt and one deterministic filter, usable both locally and from GitHub Actions.

## The idea in one paragraph

The prompt used to do two jobs: find problems and decide which ones were worth saying. Models are good at the first and unreliable at the second, which is where the trailing-whitespace comments, praise sections and duplicated summaries came from. So the jobs are split. Claude's only output is a structured `findings.json`, with a severity, a confidence score and a record of how each finding was verified against the working tree. A small Python script then applies fixed rules (severity at least high, verified, confidence at least 80, not in a banned category, one finding per line, at most ten inline comments) and posts a single GitHub review, plus one sticky status line per PR (edited in place each run) saying what was considered and what was posted, so a clean pass is visibly a checked pass rather than silence. Everything Claude found, including what was dropped, is kept as a workflow artefact so the team can audit the filter and tune it.

## Files

| Path | Purpose |
|---|---|
| `.github/claude/pr-review-prompt.md` | The review brief: scope, severity definitions, the never-report list, mandatory verification, JSON schema |
| `.github/claude/filter_findings.py` | The gate. Pure Python, no model. `--dry-run` prints its decisions |
| `.github/claude/post_review.sh` | Posts one review via `gh api`; dismisses stale blocking reviews from earlier runs; falls back to body-only if GitHub rejects an inline anchor |
| `.github/workflows/claude-pr-review.yml` | Runs on `opened`, `ready_for_review`, `synchronize` for non-draft PRs from the same repo. Stage A Claude, stage B filter, stage C post, artefact upload |
| `scripts/pr-review-local.sh` | Same pipeline from a laptop: `scripts/pr-review-local.sh main` to preview, `--post <pr>` to submit |
| `.claude/commands/pr-review.md` | `/pr-review` inside Claude Code for an interactive run with the same brief |

## Where it lives: the branch model

`main` in `sam-build` is deliberately light. It is the template a fresh build is cut from (runbook, guardrails, specs, this kit); each build lands on its own branch (`sam-build-v2` and successors) because the team expects to build several times and does not want to clear `main` out each time. The kit therefore lives on `main` so every new build inherits it, and is merged forward into builds already in flight (`git merge origin/main` on the build branch).

The workflow does not depend on the base branch: `pull_request` fires for a PR into any branch, and the files it needs are on the PR head. It discovers npm trees from `package.json` files (root and one level down), so a PR into a clean `main` gets a static review with no tests, and a PR into a build branch gets the full run with tests.

Protection (decided 22 Aug 2026, ruleset `21232728` active since 23 Aug): one ruleset on `main` only; PR required, one approval (authors cannot approve their own, and no bypass actors, so this binds Rob too), stale approvals dismissed on new pushes, the `review` check required, no force-push or deletion, because template changes affect every future build. Build branches are deliberately unprotected so ralph and the build pairs are not slowed; there the review runs on PRs by convention, backed by the PR template checklist. If a slip through a direct push ever warrants it, add a pattern ruleset (`sam-build-*`) in evaluate mode first.

## Install

1. Land the kit on `main` (PR #7), then merge `main` into each live build branch. Only the toolchain step needs adjusting if a repo is not Node.
2. Authentication: the workflow uses `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token` on Rob's account, stored as a repo secret). Every CI run draws on that account's weekly limit; if it becomes a constraint, swap the one line in the workflow for `anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}` on a dedicated Console workspace. Either way GitHub access is the job's own `GITHUB_TOKEN`, scoped to the repo and `pull-requests: write`, which removes the personal-token scope concern raised in Session 11.
3. The `main` ruleset requires the `review` check. The workflow requests changes only for `blocking` findings, so it blocks merge on exactly those and stays out of the way otherwise.
4. Run it once on an old PR with `workflow_dispatch` (available once the workflow is on `main`) and read the artefact's `summary.md` to see what it would have posted and what it dropped.

## Gotchas met on the way in

- A PR that GitHub marks `CONFLICTING` gets no `pull_request` runs at all, silently: there is no merge commit to run against. Rebase first, then look for the check.
- Permission rules for file writes are spelled `Edit(path)`; one Edit rule authorises both the Edit and Write tools. The Edit *tool* cannot create a file, so the pipeline pre-creates a placeholder `findings.json`, and the filter fails the check if that placeholder is still there after Claude's step.
- In zsh, a trailing `# comment` on a command line is passed as arguments; keep comments off command lines when pasting.
- macOS numbers repeated downloads (`file (1).yml`); `cp ~/Downloads/file.yml` takes the oldest. Use `ls -t ~/Downloads/file* | head -1`.

## Tuning

All knobs are in the `env:` block of the workflow, not in the prompt:

- `MIN_SEVERITY` (default `high`). Drop to `medium` on a repo where you want more, never below.
- `MIN_CONFIDENCE` (default 80).
- `MAX_INLINE_COMMENTS` (default 10). Anything past the cap is listed as one line each in the review body.

The banned-title patterns and suppressed categories at the top of `filter_findings.py` are the place to add a new class of noise when one shows up. Add it there first; change the prompt second.

## Security notes

Claude runs with read-only tools plus a single `Edit` target (`.claude-review/findings.json`) and the discovered test and lint commands, with `WebFetch` and `WebSearch` disallowed so nothing can leave the runner. It has no `gh` write access and cannot post, so the most a prompt injection in a PR description can do is shape a finding, which then has to survive the filter and still be read by a human. The workflow skips PRs from forks and from bots, and the brief tells the model to treat PR text as data. Keep the `--allowedTools` list tight when you extend it.

## Measuring whether it is working

Each run's artefact has `summary.md` with counts of raw, posted and filtered findings and the reason for each drop. Two numbers worth tracking per week in `METRICS.md`: how many posted findings a human acted on (precision) and how many bugs reached `main` that a review should have caught (recall). If precision is high and comments are still ignored, lower the cap; if recall is poor, look at what the filter dropped before loosening the prompt.
