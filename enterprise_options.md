# TimelessStack Enterprise Architecture

## Design Principle

Keep the three open source libraries (timeless_metrics, timeless_logs, timeless_traces) exactly as they are - single-node, embeddable, lightweight. Build clustering as a stack-level concern in separate private repositories.

## Audience Separation

- **Embedded** (Phoenix devs) - lightweight library deps, zero-config, no clustering awareness needed
- **Standalone** (ops teams) - containerized deployment that scales horizontally

## Architecture

```
timeless_stack (open source, single-node)
  ├── timeless_metrics
  ├── timeless_logs
  └── timeless_traces

timeless_cluster (private)
  ├── node discovery / membership (libcluster or custom)
  ├── consistent hash ring
  ├── write routing / read fan-out
  ├── replication + anti-entropy
  └── shard management

timeless_stack_enterprise (private, composes both)
  ├── timeless_stack (all three services)
  └── timeless_cluster (distributed coordination)
```

## How It Works

Each node in the cluster runs the full single-node stack. `timeless_cluster` sits in front and handles distribution:

- **Writes**: routed to the correct node(s) via consistent hash ring
- **Reads**: fanned out across relevant nodes and merged
- **Replication**: writes forwarded to replica nodes for durability
- **Failover**: hash ring rebalances when nodes join/leave

The individual libraries never need to know they're in a cluster. They store and serve data for their shard as if they were standalone.

## BEAM Advantages

OTP distribution, pg groups, and native process messaging across nodes are built in. Go competitors bolt on gRPC sidecars and gossip protocols. BEAM gets this for free, which is the basis for surpassing them.

## Required Hook: Write-Ahead Log / Change Feed

The one addition needed in the open source libraries is a WAL or change feed for replication - so `timeless_cluster` can stream writes between replicas. This can be added as a general-purpose feature in the open source libraries since it also enables:

- Litestream-style embedded-to-stack replication (Phoenix apps streaming to centralized stack)
- Point-in-time recovery
- Cross-datacenter replication

No clustering logic leaks into the libraries themselves.

## Scaling Model

| Deployment | Stack | Use Case |
|---|---|---|
| Single node | timeless_stack (free) | Small/medium, dev, single datacenter |
| DIY horizontal | 2x timeless_stack + Vector (free) | Large datacenter, cost-conscious |
| Clustered | timeless_stack_enterprise (paid) | Multi-datacenter, enterprise, managed |

## Enterprise-Only Features

- Automatic cluster formation and node discovery
- Consistent hashing with virtual nodes
- Configurable replication factor (1x, 2x, 3x)
- Anti-entropy repair for diverged replicas
- Rolling upgrades with zero downtime
- Multi-tenant isolation and RBAC
- Built-in observability UI (Grafana-style)
- SLA-grade alerting and on-call integrations
