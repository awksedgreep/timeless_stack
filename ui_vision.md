# TimelessStack UI Vision

## Core Concept

Replace the grid-of-panels dashboard paradigm (Grafana, New Relic, Datadog) with a freeform spatial canvas where the layout represents your actual infrastructure. The topology IS the dashboard.

Inspired by:
- **tkined** (Scotty) - spatial network editor with live SNMP overlays
- **Linux window managers** (i3/sway) - floating, tiling, stacking, keyboard-driven
- **Anti-New Relic** - no rigid pre-built layouts, no restrictions on arrangement

## The Canvas

The primary workspace is an infinite pannable, zoomable canvas. Everything lives on it:

- **Server icons** positioned to reflect real network topology
- **Metrics graphs** attached to elements, auto-bound to that host's data
- **Log streams** in floating, scrollable windows
- **Trace waterfalls** expandable from any element
- **Status indicators** (green/yellow/red) glowing on each element in real-time
- **Connection lines** between elements showing traffic flow with live throughput
- **Labels and annotations** for documentation and context
- **Grouping containers** for racks, availability zones, regions, logical services

### Detail Levels

Instead of semantic zoom, detail is managed by linking canvas elements to sub-canvases.
Double-click a canvas element to drill down. Breadcrumb navigation to go back up.

### Keyboard-Driven

For power users who live in tiling WMs:

- `/` to open command palette (search for any element, metric, action)
- `hjkl` or arrow keys to navigate between elements
- `Enter` to expand/focus an element
- `Esc` to zoom back out
- `1-9` to switch between saved layouts/workspaces
- `Space` to toggle live tail on focused log panel
- `g` to add a graph to the selected element
- `l` to open a log window for the selected element
- `t` to open traces for the selected element

## Element Types

### Infrastructure Elements

- **Server** - physical or virtual machine, shows hostname, IP, OS
- **Container** - Docker/Podman container, shows image, resource limits
- **Service** - logical service spanning multiple hosts
- **Database** - with query rate, connection pool, replication lag overlays
- **Load balancer** - with upstream health and request distribution
- **Network device** - router, switch, firewall with interface stats
- **Custom** - user-defined icon + label for anything else

### Data Panels

- **Time series graph** - line, area, stacked, with multiple series
- **Sparkline** - compact inline graph for embedding in element labels
- **Gauge** - circular or linear for current values (CPU%, memory%, disk%)
- **Log stream** - scrollable, filterable, with live tail toggle
- **Trace waterfall** - latency breakdown across services
- **Table** - for structured data (top-N queries, error counts by path)
- **Stat** - single big number with trend arrow
- **Status light** - green/yellow/red dot with configurable thresholds

### Connections

- **Lines** between elements with optional labels
- **Animated flow** showing direction and volume (thicker = more traffic)
- **Color-coded** by health (green = healthy, red = errors detected)
- Auto-discovered from trace data (service A called service B)

## Binding Data to Elements

Drag a graph onto a server and it auto-binds using element metadata:

```
Server "web-01" has labels: {host: "web-01", role: "web", rack: "A3"}

Dropping a "CPU Usage" graph onto it automatically queries:
  TimelessMetrics: cpu_usage{host="web-01"}

Dropping a "Log Stream" panel queries:
  TimelessLogs: metadata.host = "web-01"

Dropping a "Traces" panel queries:
  TimelessTraces: service = "web-01" OR attributes.host = "web-01"
```

Users can override the auto-binding with custom queries.

## Workspaces

Multiple named workspaces (like virtual desktops in a WM):

- **Overview** - the full datacenter/network map
- **Web Tier** - zoomed in on load balancers + web servers
- **Database** - focused on DB cluster with replication topology
- **Incidents** - ad-hoc workspace for active investigation
- **Per-team** - each team maintains their own view of what they care about

Switch between workspaces with keyboard shortcuts or tabs. Each workspace persists its layout, zoom level, and panel states independently.

