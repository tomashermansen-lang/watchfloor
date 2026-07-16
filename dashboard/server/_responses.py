"""Wire-byte-equivalent JSON response class for the FastAPI port (R2 / C2).

``StdlibJSONResponse`` reproduces the exact body bytes emitted by
``dashboard/serve.py:_send_json`` (lines 299-307), so the byte-equivalence
harness (``dashboard/tests/test_response_compat.py``) can diff fixture vs.
live response without spurious mismatches against FastAPI's default
``JSONResponse`` (which uses compact separators ``,`` / ``:``).

``ensure_ascii`` MUST remain ``True`` for stdlib byte-equivalence — non-ASCII
payloads encode as ``\\uXXXX`` escapes; flipping it to ``False`` breaks every
non-ASCII fixture diff (Risk-E in PLAN.md).
"""

from __future__ import annotations

import json
from typing import Any

from starlette.responses import Response


class StdlibJSONResponse(Response):
    """Byte-equivalent JSON response matching stdlib ``json.dumps`` defaults."""

    media_type = "application/json; charset=utf-8"

    def __init__(
        self,
        content: Any,
        status_code: int = 200,
        headers: dict[str, str] | None = None,
    ) -> None:
        merged_headers = {"cache-control": "no-store"}
        if headers:
            merged_headers.update({k.lower(): v for k, v in headers.items()})
        super().__init__(content=content, status_code=status_code, headers=merged_headers)

    def render(self, content: Any) -> bytes:
        return json.dumps(content).encode("utf-8")
