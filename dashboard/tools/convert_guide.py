#!/usr/bin/env python3
"""Convert EXECUTION_GUIDE.md markdown to schema-valid execution-plan JSON.

Best-effort conversion using the same patterns as the dashboard's pipelineParser.

Two internal functions:
- parse_guide(text) — extracts structure from markdown
- emit_plan(parsed) — transforms to schema-conformant JSON

Usage: python3 tools/convert-guide.py <markdown-file>
Output: JSON to stdout.
"""
import json
import re
import sys
from pathlib import Path


def parse_guide(text: str) -> dict:
    """Parse EXECUTION_GUIDE.md markdown into intermediate structure.

    Returns dict with 'phases' list, each phase having 'id', 'name',
    'items' (mixed tasks and gates), and parallel group info.
    """
    lines = text.split("\n")
    phases = []
    current_phase = None
    in_parallel = False
    parallel_group_id = 0
    gate_checklist = []
    collecting_gate = False
    current_gate_label = ""
    current_gate_passed = False

    fase_re = re.compile(
        r"^\s*(?:#{1,3}\s*)?[Ff][Aa][Ss][Ee]\s+(\d+)\s*[:\-\u2014\u2013]\s*(.+)"
    )
    gate_re = re.compile(
        r"^\s*(?:[\u2550═#]*\s*)?(?:FINAL\s+)?GATE\s*:\s*(.+)", re.IGNORECASE
    )
    trin_re = re.compile(r"\[Trin\s+(\d+)\]\s*(.+)", re.IGNORECASE)
    cmd_re = re.compile(r">>\s*\/(?:start|ba(?:\s+flow)?)\s+(\S+)")
    list_re = re.compile(r"^\s*[-*]\s+(?:\[.\]\s*)?(.+)")
    numbered_re = re.compile(r"^\s*\d+\.\s+(.+)")

    done_re = re.compile(r"[\u2713\u2705]\s*(?:DONE|PASSED)", re.IGNORECASE)
    done_checkbox_re = re.compile(r"\[x\]", re.IGNORECASE)
    wip_re = re.compile(r"(?:WIP|IN.?PROGRESS|INPROGRESS)", re.IGNORECASE)

    def detect_status(line_text):
        is_done = bool(done_re.search(line_text)) or bool(done_checkbox_re.search(line_text))
        is_wip = bool(wip_re.search(line_text)) and not is_done
        if is_done:
            return "done"
        if is_wip:
            return "wip"
        return "pending"

    def clean_name(name):
        name = re.sub(r"[\u2551]", "", name)
        name = re.sub(r"[\u2713\u2705]\s*(?:DONE|PASSED)\b", "", name, flags=re.IGNORECASE)
        name = re.sub(r"\bDONE\b", "", name, flags=re.IGNORECASE)
        name = re.sub(r"\bWIP\b", "", name, flags=re.IGNORECASE)
        name = re.sub(r"\bIN.?PROGRESS\b", "", name, flags=re.IGNORECASE)
        name = re.sub(r"\[x\]", "", name, flags=re.IGNORECASE)
        name = re.sub(r"\[\s\]", "", name)
        name = re.sub(r"\*\*", "", name)
        name = re.sub(r"^\s*[-:]\s*", "", name)
        return name.strip()

    def flush_gate():
        nonlocal collecting_gate, gate_checklist, current_gate_label, current_gate_passed
        if collecting_gate and current_phase and gate_checklist:
            current_phase["gates"].append({
                "label": current_gate_label,
                "passed": current_gate_passed,
                "checklist": gate_checklist[:],
            })
        collecting_gate = False
        gate_checklist = []
        current_gate_label = ""
        current_gate_passed = False

    def add_item(name, status, prompt=None):
        name = clean_name(name)
        if not name:
            return
        for existing in current_phase["items"]:
            if existing["name"] == name:
                return
        item = {
            "name": name,
            "status": status,
            "parallel": in_parallel,
            "pgroup": parallel_group_id if in_parallel else 0,
        }
        if prompt:
            item["prompt"] = prompt
        current_phase["items"].append(item)

    seen_fase_nums = set()

    for line in lines:
        fase_match = fase_re.match(line)
        if fase_match:
            flush_gate()
            title = fase_match.group(2).strip()
            if re.match(r"^(?:GATE|QUALITY)", title, re.IGNORECASE):
                if current_phase:
                    gate_label = re.sub(r"^GATE\s*:\s*", "", title, flags=re.IGNORECASE)
                    gate_label = re.sub(r"^QUALITY\s*GATE\s*", "", gate_label, flags=re.IGNORECASE)
                    passed = bool(re.search(r"\u2713\s*PASSED", line, re.IGNORECASE))
                    collecting_gate = True
                    current_gate_label = gate_label
                    current_gate_passed = passed
                continue

            fase_num = int(fase_match.group(1))
            if fase_num in seen_fase_nums:
                continue
            seen_fase_nums.add(fase_num)

            title = re.sub(r"\(.*\)$", "", title).strip()
            current_phase = {
                "id": f"fase-{fase_num}",
                "number": fase_num,
                "name": title,
                "items": [],
                "gates": [],
            }
            phases.append(current_phase)
            in_parallel = False
            continue

        gate_match = gate_re.match(line)
        if gate_match and current_phase:
            flush_gate()
            label = gate_match.group(1)
            label = re.sub(r"\s*[\u2550═]+\s*$", "", label).strip()
            passed = bool(re.search(r"\u2713\s*PASSED", line, re.IGNORECASE))
            collecting_gate = True
            current_gate_label = label
            current_gate_passed = passed
            continue

        if re.search(r"PARALLEL", line, re.IGNORECASE) and current_phase:
            flush_gate()
            if not in_parallel:
                parallel_group_id += 1
            in_parallel = True
            continue

        if re.search(r"SEKVENTIELT", line, re.IGNORECASE) and current_phase:
            flush_gate()
            in_parallel = False
            continue

        if not current_phase:
            continue

        status = detect_status(line)

        # Gate checklist items (list items after a GATE: line)
        if collecting_gate:
            list_match = list_re.match(line)
            numbered_match = numbered_re.match(line)
            if list_match:
                cleaned = clean_name(list_match.group(1))
                if cleaned:
                    gate_checklist.append(cleaned)
                continue
            elif numbered_match:
                cleaned = clean_name(numbered_match.group(1))
                if cleaned:
                    gate_checklist.append(cleaned)
                continue
            elif line.strip():
                flush_gate()
            else:
                continue

        trin_match = trin_re.search(line)
        if trin_match:
            add_item(trin_match.group(2), status)
            continue

        if cmd_re.search(line):
            segments = line.split("\u2551")
            found = False
            for seg in segments:
                m = cmd_re.search(seg)
                if m:
                    cmd_name = m.group(1).replace("\u2551", "").strip()
                    if not cmd_name:
                        continue
                    seg_done = bool(done_re.search(seg))
                    seg_status = "done" if seg_done else "pending"
                    prompt_text = seg.strip()
                    prompt_match = re.search(r"(>>\s*\S+.*?)(?:\s*[\u2713\u2705]|\s*$)", seg)
                    if prompt_match:
                        prompt_text = prompt_match.group(1).strip()
                    add_item(cmd_name, seg_status, prompt=prompt_text)
                    found = True
            if found:
                continue

        list_match = list_re.match(line)
        if list_match:
            add_item(list_match.group(1), status)
            continue

        numbered_match = numbered_re.match(line)
        if numbered_match:
            add_item(numbered_match.group(1), status)
            continue

    flush_gate()

    # Extract title from first markdown heading
    title = None
    for line in lines:
        heading_match = re.match(r"^#{1,2}\s+(.+)", line)
        if heading_match:
            title = heading_match.group(1).strip()
            break

    return {"phases": phases, "title": title}


