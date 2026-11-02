# Auto queue

`.github/workflows/auto-queue.yml` (logic in `.github/scripts/auto-queue.sh`) puts eligible PRs into
the `main` merge queue so nobody has to run `gh pr merge` for each PR.

## Triggers

- `workflow_run` on the `CI` workflow completing for a `pull_request` event: checks just that PR.
- A sweep every 30 minutes over all open PRs to `main`. It picks up missed events and retries
  failures.
- `workflow_dispatch` with `dry_run` (default `true`) and an optional `pr` number.

## Eligibility (every rule must hold; each skip is logged with its reason)

| Rule | Skip decision |
|---|---|
| PR is open | `skip:state-*` |
| Not already in the queue and has no auto-merge request | `queued-already[:auto-merge-merge]` |
| Base is `main` | `skip:base-*` |
| Not a draft | `skip:draft` |
| Author is `zackees` or `github-actions[bot]`, plus logins in repo variable `AUTO_QUEUE_ACTORS` | `skip:untrusted-author-*` |
| No `do-not-merge`, `hold`, `wip`, `ci-full` or `draft` label | `skip:label-*` |
| `mergeable == MERGEABLE` (`UNKNOWN` is checked again once after 10 s) | `skip:mergeable-*` |
| Required check `CI summary` has not failed. A missing or pending check is allowed. | `skip:ci-summary-*` |

## Enqueue semantics

The workflow first calls the GraphQL `enqueuePullRequest` mutation. If GitHub rejects it (for
example, `CI summary` is "expected" but has not reported yet), it falls back to
`gh pr merge <n> --auto --merge`, which turns on auto-merge. The PR then joins the queue once its
required check passes. The queue merges with **MERGE** (merge commits), so the fallback has to use
`--merge`. A PR that is already queued, or already has auto-merge on, counts as success. The job
fails only when a real API error happens.

The token is `${{ github.token }}` with `pull-requests: write`. The workflow uses no PAT and no
secrets.

## Opting out and running by hand

- To keep a PR out of the queue, add the `do-not-merge` (or `hold`/`wip`) label. If it is already
  queued, also remove it from the queue in the PR UI.
- Dry run: `gh workflow run auto-queue.yml -f dry_run=true [-f pr=123]`. The decision table appears
  in the job summary.
- Locally: `REPO=forge-ci/reld DRY_RUN=true .github/scripts/auto-queue.sh [PR]`.

## Keep in sync

If the required check in the merge-queue ruleset is renamed from `CI summary`, or the `CI` workflow's
`name:` changes, update `REQUIRED_CHECK` in the script and `workflows:` in the workflow too.
Otherwise auto-queue stops working without any error.

**Risk:** once the queue's CI is green, an auto-queued PR merges with no human review. Use the
opt-out labels for anything that needs one.
