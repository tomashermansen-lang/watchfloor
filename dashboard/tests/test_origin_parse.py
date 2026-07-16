"""Pure-Python unit tests for `origin_check` helpers (TESTPLAN § C1.A/B/C/E/H).

Fast layer (no uvicorn): parse, extract, classify, immutability, and
audit-path identity with csrf.py.
"""

from __future__ import annotations

import os
import subprocess
import sys
import textwrap
from pathlib import Path

from dashboard.server.middleware.origin_check import (
    _ALLOWED_ORIGINS,
    _ALLOW_LOOPBACK_DEFAULT,
    _AUDIT_PATH,
    _DEFAULT_ORIGINS,
    _classify,
    _extract_origin,
    _is_loopback_origin,
    _parse_allowlist,
)

# controls-06 #9 — DASHBOARD_ALLOWED_ORIGINS unset means
# `_DEFAULT_ORIGINS` is empty AND `_ALLOW_LOOPBACK_DEFAULT` is True,
# so the runtime accepts any loopback origin (`http(s)://127.0.0.1`
# or `http(s)://localhost`, any port) without enumeration. Hardcoding
# a closed set excluded the operator's other local projects
# (OIH 8100/5174, Eulex 8200/5173, etc.) for no security gain — the
# server binds 127.0.0.1 at the kernel level (CLAUDE.md `## Security
# Rules`) so only this machine's browser can reach the dashboard.
# Operators who want a tighter posture still override via the
# env var; explicit allowlist disables the loopback default.
_DEFAULT_EXPECTED = frozenset()


# ── C1.A — allowlist parse ─────────────────────────────────────────────


def test_c1_a_1_none_returns_default() -> None:
    assert _parse_allowlist(None) == _DEFAULT_EXPECTED


def test_c1_a_2_empty_string_returns_default() -> None:
    assert _parse_allowlist("") == _DEFAULT_EXPECTED


def test_c1_a_3_whitespace_only_returns_default() -> None:
    assert _parse_allowlist("   ") == _DEFAULT_EXPECTED


def test_c1_a_4_single_override_replaces_default() -> None:
    assert _parse_allowlist("http://override.example") == frozenset({"http://override.example"})


def test_c1_a_5_two_element_split() -> None:
    assert _parse_allowlist("http://a,http://b") == frozenset({"http://a", "http://b"})


def test_c1_a_6_empty_elements_discarded() -> None:
    assert _parse_allowlist("http://a,,http://b,") == frozenset({"http://a", "http://b"})


def test_c1_a_7_per_element_strip() -> None:
    assert _parse_allowlist("  http://a  , http://b ") == frozenset({"http://a", "http://b"})


def test_c1_a_8_scheme_only_kept_literally() -> None:
    assert _parse_allowlist("http://") == frozenset({"http://"})


def test_c1_a_9_wildcards_not_expanded() -> None:
    assert _parse_allowlist("*.example.com") == frozenset({"*.example.com"})


def test_c1_a_10_case_preserved_verbatim() -> None:
    assert _parse_allowlist("HTTP://X.EXAMPLE") == frozenset({"HTTP://X.EXAMPLE"})


def test_c1_a_11_return_type_is_frozenset() -> None:
    assert isinstance(_parse_allowlist("http://a"), frozenset)


def test_default_constant_matches_expected() -> None:
    assert _DEFAULT_ORIGINS == _DEFAULT_EXPECTED


def test_allow_loopback_default_is_true_when_env_unset() -> None:
    # controls-06 #9: tests run without DASHBOARD_ALLOWED_ORIGINS set
    # (conftest doesn't export it), so module-level
    # _ALLOW_LOOPBACK_DEFAULT must be True. Operators who set the env
    # var flip this to False; that branch is covered by the explicit
    # override test pair below (the env-var-set path bypasses
    # loopback entirely).
    assert _ALLOW_LOOPBACK_DEFAULT is True


# ── C1.A2 — loopback predicate (controls-06 #9) ────────────────────────


def test_is_loopback_origin_accepts_127_any_port() -> None:
    assert _is_loopback_origin("http://127.0.0.1") is True
    assert _is_loopback_origin("http://127.0.0.1:1") is True
    assert _is_loopback_origin("http://127.0.0.1:65535") is True


def test_is_loopback_origin_accepts_localhost_any_port() -> None:
    assert _is_loopback_origin("http://localhost") is True
    assert _is_loopback_origin("http://localhost:5175") is True
    assert _is_loopback_origin("https://localhost:8443") is True


