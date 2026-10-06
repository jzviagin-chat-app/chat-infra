# Observability

Logs, traces and metrics for every pod, viewed in Grafana.

```
pods (stdout) ──► Alloy ──► Loki ──► bucket chat-logs     (7 days)
services (OTLP traces) ──► Alloy :4317/:4318 ──► Tempo ──► bucket chat-traces (3 days)
nodes, pods ◄── Prometheus (scrapes every 60 s, local disk, 7 days)
                         Grafana ◄── reads all three (SSH tunnel only)
```

Everything runs on the `ops` node, in the `observability` namespace.

| Component | Address inside the cluster |
|---|---|
| Loki | `http://loki.observability.svc:3100` |
| Tempo | `http://tempo.observability.svc:3200` |
| Prometheus | `http://prometheus-server.observability.svc` |
| Grafana | `http://grafana.observability.svc` |
| **Send traces here** (services) | `alloy.observability.svc:4317` (gRPC) / `:4318` (HTTP) |

## Open Grafana

```bash
ssh -L 3000:localhost:3000 ubuntu@<lb_public_ip> \
  'kubectl -n observability port-forward svc/grafana 3000:80'
```
Then browse to http://localhost:3000 and log in with the admin user/password from your password manager.

## Useful queries (Explore)

**Loki**
```
{namespace="default"}                              all app pods
{app="auth"}                                       one service
{app="auth"} | json | level="error"                errors only (JSON logs)
{namespace="observability", pod=~"loki.*"}         Loki's own logs
```

**Prometheus**
```
sum by (node) (rate(node_cpu_seconds_total{mode!="idle"}[5m]))     CPU per node
node_memory_MemAvailable_bytes / 1e9                                free memory (GB)
kube_pod_container_status_restarts_total > 0                        restarting containers
```

**Tempo:** "Search" tab, or click a `trace_id` in a log line. Empty until services send traces.

## Logging rules for our services
- One **JSON object per line** on stdout, with `level`, `msg` and, when inside a request, `trace_id`.
  Alloy turns `level` into a label and keeps `trace_id` as metadata linked to Tempo.
- **Never log** OTP codes, tokens, passwords or full phone numbers (mask them: `+97250***1234`).

## Free-tier guards
- Retention: logs 7 days, traces 3 days (Loki/Tempo), plus bucket lifecycle rules (14 / 7 days) as a
  safety net.
- Few object-storage requests: Loki uploads chunks after ~1 h idle / 2 h max; compaction every 2 h;
  Tempo polls the bucket every 15 min. Check monthly request counts in the Oracle console
  (bucket → Metrics) for the first weeks.
- Loki ingestion limit: 4 MB/s per tenant, so a runaway pod can't fill the bucket.

## Troubleshooting
```bash
kubectl -n observability get pods -o wide
kubectl -n kube-system get pods | grep helm-install        # Error = chart install failed
kubectl -n kube-system logs job/helm-install-<name> --tail=30
kubectl -n observability logs statefulset/loki --tail=50   # storage errors show here
kubectl -n observability logs statefulset/tempo --tail=50
kubectl -n observability logs deploy/alloy --tail=50
```
`AccessDenied` / `SignatureDoesNotMatch` from Loki or Tempo: wrong key, endpoint or region in
`observability-loki.yaml` / `observability-tempo.yaml`, or the observability user's policy.
