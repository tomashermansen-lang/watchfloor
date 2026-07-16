"""Tests for _configure_logging() opt-out + uvicorn.access silencing.

LCG-01: env var "1" disables dictConfig.
LCG-02: any other value applies dictConfig.
LCG-03: uvicorn.access logger is propagate=False AND level >= WARNING.
APP-05 (EC-10.1): importing dashboard.server does not import dashboard.server.app.
"""

from __future__ import annotations

import logging
import subprocess
import sys

import pytest

from dashboard.server import app as app_module

# ---------------------------------------------------------------------------
# LCG-01 — opt-out env var skips dictConfig
# ---------------------------------------------------------------------------


def test_lcg01_opt_out_skips_dictconfig(monkeypatch):
    """LCG-01 (R5, EC-5.4): DASHBOARD_LOG_CONFIG_OPT_OUT=1 → _configure_logging is no-op."""
    captured: list[dict] = []

    def _fake_dictconfig(cfg):
        captured.append(cfg)

    monkeypatch.setenv("DASHBOARD_LOG_CONFIG_OPT_OUT", "1")
    monkeypatch.setattr("dashboard.server.app.dictConfig", _fake_dictconfig)
    app_module._configure_logging()
    assert captured == [], (
        "EC-5.4: when DASHBOARD_LOG_CONFIG_OPT_OUT=1, dictConfig must NOT be called"
    )


# ---------------------------------------------------------------------------
# LCG-02 — non-"1" values still apply dictConfig
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("value", ["", "0", "true", "yes", "TRUE", "1 "])
def test_lcg02_non_one_values_apply_dictconfig(monkeypatch, value):
    """LCG-02 (R5, EC-5.4): only literal '1' triggers opt-out."""
    captured: list[dict] = []
    monkeypatch.setenv("DASHBOARD_LOG_CONFIG_OPT_OUT", value)
    monkeypatch.setattr("dashboard.server.app.dictConfig", lambda cfg: captured.append(cfg))
    app_module._configure_logging()
    assert len(captured) == 1, (
        f"EC-5.4: dictConfig must apply when value={value!r}; only literal '1' opts out"
    )


def test_lcg02_unset_applies_dictconfig(monkeypatch):
    """LCG-02 (R5): unset env var → dictConfig is called."""
    captured: list[dict] = []
    monkeypatch.delenv("DASHBOARD_LOG_CONFIG_OPT_OUT", raising=False)
    monkeypatch.setattr("dashboard.server.app.dictConfig", lambda cfg: captured.append(cfg))
    app_module._configure_logging()
    assert len(captured) == 1


# ---------------------------------------------------------------------------
# LCG-03 — uvicorn.access silenced
# ---------------------------------------------------------------------------


def test_lcg03_uvicorn_access_silenced():
    """LCG-03 (R5): after import, uvicorn.access is propagate=False AND level >= WARNING."""
    uvicorn_logger = logging.getLogger("uvicorn.access")
    assert uvicorn_logger.propagate is False, "R5: uvicorn.access logger MUST have propagate=False"
    # logging level constants: INFO=20, WARNING=30. Higher means more silent.
    assert uvicorn_logger.level >= logging.WARNING, (
        f"R5: uvicorn.access level must be >= WARNING (30), got {uvicorn_logger.level}"
    )


# ---------------------------------------------------------------------------
# APP-05 (EC-10.1) — importing dashboard.server does NOT import .app
# ---------------------------------------------------------------------------


def test_app05_no_eager_app_import_via_init():
    """APP-05 (R10, EC-10.1): `import dashboard.server` MUST NOT import .app."""
    # Use a fresh interpreter to avoid pollution from the test session.
    repo_root = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    code = (
        "import sys\n"
        f"sys.path.insert(0, {repo_root!r})\n"
        "import dashboard.server\n"
        "loaded = 'dashboard.server.app' in sys.modules\n"
        "print('LOADED' if loaded else 'NOT_LOADED')\n"
    )
    result = subprocess.run(
        [sys.executable, "-c", code], capture_output=True, text=True, check=True
    )
    assert result.stdout.strip() == "NOT_LOADED", (
        f"EC-10.1: importing dashboard.server must not import .app. stdout={result.stdout!r}"
    )
