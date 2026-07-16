"""Pydantic v2 base schema for dashboard write endpoints.

Declares `WriteRequest` plus the `FeatureId` and `PhaseName` types it
composes. Framework-agnostic (no FastAPI/Starlette imports) so Phase 2
endpoints can subclass it under any route declaration style.

The 8-value `PhaseName` literal mirrors `PHASE_ORDER` in
`adapters/claude-code/claude/tools/lib/phase-selector.sh` verbatim — the
canonical source per CLAUDE.md § Pipelines. The
test_c2_b_1b_phase_literal_matches_bash_phase_order pytest pins this
against the bash source.
"""

from __future__ import annotations

from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, StringConstraints

FeatureId = Annotated[
    str,
    StringConstraints(
        pattern=r"^[a-zA-Z0-9_-]{1,64}$",
        min_length=1,
        max_length=64,
    ),
]

PhaseName = Literal[
    "ba",
    "plan",
    "testplan",
    "review",
    "implement",
    "qa",
    "static-analysis",
    "commit",
]


class WriteRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    feature_id: FeatureId
    from_phase: PhaseName


class BufferOverflowSentinel(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: Literal["buffer_overflow"]
    bytes_dropped: int
    at: int
