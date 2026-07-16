# Component Patterns

## Layout

**Full-width** — no `Container maxWidth`. Use `Box` with responsive padding:
```
sx={{ px: { xs: 1.5, sm: 2, md: 3, lg: 4, xl: 6 }, py: 3 }}
```

**Grid**: `Grid2` (CSS gap-based) with standard column patterns:
```
4-across (KPI cards):   size={{ xs: 12, sm: 6, lg: 3 }}
3-across (item cards):  size={{ xs: 12, sm: 6, lg: 4 }}
2-across (panels):      size={{ xs: 12, lg: 6 }}
Full-width:             size={{ xs: 12 }}
```

Grid spacing: `spacing={1.5}` for card grids.

## Cards (Border-Based Depth)

All cards use elevation 0 with border-based depth:

```
<Paper sx={{ p: 1.5 }}>  — elevation 0 (theme default), 1px border via theme
<Card>                    — elevation 0 (theme default), hover: primary.light border
```

No drop shadows. Depth via borders + surface layer backgrounds.

## Status Chips (Tonal, No Icons)

```
<Chip label="Done" color="done" size="small" />
```

Theme renders tonal: 14% colored background + colored text. Do NOT add `icon` prop to status chips — text + tonal color is sufficient for accessibility.

## Data Tables

`DataGrid` (MUI X v8 Community) for sortable, filterable lists.
- Free tier: sorting, filtering, pagination, column resize, row selection
- NOT free: column grouping, aggregation, row grouping, pivot, Excel export

## Charts (Recharts v3)

**When to use Recharts vs MUI X Charts:**
- Recharts: custom layouts, complex compositions, tooltips with custom content
- MUI X Charts: simpler integration with MUI theme

**Common patterns:**
```
AreaChart     — progress over time, burndown
BarChart      — task counts per phase, comparison
LineChart     — trend lines, velocity
PieChart      — status distribution (done/wip/pending)
Treemap       — proportional view of effort across phases
```

**Theme integration:** `useTheme()` for standard palette, `pv()` for custom tokens in dark mode.

## Navigation

- **Project switching:** `Tabs` for project selector
- **Phase navigation:** `Stepper` (vertical) for phase progression
- **Sidebar:** `Drawer` (permanent on desktop, temporary on mobile)
- **Drill-down:** `Breadcrumbs` (Project > Phase > Task)

## Feedback & Loading

- `Skeleton` (`variant="rectangular"`) for placeholder content
- `Snackbar` + `Alert` for transient notifications
- `LinearProgress` in header for global loading state
- `Backdrop` + `CircularProgress` for blocking operations

## Session Status Mapping

Dashboard-specific status colors for session monitoring:

```
working / active    → status.wip
needs_input         → status.failed
idle                → status.pending
completed / done    → status.done
stopped             → status.skipped
blocked             → status.blocked
wip / in_progress   → status.wip
```
