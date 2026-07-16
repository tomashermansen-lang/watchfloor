"""Single source of truth for the length-capped safe-identifier regex.

Owns ``^[a-zA-Z0-9_-]{1,64}$`` as both a raw-string literal (``SAFE_ID_REGEX``)
and a compiled pattern (``SAFE_ID_PATTERN``), plus a thin
``validate_safe_id`` helper that raises ``ValueError`` with the offending
input quoted when the value does not match.

The cap (DN-12 of the host plan ``poc-watchfloor-autopilot-control``)
tightens the previously permissive ``^[a-zA-Z0-9_-]+$`` shape that lived
inline in ``_serve_legacy.py``. ``_serve_legacy._RE_SAFE_ID`` is now an
aliased re-export of ``SAFE_ID_REGEX`` so every consumer
(``routes/api.py``, ``tmux_session.py``, the C2-06 test row) binds the
same string object — identity equality holds via shared import, not via
CPython's string-interning heuristic.

Imports only ``re`` so this module sits at the bottom of the
``dashboard.server`` import graph and never participates in a circular
import (EC-M2).
"""

from __future__ import annotations

import re

SAFE_ID_REGEX = r"^[a-zA-Z0-9_-]{1,64}$"
SAFE_ID_PATTERN = re.compile(SAFE_ID_REGEX)


def validate_safe_id(value: str, *, field: str = "value") -> None:
    """Raise ``ValueError`` if ``value`` does not match ``SAFE_ID_PATTERN``.

    The error message quotes both ``field`` (so the caller knows which
    parameter failed) and the offending input via ``repr`` (so shell
    metacharacters render unambiguously in logs).
    """
    if SAFE_ID_PATTERN.match(value) is None:
        raise ValueError(f"{field} failed regex {SAFE_ID_REGEX}: {value!r}")
