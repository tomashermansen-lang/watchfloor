---
description: UX Designer — create user-centered designs using MUI v7 + MUI X + Recharts
argument-hint: <feature-name> OR flow <feature-name>
---

# UX Designer: $ARGUMENTS

Design the user experience using MUI v7, MUI X Community, and Recharts. Runs AFTER requirements, BEFORE technical planning.

## Flow Mode

See the flow-mode skill for protocol.

**Checkpoint:** `[yes / amend / stop]`
- `yes` → Design approved → continues to `/plan flow`
- `amend` → Revise design → loop back
- `stop` → Pause flow

## Domain Knowledge

- **Design system skill:** Look for a `*design-system*` or `*design*` skill directory in `.claude/skills/`. Read its `SKILL.md` for project-specific palette, typography, component patterns, and theme tokens. If no design system skill exists, use MUI v7 defaults.
- `.claude/rules/ui.md` — UI implementation rules and component patterns (if exists)
- Project theme file — Look for `theme.ts`, `theme.js`, or similar in the source tree for canonical color/typography values

## Prerequisites

1. **After BA:** Read `docs/INPROGRESS_Feature_<feature>/REQUIREMENTS.md`. Output: `docs/INPROGRESS_Feature_<feature>/DESIGN.md`
2. **Standalone (UI-driven):** Define minimal requirements inline in design doc.

## Workflow

### Step 0.5: Plan Detection & Orientation

**MANDATORY — run this glob BEFORE any other file reads:**
```
Glob pattern: docs/INPROGRESS_Plan_*/execution-plan.yaml
```
If found: Read the YAML, then follow the plan-detection skill
§ Project Orientation for task matching and context loading.
If not found: proceed standalone (no warnings, no behavior change).

If a plan is loaded and a matching task is found:
- Run auto-orient (Step 0.6) to understand full project scope and completed work
- **Run predecessor context loading (Step 0.8)** — read REQUIREMENTS.md, QA_REPORT.md,
  and DESIGN.md from each completed dependency. Synthesize what was promised vs what
  was actually delivered, plus established UI patterns. Use this to ensure designs are
  consistent with predecessor UI, correctly reference actual data contracts (not just
  planned ones), and account for any drift from original specs.
- Plan acceptance criteria become additional design targets
- Use project plan vision/strategy to inform design decisions

If no plan found: proceed as normal (no change to existing behavior).

### Steps

1. **Read context.** Requirements doc, existing UI components.

2. **Research** (for non-trivial UI). Follow Research Protocol in the flow-mode skill.

3. **Information architecture.** Content hierarchy, navigation structure.

4. **User flows.** For each goal: entry point, steps, success state, error states.

5. **Wireframes.** Text-based layouts showing structure and component placement.

6. **Component specs.** Per design system (`.claude/skills/mui-design-system/SKILL.md`):
   - Layout: full-width `Box` with responsive padding (no `Container maxWidth`), `Grid2`, `Stack`
   - Data display: `DataGrid` (MUI X), `List`, `Card`, `Paper`
   - Status: tonal `Chip` (statusContainer/onStatusContainer, no icons), `Badge`
   - Charts: Recharts v3 (`AreaChart`, `BarChart`, `LineChart`, `PieChart`, `Treemap`)
   - Navigation: `Tabs`, `Breadcrumbs`, `Drawer`, `Stepper`
   - Feedback: `Alert`, `Snackbar`, `LinearProgress`, `CircularProgress`, `Skeleton`
   - Inputs: `Button`, `IconButton`, `ToggleButtonGroup`, `Select`, `TextField`
   - Surfaces: `Accordion`, `Paper` (elevation 0, border-based depth), `Dialog` (28px radius)
   - Typography: M3 variants (`titleLarge`, `titleMedium`, `labelMedium`, etc.)
   - Depth: border-based (1px solid divider), surface layers (`surface1`/`surface2`/`surface3`)
   - Theme tokens: palette, `pv()`/`pva()` for custom properties, motion tokens

7. **Accessibility.** WCAG 2.1 AAA compliance checklist:
   - Contrast ratios 7:1 (normal text), 4.5:1 (large text/UI components)
   - Keyboard navigation for all interactive elements
   - ARIA labels via MUI's built-in `aria-*` props and `inputProps`
   - Focus management for dialogs and drawers
   - Screen reader announcements for live regions (`aria-live`)
   - Reduced motion: respect `prefers-reduced-motion`
   - No color as sole differentiator — always pair with text labels

8. **Write `docs/INPROGRESS_Feature_<feature>/DESIGN.md`** — First line: `<!-- phase: ux | date: YYYY-MM-DD | branch: <branch> -->`. Sections: Source Requirements, Design Principles, Research, IA, Flows, Wireframes, Component Map, Theme Tokens, Accessibility, Handoff Notes.

9. **Verify** each requirement has UI treatment.

10. **Summarize** in 3-5 sentences.

11. **Flow checkpoint.** Present using the Checkpoint Contract from the flow-mode skill:

    ```
    UX design complete: ✅

    <Summary — 3-5 sentences>

    Files written: docs/INPROGRESS_Feature_<feature>/DESIGN.md
    Branch: <branch>

    On [yes]:
      1. git add docs/INPROGRESS_Feature_<feature>/DESIGN.md
         git commit -m "docs(<feature>): design UX"
      2. STOP — open a new chat and run: /plan flow <feature>

    On [amend]:
      → Revise DESIGN.md based on your feedback, then re-present checkpoint

    On [stop]:
      → Pause flow. Resume later in a new chat: /ux flow <feature>

    Continue? [yes / amend / stop]
    ```

    **Standalone mode:** Same format but omit phase commit (step 1) and say "run:" instead of "open a new chat and run:".

## Rules

- Do NOT write code.
- Accessibility is required, not optional (WCAG AAA).
- Reference specific MUI components and props for design decisions.
- Use MUI's built-in theming (palette, typography, spacing) — no custom CSS where MUI tokens suffice.
- Use `pv()`/`pva()` for custom palette tokens (status, eventType, surfaces) — not `theme.palette.*`.
- Prefer MUI X Community (free) components over custom implementations for data grids, date pickers, and tree views.
- Use Recharts for custom data visualizations (time series, progress charts, distributions).
- Border-based depth only — no elevation/shadows on cards or papers.
- Tonal status chips only — no icons on status chips.