def test_is_loopback_origin_rejects_path() -> None:
    # A crafted Origin like `http://localhost:5175/../evil` must not
    # bypass the predicate. fullmatch anchors both ends.
    assert _is_loopback_origin("http://localhost:5175/") is False
    assert _is_loopback_origin("http://localhost:5175/../evil") is False


def test_is_loopback_origin_rejects_non_loopback_host() -> None:
    assert _is_loopback_origin("http://example.com") is False
    assert _is_loopback_origin("http://192.168.1.10:5175") is False
    assert _is_loopback_origin("http://127.0.0.2:5175") is False  # not loopback


def test_is_loopback_origin_rejects_userinfo_and_query() -> None:
    assert _is_loopback_origin("http://user@localhost:5175") is False
    assert _is_loopback_origin("http://localhost:5175?x=1") is False
    assert _is_loopback_origin("http://localhost:5175#frag") is False


def test_is_loopback_origin_rejects_non_http_scheme() -> None:
    assert _is_loopback_origin("ws://localhost:5175") is False
    assert _is_loopback_origin("file://localhost") is False


# ── C1.B — origin header extraction ────────────────────────────────────


def test_c1_b_1_empty_headers_returns_none() -> None:
    assert _extract_origin([]) is None


def test_c1_b_2_origin_present() -> None:
    assert _extract_origin([(b"origin", b"http://x.example")]) == "http://x.example"


def test_c1_b_3_order_independent() -> None:
    assert (
        _extract_origin([(b"host", b"x"), (b"origin", b"http://x.example")]) == "http://x.example"
    )


def test_c1_b_4_first_origin_wins() -> None:
    assert _extract_origin([(b"origin", b"http://a"), (b"origin", b"http://b")]) == "http://a"


def test_c1_b_5_empty_value_returns_empty_string() -> None:
    assert _extract_origin([(b"origin", b"")]) == ""


def test_c1_b_6_latin1_bytes_decoded_without_error() -> None:
    assert _extract_origin([(b"origin", b"\xe9\xe9\xe9")]) == "ééé"


def test_c1_b_7_ascii_lowercase_canonical() -> None:
    assert _extract_origin([(b"origin", b"x")]) == "x"


# ── C1.C — origin classification ───────────────────────────────────────


def test_c1_c_1_none_is_missing() -> None:
    assert _classify(None) == "missing"


def test_c1_c_2_empty_string_is_missing() -> None:
    assert _classify("") == "missing"


def test_c1_c_3_default_classify_accepts_8787() -> None:
    # controls-06 #9: classify is the contract; _ALLOWED_ORIGINS is
    # now empty by default and the loopback predicate handles
    # acceptance. Specific-port membership in _ALLOWED_ORIGINS is no
    # longer the invariant — _classify is.
    assert _classify("http://127.0.0.1:8787") is None


def test_c1_c_3b_default_classify_accepts_5175() -> None:
    # T9 from /team-qa Round 1: AS-2 unit-layer mirror of AS-1.
    # Re-anchored on _classify rather than set membership
    # (controls-06 #9).
    assert _classify("http://127.0.0.1:5175") is None


def test_c1_c_3c_default_classify_accepts_localhost_5175() -> None:
    # controls-06 #9: browser sends whichever hostname the operator
    # typed; localhost is as valid as 127.0.0.1 for the loopback
    # interface and must not 403.
    assert _classify("http://localhost:5175") is None


def test_c1_c_3d_default_classify_accepts_localhost_8787() -> None:
    assert _classify("http://localhost:8787") is None


def test_c1_c_3e_default_classify_accepts_other_local_project_ports() -> None:
    # controls-06 #9: the operator's other local projects (OIH
    # 8100/5174, Eulex 8200/5173, etc.) must not be rejected just
    # because the dashboard wasn't told about their ports.
    assert _classify("http://127.0.0.1:8100") is None  # OIH backend
    assert _classify("http://127.0.0.1:5174") is None  # OIH frontend
    assert _classify("http://localhost:8200") is None  # Eulex backend
    assert _classify("http://localhost:5173") is None  # Eulex frontend


def test_c1_c_3f_default_classify_rejects_off_machine_origin() -> None:
    # Default loopback-permissive mode must NOT accept anything
    # that isn't the loopback interface.
    assert _classify("http://192.168.1.10:5175") == "disallowed"
    assert _classify("http://attacker.example") == "disallowed"


