#!/usr/bin/env python3
"""Post-process raw LLM output into a canonical structured format.

Inputs raw LLM text on stdin. Outputs the same content normalised so:

  ⚠ DANGER — <summary>

    Hvad: <text>
    Hvorfor: <text>
    Verificér: <text>

(or single-line ✓ HARDEN / ◦ NEUTRAL).

LLM compliance with the prompt's strict format is ~80%. This normaliser
brings it to 100% — extracts classification + summary + fields by regex
(tolerant to extra whitespace, missing colons, code fences) and re-emits
in the canonical shape. Fallback for unparseable input: raw output with
a "(format mismatch)" prefix so the user notices.

Stdin: raw LLM text
Stdout: normalised text
"""

import re
import sys

CLASSIFICATION_RE = re.compile(
    r"^[\s>`*]*([⚠✓◦])\s*"
    r"(DANGER|HARDEN|NEUTRAL)"
    r"\s*[—–\-]\s*"
    r"(.+?)\s*$",
    re.MULTILINE,
)

# Tolerant field extractor: accepts "Hvad:", "Hvad :", "**Hvad**:",
# "**Hvad:** value", varying leading whitespace. Captures up to the next
# field marker or end-of-input.
FIELD_RE = re.compile(
    r"^\s*(?:[*_`]*)\s*(?P<name>Hvad|Hvorfor|Verific[ée]r)\s*[*_`]*\s*:\s*"
    r"[*_`]*\s*"  # also consume markdown markers between ":" and value
    r"(?P<value>.*?)"
    r"(?=\n\s*(?:[*_`]*)\s*(?:Hvad|Hvorfor|Verific[ée]r)\s*[*_`]*\s*:|\Z)",
    re.MULTILINE | re.DOTALL,
)


def strip_fences(text: str) -> str:
    """Remove markdown code-fence wrappers if the LLM ignored the no-fence rule."""
    text = re.sub(r"^```\w*\s*\n", "", text)
    text = re.sub(r"\n```\s*$", "", text)
    return text.strip()


def collapse_whitespace(text: str) -> str:
    """Flatten multi-line field values into a single line."""
    return " ".join(text.split())


def normalise(raw: str) -> str:
    raw = strip_fences(raw)
    if not raw:
        # Empty LLM response — common transient cause is API rate-limit /
        # network blip. Emit explicit marker so user notices instead of
        # seeing a silent gap under "LLM:".
        return (
            "? LLM returnerede tomt svar — sandsynligvis transient "
            "(rate limit, netværk). Kør sync.sh diff igen."
        )

    m = CLASSIFICATION_RE.search(raw)
    if not m:
        # Couldn't find any classification symbol — bubble up with a marker
        # so the user knows the format is off and reads carefully.
        lines = ["? FORMAT MISMATCH — raw LLM output (læs forsigtigt):"]
        for line in raw.splitlines():
            lines.append(f"  {line}")
        return "\n".join(lines)

    classification = m.group(2)
    summary = collapse_whitespace(m.group(3))

    if classification == "HARDEN":
        return f"✓ HARDEN — {summary}"
    if classification == "NEUTRAL":
        return f"◦ NEUTRAL — {summary}"

    # DANGER — extract structured fields
    fields = {}
    for fm in FIELD_RE.finditer(raw):
        name = fm.group("name").replace("Verificer", "Verificér")
        # Normalise field-name typo
        name = "Verificér" if name.startswith("Verific") else name
        value = collapse_whitespace(fm.group("value"))
        # Strip trailing markdown markers (**, __, ``) the LLM may add
        value = re.sub(r"[\s*_`]+$", "", value)
        if value and name not in fields:
            fields[name] = value

    out = [f"⚠ DANGER — {summary}", ""]
    if "Hvad" in fields:
        out.append(f"  Hvad: {fields['Hvad']}")
    if "Hvorfor" in fields:
        out.append(f"  Hvorfor: {fields['Hvorfor']}")
    if "Verificér" in fields:
        out.append(f"  Verificér: {fields['Verificér']}")

    if len(out) == 2:
        # Classified DANGER but no structured fields parseable. Fall back to
        # showing the raw text after the summary line so user has SOMETHING.
        out.append("  (DANGER uden strukturerede felter — raw:)")
        for line in raw.splitlines()[1:]:  # skip first line which is the header
            stripped = line.strip()
            if stripped:
                out.append(f"    {stripped}")

    return "\n".join(out)


def main():
    raw = sys.stdin.read()
    print(normalise(raw))


if __name__ == "__main__":
    main()
