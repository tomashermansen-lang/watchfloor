"""Cross-validation: author ↔ contract ↔ executor agree by value (§7).

The real failure mode of the integration gate is the two ends DRIFTING —
/plan-project authors a gate in one shape, the orchestrator expects another, and
you get green theater (cf. the /qa "every TESTPLAN scenario has a test"
silent-pass loop). This test defends the seam the same way the Python↔TypeScript
_REASON_TABLE boundary is defended: one canonical field set asserted against all
three artifacts —

  - the CONTRACT   : core/schema/execution-plan.schema.json (the integration
                     check kind + gate_remediation $def)
  - the EXECUTOR   : claude-session-lib.sh evaluate_phase_integration_checks
                     (the bash/Python probe that READS the gate)
  - the AUTHOR     : skills/integration-gate-authoring + integration-remediation
                     (what /plan-project is told to WRITE)

If any artifact renames a field or changes an enum value, this test fails.
"""
from __future__ import annotations

import json

from conftest import CLAUDE_SCHEMA_DIR, REPO_ROOT

# ── The canonical integration-gate contract (single source for this test) ──
KIND_VALUE = "integration"
CHECK_FIELDS = ("trigger", "remediation", "command")
REMEDIATION_FIELDS = ("agent", "max_iterations", "on_unfixable")
AGENT_VALUE = "lead-developer"
ON_UNFIXABLE_VALUE = "escalate"

LIB = (
    REPO_ROOT
    / "adapters/claude-code/claude/tools/lib/claude-session-lib.sh"
)
AUTHOR_SKILL = (
    REPO_ROOT
    / "adapters/claude-code/claude/skills/integration-gate-authoring/SKILL.md"
)
PRODUCER_CONVENTIONS = (
    REPO_ROOT
    / "adapters/claude-code/claude/skills/plan-producer-conventions/SKILL.md"
)
REMEDIATION_SKILL = (
    REPO_ROOT
    / "adapters/claude-code/claude/skills/integration-remediation/SKILL.md"
)


def _schema() -> dict:
    return json.loads((CLAUDE_SCHEMA_DIR / "execution-plan.schema.json").read_text())


# ── The CONTRACT (schema) ──

class TestContract:
    def test_kind_enum_has_integration(self):
        check = _schema()["$defs"]["checklist_item_2_0"]["properties"]["check"]
        assert KIND_VALUE in check["properties"]["kind"]["enum"]

    def test_check_declares_integration_fields(self):
        props = _schema()["$defs"]["checklist_item_2_0"]["properties"]["check"]["properties"]
        for field in CHECK_FIELDS:
            assert field in props, f"check.{field} missing from schema"

    def test_gate_remediation_required_and_enums(self):
        rem = _schema()["$defs"]["gate_remediation"]
        assert set(rem["required"]) == set(REMEDIATION_FIELDS)
        assert rem["properties"]["agent"]["enum"] == [AGENT_VALUE]
        assert rem["properties"]["on_unfixable"]["enum"] == [ON_UNFIXABLE_VALUE]
        mi = rem["properties"]["max_iterations"]
        assert mi["minimum"] == 1 and mi["maximum"] == 5


# ── The EXECUTOR (claude-session-lib.sh reads exactly these names) ──

class TestExecutorReadsContract:
    def test_executor_references_every_contract_field(self):
        src = LIB.read_text()
        # The probe in evaluate_phase_integration_checks keys on the kind value
        # and reads remediation.{max_iterations,on_unfixable}; run_phase keys on
        # trigger via integration_trigger_matches.
        for token in (
            f"'{KIND_VALUE}'",          # kind == 'integration'
            "remediation",
            "max_iterations",
            "on_unfixable",
            "trigger",
        ):
            assert token in src, f"executor does not read contract token {token!r}"


# ── The AUTHOR (skills tell /plan-project to write exactly these names) ──

class TestAuthorMatchesContract:
    def test_authoring_skill_documents_contract(self):
        txt = AUTHOR_SKILL.read_text()
        for token in (
            KIND_VALUE,
            *CHECK_FIELDS,
            *REMEDIATION_FIELDS,
            AGENT_VALUE,
            ON_UNFIXABLE_VALUE,
        ):
            assert token in txt, f"authoring skill omits contract token {token!r}"

    def test_producer_conventions_wires_the_rule_as_mandatory(self):
        """The /plan-project producer conventions (read at Step 5) must carry the
        integration-gate rule as a MANDATORY, directive step — not a soft pointer.
        A blind planner only authored shell gates when this was a soft pointer
        (real integration gates — authoring-wiring finding), so guard against
        regressing to one."""
        txt = PRODUCER_CONVENTIONS.read_text()
        assert "integration-gate-authoring" in txt, "must reference the authoring skill"
        assert "kind: integration" in txt
        assert "integration_test.trigger" in txt, "must tell the planner to read the manifest trigger"
        assert "verbatim" in txt.lower(), "must require copying the trigger verbatim"
        # The rule must be directive ("MANDATORY" + an intersect/path test), not advisory.
        assert "MANDATORY" in txt and "intersect" in txt.lower()

    def test_remediation_skill_states_the_guards(self):
        txt = REMEDIATION_SKILL.read_text().lower()
        # The fixer's load-bearing guards must be present, not paraphrased away.
        assert "never" in txt and "oracle" in txt          # Guard #2
        assert "untrusted" in txt                            # §6a injection guard
        assert "escalate" in txt or "cannot fix" in txt      # Guard #3 honest fail
