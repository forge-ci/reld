#!/usr/bin/env bash
# Auto-queue: enqueue eligible PRs into the `main` merge queue.
# Used by .github/workflows/auto-queue.yml; runnable locally with `gh` auth:
#   REPO=forge-ci/reld DRY_RUN=true .github/scripts/auto-queue.sh [PR]
# Env: REPO (owner/name), DRY_RUN (true|false, default true), PR (optional number),
#      AUTO_QUEUE_ACTORS (optional extra trusted logins, comma/space separated).
# Rules are documented in docs/auto-queue.md.
# shellcheck disable=SC2016  # literal $vars in GraphQL/markdown strings are intentional
set -euo pipefail

REPO="${REPO:?REPO=owner/name required}"
DRY_RUN="${DRY_RUN:-true}"
PR="${PR:-${1:-}}"
REQUIRED_CHECK="CI summary"
BASE="main"
TRUSTED="zackees github-actions[bot] github-actions app/github-actions ${AUTO_QUEUE_ACTORS:-}"
TRUSTED="${TRUSTED//,/ }"
OPT_OUT_LABELS="do-not-merge hold wip ci-full draft"
OWNER="${REPO%%/*}"; NAME="${REPO##*/}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

PR_FIELDS='
  id number state isDraft baseRefName mergeable isInMergeQueue headRefOid
  autoMergeRequest { mergeMethod }
  author { login }
  labels(first: 50) { nodes { name } }
  commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) {
    nodes {
      __typename
      ... on CheckRun { name conclusion status }
      ... on StatusContext { context state }
    } } } } } }'

fetch_one() {
  gh api graphql -F owner="$OWNER" -F name="$NAME" -F n="$1" -f query="
    query(\$owner:String!,\$name:String!,\$n:Int!){ repository(owner:\$owner,name:\$name){
      pullRequest(number:\$n){ $PR_FIELDS } } }" --jq '.data.repository.pullRequest'
}

fetch_all() {
  gh api graphql --paginate -F owner="$OWNER" -F name="$NAME" -f query="
    query(\$owner:String!,\$name:String!,\$endCursor:String){ repository(owner:\$owner,name:\$name){
      pullRequests(states: OPEN, baseRefName: \"$BASE\", first: 50, after: \$endCursor){
        nodes { $PR_FIELDS } pageInfo { hasNextPage endCursor } } } }" \
    --jq '.data.repository.pullRequests.nodes[]'
}

# decide <pr-json> -> prints "eligible" or "queued-already" or "skip:<reason>"
decide() {
  jq -r --arg base "$BASE" --arg check "$REQUIRED_CHECK" \
        --arg trusted "$TRUSTED" --arg optout "$OPT_OUT_LABELS" '
    ($trusted | split(" ") | map(select(. != ""))) as $t
    | ($optout | split(" ")) as $o
    | ([.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]?
        | select((.name // .context) == $check)
        | (.conclusion // .state // .status // "PENDING") | ascii_upcase]) as $ci
    | ([.labels.nodes[].name | ascii_downcase] | map(select(. as $l | ($o | index($l)) != null))) as $bad
    | if .state != "OPEN" then "skip:state-\(.state | ascii_downcase)"
      elif .isInMergeQueue then "queued-already"
      elif .autoMergeRequest != null then "queued-already:auto-merge-\(.autoMergeRequest.mergeMethod | ascii_downcase)"
      elif .baseRefName != $base then "skip:base-\(.baseRefName)"
      elif .isDraft then "skip:draft"
      elif (.author.login as $a | $t | index($a)) == null then "skip:untrusted-author-\(.author.login)"
      elif ($bad | length) > 0 then "skip:label-\($bad | join(","))"
      elif .mergeable != "MERGEABLE" then "skip:mergeable-\(.mergeable | ascii_downcase)"
      elif ($ci | any(. == "FAILURE" or . == "CANCELLED" or . == "TIMED_OUT" or . == "ERROR" or . == "ACTION_REQUIRED" or . == "STARTUP_FAILURE"))
        then "skip:ci-summary-\($ci | map(ascii_downcase) | join(","))"
      else "eligible" end' <<<"$1"
}

enqueue() { # <node-id> <number>  -> 0 on success / already-queued
  local id="$1" n="$2" out
  if out=$(gh api graphql -f id="$id" -f query='mutation($id:ID!){
        enqueuePullRequest(input:{pullRequestId:$id}){ mergeQueueEntry { position } } }' 2>&1); then
    echo "  graphql enqueue ok: $out"; return 0
  fi
  echo "  graphql enqueue rejected: $out"
  if grep -qiE 'already (in|queued|added)' <<<"$out"; then return 0; fi
  if out=$(gh pr merge "$n" --repo "$REPO" --auto --merge 2>&1); then
    echo "  gh pr merge --auto --merge ok: $out"; return 0
  fi
  echo "  gh pr merge fallback failed: $out"
  grep -qiE 'already (in|queued|added)|merge queue' <<<"$out"
}

if [[ -n "$PR" ]]; then prs=$(fetch_one "$PR"); else prs=$(fetch_all); fi

printf '## Auto-queue (%s, dry_run=%s)\n\n| PR | Author | Decision |\n|---|---|---|\n' "$REPO" "$DRY_RUN" >>"$SUMMARY"
errors=0
while IFS= read -r pr; do
  [[ -z "$pr" ]] && continue
  n=$(jq -r .number <<<"$pr"); who=$(jq -r .author.login <<<"$pr")
  d=$(decide "$pr")
  if [[ "$d" == "skip:mergeable-unknown" ]]; then
    sleep 10; pr=$(fetch_one "$n"); d=$(decide "$pr")
  fi
  if [[ "$d" == "eligible" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then d="would-enqueue"
    elif enqueue "$(jq -r .id <<<"$pr")" "$n"; then d="enqueued"
    else d="error:enqueue-failed"; errors=$((errors+1)); fi
  fi
  printf 'PR #%s (%s): %s\n' "$n" "$who" "$d"
  printf '| #%s | %s | `%s` |\n' "$n" "$who" "$d" >>"$SUMMARY"
done < <(jq -c 'select(. != null)' <<<"$prs")

exit $(( errors > 0 ))
