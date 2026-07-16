"""Tests for explain-format.py — the LLM-output normaliser.

Covers the variations the LLM produces in practice (code fences, varying
indentation, missing colons, prose-only DANGER without structured fields,
HARDEN with extra prose, etc.) and verifies the normaliser brings each
to canonical shape.
"""

import importlib.util
from pathlib import Path

LIB = (
    Path(__file__).resolve().parent.parent
    / "adapters/claude-code/claude/tools/lib/explain-format.py"
)
spec = importlib.util.spec_from_file_location("explain_format", LIB)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
normalise = mod.normalise


# ---------------------------------------------------------------------------
# DANGER — structured output stays canonical
# ---------------------------------------------------------------------------


def test_clean_danger_passes_through():
    raw = "⚠ DANGER — kerne-risiko\n\n  Hvad: A\n  Hvorfor: B\n  Verificér: C\n"
    out = normalise(raw)
    assert "⚠ DANGER — kerne-risiko" in out
    assert "  Hvad: A" in out
    assert "  Hvorfor: B" in out
    assert "  Verificér: C" in out


def test_danger_with_code_fences_strips_them():
    raw = "```\n⚠ DANGER — fence-wrapped\n\n  Hvad: x\n  Hvorfor: y\n  Verificér: z\n```"
    out = normalise(raw)
    assert "```" not in out
    assert "⚠ DANGER — fence-wrapped" in out


def test_danger_with_extra_indentation_normalises():
    raw = "⚠ DANGER — for-meget-indrykning\n\n    Hvad: A\n        Hvorfor: B\n      Verificér: C\n"
    out = normalise(raw)
    # Canonical indentation is 2 spaces
    assert "  Hvad: A" in out
    assert "  Hvorfor: B" in out
    assert "  Verificér: C" in out


def test_danger_with_prose_then_fields():
    """Some LLM outputs add prose before the structured fields."""
    raw = (
        "⚠ DANGER — sammenfatning\n\n"
        "Generel forklaring der ikke matcher format-spec.\n"
        "Hvad: konkret hvad\n"
        "Hvorfor: konkret hvorfor\n"
        "Verificér: konkret verify\n"
    )
    out = normalise(raw)
    # The prose IS lost (only structured fields appear) but classification + summary preserved
    assert "⚠ DANGER — sammenfatning" in out
    assert "  Hvad: konkret hvad" in out
    assert "  Hvorfor: konkret hvorfor" in out
    assert "  Verificér: konkret verify" in out


def test_danger_field_with_multi_line_value():
    raw = (
        "⚠ DANGER — multi-line\n\n"
        "  Hvad: linje 1\n"
        "  med fortsat tekst på linje 2\n"
        "  Hvorfor: B\n"
        "  Verificér: C\n"
    )
    out = normalise(raw)
    assert "  Hvad: linje 1 med fortsat tekst på linje 2" in out


def test_danger_verificer_typo_normalised():
    """LLM sometimes drops the é in 'Verificér'."""
    raw = "⚠ DANGER — typo-test\n\n  Hvad: A\n  Hvorfor: B\n  Verificer: C\n"
    out = normalise(raw)
    assert "Verificér: C" in out


def test_danger_without_structured_fields_falls_back():
    raw = "⚠ DANGER — ren-prose\n\nDette er bare en lang forklaring uden struktur.\nFlere linjer."
    out = normalise(raw)
    assert "⚠ DANGER — ren-prose" in out
    # Falls back to raw display marker
    assert "DANGER uden strukturerede felter" in out


# ---------------------------------------------------------------------------
# HARDEN — single-line, strip extra fields
# ---------------------------------------------------------------------------


def test_clean_harden_passes_through():
    raw = "✓ HARDEN — beskytter X mod Y"
    out = normalise(raw)
    assert out == "✓ HARDEN — beskytter X mod Y"


def test_harden_with_extra_hvad_strips_it():
    """LLM sometimes adds Hvad: even though prompt says HARDEN is single-line."""
    raw = "✓ HARDEN — kort beskrivelse\n\nHvad: ekstra tekst\nHvorfor: mere"
    out = normalise(raw)
    assert out == "✓ HARDEN — kort beskrivelse"
    assert "Hvad" not in out
    assert "Hvorfor" not in out


def test_harden_with_code_fences():
    raw = "```\n✓ HARDEN — fence-test\n```"
    out = normalise(raw)
    assert out == "✓ HARDEN — fence-test"


# ---------------------------------------------------------------------------
# NEUTRAL — single-line, strip extra
# ---------------------------------------------------------------------------


def test_clean_neutral_passes_through():
    raw = "◦ NEUTRAL — refactor uden sikkerhedseffekt"
    out = normalise(raw)
    assert out == "◦ NEUTRAL — refactor uden sikkerhedseffekt"


def test_neutral_with_extra_text_strips_it():
    raw = "◦ NEUTRAL — kort\n\nHvad: dette skulle ikke være her"
    out = normalise(raw)
    assert out == "◦ NEUTRAL — kort"


# ---------------------------------------------------------------------------
# Fallback — unknown format
# ---------------------------------------------------------------------------


def test_no_classification_falls_back_with_marker():
    raw = "Bare prose, ingen klassifikation."
    out = normalise(raw)
    assert "FORMAT MISMATCH" in out
    assert "Bare prose" in out


def test_empty_input_shows_transient_marker():
    """Empty LLM response is usually a transient API issue — make it visible."""
    out_empty = normalise("")
    out_whitespace = normalise("   \n  \n")
    for out in (out_empty, out_whitespace):
        assert "tomt svar" in out
        assert "transient" in out
        assert "sync.sh diff igen" in out


# ---------------------------------------------------------------------------
# Robust to LLM variations seen in production
# ---------------------------------------------------------------------------


def test_danger_with_summary_having_em_dash():
    raw = (
        "⚠ DANGER — den primære risiko er X — afledt af Y\n\n"
        "  Hvad: A\n  Hvorfor: B\n  Verificér: C"
    )
    out = normalise(raw)
    # First em-dash is the separator; subsequent are part of summary
    assert "⚠ DANGER — den primære risiko er X — afledt af Y" in out


def test_danger_with_field_separators_using_bold_markdown():
    """Some LLM outputs wrap field names in **bold**."""
    raw = "⚠ DANGER — markdown-bold\n\n  **Hvad:** A\n  **Hvorfor:** B\n  **Verificér:** C\n"
    out = normalise(raw)
    assert "  Hvad: A" in out
    assert "  Hvorfor: B" in out
    assert "  Verificér: C" in out
