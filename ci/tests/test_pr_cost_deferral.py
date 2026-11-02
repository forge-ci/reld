"""Expensive lanes must not run on pull_request; the PR/merge queue is Linux-only (CI summary)."""

from pathlib import Path

import re

import pytest

WORKFLOWS = Path(__file__).parents[2] / ".github" / "workflows"
DEFERRED = (
    "linker-artifacts.yml",
    "linker-modes.yml",
    "linux-linker-competition.yml",
    "sanitizers.yml",
    "stress.yml",
    "cross-ship.yml",
)


def triggers(name: str) -> str:
    text = (WORKFLOWS / name).read_text(encoding="utf-8")
    return re.search(r"^on:\n((?:[ #].*\n|\n)*)", text, re.M).group(1)


@pytest.mark.parametrize("name", DEFERRED)
def test_deferred_lane_skips_pull_request_but_stays_reachable(name: str) -> None:
    block = triggers(name)
    top = re.findall(r"^  ([a-z_]+):", block, re.M)
    assert "pull_request" not in top
    assert "merge_group" not in top
    assert "workflow_dispatch" in top
    assert "push:\n    branches: [main]" in block
