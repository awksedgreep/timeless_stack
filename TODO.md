# TimelessStack Roadmap

## v1.1 - Stack-Level Features

- [ ] Unified `/health` endpoint aggregating all three services on a single port
- [ ] Global retention policy overrides at the stack level
- [ ] Backup scheduling via GenServer (cron-style periodic backups)
- [ ] Self-instrumentation: write stack resource usage (memory, disk, request rates, BEAM stats) into timeless_metrics - doubles as test data for GUIs
- [ ] `docker-compose.yml` with Grafana pre-configured against the Prometheus-compatible endpoint

## v2.0 - Clustering

- [ ] Advanced clustering surpassing Go-based competitors (Prometheus/Thanos/Cortex/Mimir)
- [ ] Litestream-style replication: embedded Phoenix apps stream updates to centralized stack

## v2.x - Ingestion & UI

- [ ] Better ingestion protocols: OTLP gRPC+HTTP, Prometheus remote write, Loki-compatible push
- [ ] Built-in Grafana-style observability UI
- [ ] Live tail for logs/traces via WebSocket/SSE
