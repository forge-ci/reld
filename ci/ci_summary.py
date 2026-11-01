"""Single required merge gate: fail if any other job in this run attempt did not succeed.

    python -m ci.ci_summary

Runs as the `CI summary` job (`if: always()`) on pull_request and merge_group.
It reads the run attempt's full job list from the API instead of trusting
`needs.*.result`, which reports a reusable-workflow caller as success even when
a job inside it was cancelled. Needs GITHUB_REPOSITORY, GITHUB_RUN_ID,
GITHUB_RUN_ATTEMPT and a GH_TOKEN with actions: read. Mirrors the
obs-rust/obs-studio `CI Gate` and forge-ci/soldr `CI summary` gates.
"""

from __future__ import annotations

import json
import os
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

GATE = "CI summary"
BLOCKING = frozenset({"failure", "cancelled", "timed_out", "startup_failure", "action_required"})
# Maintenance jobs, exempted deliberately by exact name. Each one is either
# skipped on pull_request or best-effort housekeeping whose failure says nothing
# about the change:
#   - Cancel superseded queue runs: cancels *other* runs; a 409 race is not a defect.
#   - Cache janitor: needs every job, so it runs after (or alongside) this gate
#     and only evicts caches on merge_group/push.
EXEMPT = frozenset({GATE, "Cancel superseded queue runs", "Cache janitor"})
ATTEMPTS = 5


def blockers(jobs: list[dict]) -> list[tuple[str, str]]:
    """(name, conclusion) of every non-exempt job whose conclusion blocks the gate."""
    return sorted(
        (job["name"], job.get("conclusion") or "")
        for job in jobs
        if job["name"] not in EXEMPT and job.get("conclusion") in BLOCKING
    )


def api(url: str) -> tuple[dict, str]:
    """GET url, retrying transient/rate-limit errors; returns (body, next-page url)."""
    for attempt in range(1, ATTEMPTS + 1):
        request = Request(
            url,
            headers={
                "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
                "Accept": "application/vnd.github+json",
            },
        )
        try:
            with urlopen(request, timeout=30) as response:
                link = response.headers.get("Link") or ""
                body = json.loads(response.read())
            nxt = ""
            for part in link.split(","):
                if 'rel="next"' in part:
                    nxt = part.split(";")[0].strip().strip("<>")
            return body, nxt
        except HTTPError as error:
            if error.code not in (403, 429, 500, 502, 503, 504) or attempt == ATTEMPTS:
                raise
            print(f"job-list call returned HTTP {error.code}; retry {attempt}/{ATTEMPTS}")
        except URLError as error:
            if attempt == ATTEMPTS:
                raise
            print(f"job-list call failed ({error.reason}); retry {attempt}/{ATTEMPTS}")
        time.sleep(min(60, 5 * 2 ** (attempt - 1)))
    raise AssertionError("unreachable")


def main() -> int:
    repo = os.environ["GITHUB_REPOSITORY"]
    run_id = os.environ["GITHUB_RUN_ID"]
    run_attempt = os.environ["GITHUB_RUN_ATTEMPT"]
    url = (
        f"https://api.github.com/repos/{repo}/actions/runs/{run_id}"
        f"/attempts/{run_attempt}/jobs?per_page=100"
    )
    jobs: list[dict] = []
    while url:
        body, url = api(url)
        jobs += body["jobs"]
    for job in sorted(jobs, key=lambda j: j["name"]):
        print(f"{job.get('conclusion') or job.get('status')!s:>16}  {job['name']}")
    blocked = blockers(jobs)
    if blocked:
        print(f"::error::{GATE}: {len(blocked)} job(s) blocked the gate:")
        for name, conclusion in blocked:
            print(f"::error::  {name}: {conclusion}")
        return 1
    print(f"{GATE}: no blocking job among {len(jobs)} in attempt {run_attempt}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
