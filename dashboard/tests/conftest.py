"""Shared pytest fixtures for FastAPI app-skeleton tests (T0.1).

The dashboard/ project root is added to sys.path so `dashboard.server.app`
imports resolve in test mode without requiring `pip install -e .` (which
the sandbox network policy blocks). This mirrors what an editable install
would do at runtime.
"""

from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

# Make `dashboard.server.app` importable as `import dashboard.server.app`.
# REPO_ROOT (the parent of `dashboard/`) is added so `dashboard` resolves
# as a namespace package; in production this happens via the editable
# install + setuptools.package-dir mapping declared in pyproject.toml.
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))