## Live Features

### Live Tail

Any log or trace panel can toggle into live tail mode:
- New entries stream in via WebSocket
- Auto-scroll with pause on hover
- Highlight/filter in real-time without losing position
- Audio/visual alert on pattern match (e.g., flash red on ERROR)

### Alerting Overlays

When an alert fires:
- The affected element pulses/glows on the canvas
- A notification banner slides in with alert details
- Click to zoom directly to the affected element
- Timeline scrubber appears to correlate with other signals

### Time Travel

A global time range selector that shifts the entire canvas back in time:
- All graphs, stats, and status indicators reflect the selected time
- Scrub through an incident to see how it propagated across the topology
- Play/pause/speed controls for replaying incidents
- "Compare" mode: split view showing current vs. historical state

## Collaboration

### Shared Canvases

- Multiple users view and edit the same canvas in real-time
- Cursor presence (see where teammates are looking)
- Locking: optional per-panel locks to prevent accidental edits
- Comments: attach notes to any element or panel

### Incident Mode

One-click to enter incident mode:
- Snapshots the current canvas state
- Opens a shared investigation workspace
- Automatic timeline recording of who looked at what
- Exports to incident report when resolved

## Technology

### Phoenix LiveView

The primary rendering engine. Server-side state, real-time updates over WebSocket:
- No heavy JavaScript framework needed for data flow
- LiveView hooks for the canvas interaction layer (pan, zoom, drag)
- Efficient diffs - only changed elements re-render
- Built-in presence for collaboration features

### Client-Side Canvas

The spatial canvas itself needs a client-side rendering layer:
- **SVG** for elements, connections, and panels (DOM-based, accessible, styleable)
- **Canvas API** fallback for very large deployments (thousands of elements)
- LiveView hooks bridge server state to canvas rendering
- All layout state persisted server-side (survives refresh, shareable)

### Data Flow

```
TimelessMetrics ──┐
TimelessLogs ─────┼── LiveView Process ── WebSocket ── Canvas
TimelessTraces ───┘        │
                     PubSub/subscriptions
                     for live updates
```

Each open panel subscribes to its data source via the existing library PubSub:
- `TimelessLogs.subscribe(level: :error, metadata: %{host: "web-01"})`
- `TimelessTraces.subscribe(service: "api-gateway")`
- Metrics polled on configurable interval or pushed on threshold breach

## Differentiators

| Feature | Grafana | Datadog | New Relic | TimelessStack |
|---|---|---|---|---|
| Layout | 12-col grid | Grid | Rigid pre-built | Freeform canvas |
| Topology awareness | Plugin only | Partial | Service map only | Native, first-class |
| Keyboard-driven | No | No | No | Yes |
| Self-hosted | Yes | No | No | Yes |
| BEAM-native | No | No | No | Yes |
| All signals unified | Plugin juggling | Yes (expensive) | Yes (expensive) | Yes (built-in) |
| Real-time collaboration | No | Limited | Limited | Native LiveView |
| Time travel replay | Range selector only | Limited | Limited | Full topology replay |

## Implementation Phases

### Phase 1: Static Canvas
- Pannable, zoomable SVG canvas
- Place and arrange server icons manually
- Attach metrics graphs that poll on interval
- Save/load layouts
- Basic keyboard navigation

### Phase 2: Live Data
- WebSocket streaming for log tails and trace updates
- Status indicators with threshold-based coloring
- Connection lines with throughput animation
- Alert overlay with element highlighting

### Phase 3: Intelligence
- Auto-discovery of topology from trace data
- Suggested layouts based on service dependencies
- Anomaly highlighting (element glows when metrics deviate)
- Time travel / incident replay

### Phase 4: Collaboration
- Shared canvases with presence
- Incident mode with timeline recording
- Comments and annotations
- RBAC for view/edit permissions (enterprise)
