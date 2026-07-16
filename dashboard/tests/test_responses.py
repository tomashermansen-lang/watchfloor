"""Tests for StdlibJSONResponse (C2 — T2.1..T2.7).

Covers REQUIREMENTS.md R2 (custom Response replicates stdlib json.dumps wire
bytes). The class lives in ``dashboard.server._responses``; it is the single
mechanism keeping the FastAPI port byte-equivalent to ``serve.py``.
"""

from __future__ import annotations

import json

from dashboard.server._responses import StdlibJSONResponse


def test_t2_1_list_default_separators() -> None:
    """T2.1 (R2): list payload uses stdlib defaults `, ` between elements."""
    body = StdlibJSONResponse([1, 2, 3]).body
    assert body == b"[1, 2, 3]", "ensure_ascii=True + default separators"


def test_t2_2_dict_colon_space_comma_space() -> None:
    """T2.2 (R2): dict payload uses `: ` between key/value and `, ` between pairs."""
    body = StdlibJSONResponse({"a": 1, "b": 2}).body
    assert body == b'{"a": 1, "b": 2}'


def test_t2_3_non_ascii_escapes_via_ensure_ascii_true() -> None:
    """T2.3 (R2, EC-2.1, Risk-E): em-dash becomes `\\u2014`, NOT raw UTF-8."""
    body = StdlibJSONResponse({"x": "—"}).body
    assert body == b'{"x": "\\u2014"}', "ensure_ascii MUST stay True for byte parity"


def test_t2_4_no_trailing_newline() -> None:
    """T2.4 (R2, EC-2.2): rendered body never ends with a newline."""
    body = StdlibJSONResponse({}).body
    assert isinstance(body, bytes)
    assert not body.endswith(b"\n")
    assert body == b"{}"


def test_t2_5_default_content_type_header() -> None:
    """T2.5 (R2): default Content-Type matches stdlib `_send_json`."""
    headers = StdlibJSONResponse([]).headers
    assert headers["content-type"] == "application/json; charset=utf-8"


def test_t2_6_default_cache_control_no_store() -> None:
    """T2.6 (R2): default Cache-Control is `no-store`."""
    headers = StdlibJSONResponse([]).headers
    assert headers["cache-control"] == "no-store"


def test_t2_7_caller_supplied_header_overrides_default() -> None:
    """T2.7 (R2): caller wins on header collision (no silent merge)."""
    response = StdlibJSONResponse([], headers={"cache-control": "max-age=0"})
    assert response.headers["cache-control"] == "max-age=0"


def test_t2_status_code_defaults_to_200() -> None:
    """R2: default status is 200."""
    assert StdlibJSONResponse([]).status_code == 200


def test_t2_status_code_passes_through() -> None:
    """R2: caller-supplied status code is preserved."""
    assert StdlibJSONResponse([], status_code=201).status_code == 201


def test_t2_render_returns_bytes_matching_json_dumps() -> None:
    """R2: render(content) returns json.dumps(content).encode('utf-8') verbatim."""
    payload = {"feature": "demo", "items": [1, 2, 3], "nested": {"k": "v"}}
    expected = json.dumps(payload).encode("utf-8")
    assert StdlibJSONResponse(payload).body == expected
