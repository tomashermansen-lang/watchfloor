"""Regression guard for grinder-check.sh frontend-dir search list.

Verifies that grinder-check.sh resolves ``node`` category tools through
``$project_dir/dashboard/app/node_modules`` — the dotfiles+dashboard
monorepo's actual frontend location. Without this entry, smoke entry #2
of pipeline.yaml exits 1 because the bare ``npx <tool>`` fallback fails
when the tool is not globally installed.

Covers REQ-6 (smoke entries shall exit 0 from monorepo root) for the
runtime path that the bash test fixtures (tests/test-grinder-check.sh)
cannot exercise — those fixtures run with a stripped PATH that breaks
``import yaml`` in the parser subprocess.
"""
from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path

from conftest import REPO_ROOT


GRINDER_CHECK = REPO_ROOT / "adapters" / "claude-code" / "claude" / "tools" / "grinder-check.sh"


def _make_npx_stub(bin_dir: Path) -> None:
    """Create an npx stub that only succeeds when cwd contains node_modules.

    Proves the resolver actually used a ``cd "$frontend_dir"`` step rather
    than the bare project-root fallback.
    """
    npx = bin_dir / "npx"
    npx.write_text(
        "#!/bin/bash\n"
        '[[ -d "node_modules" ]] || exit 127\n'
        'case "$1" in\n'
        '    eslint) echo "9.0.0"; exit 0;;\n'
        '    tsc)    echo "5.4.0"; exit 0;;\n'
        '    *)      exit 127;;\n'
        "esac\n"
    )
    npx.chmod(npx.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


def test_grinder_check_resolves_node_tools_via_dashboard_app(tmp_path: Path) -> None:
    """REQ-6 — `node:` tools resolve from `<repo>/dashboard/app/node_modules/`."""
    monorepo = tmp_path / "monorepo"
    (monorepo / "dashboard" / "app" / "node_modules").mkdir(parents=True)
    (monorepo / "pipeline.yaml").write_text(
        "toolchain:\n"
        "  node: [eslint, tsc]\n"
        "  infra: [bash]\n"
    )

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _make_npx_stub(bin_dir)

    env = os.environ.copy()
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    env["GRINDER_CHECK_PROJECTS"] = f"monorepo|{monorepo}"

    result = subprocess.run(
        ["bash", str(GRINDER_CHECK)],
        capture_output=True,
        text=True,
        env=env,
    )

    assert result.returncode == 0, (
        f"grinder-check.sh exit_code={result.returncode}; "
        f"stdout={result.stdout!r}; stderr={result.stderr!r}"
    )
    assert "eslint: AVAILABLE" in result.stdout, (
        f"Expected 'eslint: AVAILABLE'; stdout={result.stdout!r}"
    )
    assert "tsc: AVAILABLE" in result.stdout, (
        f"Expected 'tsc: AVAILABLE'; stdout={result.stdout!r}"
    )