def emit_plan(parsed: dict) -> dict:
    """Transform intermediate parsed structure to schema-conformant JSON."""
    title = parsed.get("title") or "Converted Execution Plan"
    plan = {
        "schema_version": "1.0.0",
        "name": title,
        "description": f"Auto-converted from EXECUTION_GUIDE.md ({title})",
        "phases": [],
    }

    for phase_data in parsed.get("phases", []):
        phase = {
            "id": phase_data["id"],
            "name": phase_data["name"],
            "tasks": [],
        }

        seen_ids = set()
        slug_counts: dict[str, int] = {}
        for item in phase_data.get("items", []):
            base_id = _make_slug(item["name"])
            task_id = base_id
            if task_id in seen_ids:
                slug_counts[base_id] = slug_counts.get(base_id, 1) + 1
                task_id = f"{base_id}-{slug_counts[base_id]}"
            seen_ids.add(task_id)

            task = {
                "id": task_id,
                "name": item["name"],
                "status": item["status"],
            }
            if item.get("parallel") and item.get("pgroup"):
                task["parallel_group"] = f"group-{item['pgroup']}"
            if item.get("prompt"):
                task["prompt"] = item["prompt"]
            phase["tasks"].append(task)

        gates = phase_data.get("gates", [])
        if gates:
            last_gate = gates[-1]
            checklist = last_gate.get("checklist", [])
            if not checklist:
                checklist = [last_gate.get("label", "Gate check")]
            phase["gate"] = {
                "name": last_gate.get("label", "Quality Gate"),
                "checklist": checklist,
                "passed": last_gate.get("passed", False),
            }

        plan["phases"].append(phase)

    return plan


def _make_slug(name: str) -> str:
    """Convert a name to a valid task ID slug."""
    s = name.lower()
    s = re.sub(r"[^a-z0-9]+", "-", s)
    s = s.strip("-")
    return s[:50] if s else "task"


def main():
    if len(sys.argv) != 2:
        print("Usage: python3 tools/convert-guide.py <markdown-file>", file=sys.stderr)
        sys.exit(1)

    file_path = sys.argv[1]
    if not Path(file_path).exists():
        print(f"ERROR: File not found: {file_path}", file=sys.stderr)
        sys.exit(1)

    text = Path(file_path).read_text(encoding="utf-8")
    parsed = parse_guide(text)
    plan = emit_plan(parsed)
    print(json.dumps(plan, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