def test_c1_c_4_disallowed_origin() -> None:
    assert _classify("https://evil.example") == "disallowed"


def test_c1_c_4b_nul_byte_in_origin_disallowed() -> None:
    # S4 from /team-qa Round 1: a NUL-injected Origin like
    # "http://127.0.0.1:8787\x00.evil" must classify as disallowed.
    # Pins behavior against a future change that normalizes Origin
    # before byte-equality compare.
    assert _classify("http://127.0.0.1:8787\x00.evil") == "disallowed"


def test_c1_c_5_trailing_slash_disallowed() -> None:
    assert _classify("http://127.0.0.1:8787/") == "disallowed"


def test_c1_c_6_uppercase_scheme_disallowed() -> None:
    assert _classify("HTTP://127.0.0.1:8787") == "disallowed"


# ── C1.E — allowlist immutability after import ─────────────────────────


def test_c1_e_1_env_var_mutation_after_import_does_not_change_allowlist() -> None:
    code = textwrap.dedent(
        """
        from dashboard.server.middleware import origin_check
        orig = set(origin_check._ALLOWED_ORIGINS)
        import os
        os.environ['DASHBOARD_ALLOWED_ORIGINS'] = 'http://x.mutated'
        assert set(origin_check._ALLOWED_ORIGINS) == orig
        print('ok')
        """
    )
    repo_root = Path(__file__).resolve().parents[2]
    env = os.environ.copy()
    env["PYTHONPATH"] = str(repo_root)
    env.pop("DASHBOARD_ALLOWED_ORIGINS", None)
    out = subprocess.check_output([sys.executable, "-c", code], env=env, text=True)
    assert out.strip() == "ok"


# ── C1.F — explicit env override locks down (controls-06 #9) ──────────


def test_c1_f_1_explicit_env_disables_loopback_default() -> None:
    """Operator-supplied DASHBOARD_ALLOWED_ORIGINS replaces the
    loopback-permissive default entirely. A loopback origin NOT in
    the explicit list must be rejected so an operator can tighten
    the posture (e.g. lock to a specific reverse-proxy hostname).
    """
    code = textwrap.dedent(
        """
        import os
        os.environ['DASHBOARD_ALLOWED_ORIGINS'] = 'http://proxy.example'
        from dashboard.server.middleware import origin_check
        # explicit override set: loopback default OFF, list is exact
        assert origin_check._ALLOW_LOOPBACK_DEFAULT is False
        assert origin_check._classify('http://proxy.example') is None
        assert origin_check._classify('http://localhost:5175') == 'disallowed'
        assert origin_check._classify('http://127.0.0.1:8787') == 'disallowed'
        print('ok')
        """
    )
    repo_root = Path(__file__).resolve().parents[2]
    env = os.environ.copy()
    env["PYTHONPATH"] = str(repo_root)
    out = subprocess.check_output([sys.executable, "-c", code], env=env, text=True)
    assert out.strip() == "ok"


def test_c1_f_2_unset_env_keeps_loopback_default() -> None:
    """Round-trip the opposite path: env unset (the production
    default for `start-system dashboard`) leaves
    _ALLOW_LOOPBACK_DEFAULT True and accepts any loopback origin
    without enumeration.
    """
    code = textwrap.dedent(
        """
        from dashboard.server.middleware import origin_check
        assert origin_check._ALLOW_LOOPBACK_DEFAULT is True
        assert origin_check._classify('http://localhost:5175') is None
        assert origin_check._classify('http://localhost:8100') is None
        assert origin_check._classify('http://192.168.1.10:5175') == 'disallowed'
        print('ok')
        """
    )
    repo_root = Path(__file__).resolve().parents[2]
    env = os.environ.copy()
    env["PYTHONPATH"] = str(repo_root)
    env.pop("DASHBOARD_ALLOWED_ORIGINS", None)
    out = subprocess.check_output([sys.executable, "-c", code], env=env, text=True)
    assert out.strip() == "ok"


# ── C1.H — _AUDIT_PATH shared identity with csrf.py (EC-14) ────────────


def test_c1_h_1_audit_path_is_csrf_path() -> None:
    from dashboard.server.middleware.csrf import _AUDIT_PATH as csrf_path

    assert _AUDIT_PATH is csrf_path
