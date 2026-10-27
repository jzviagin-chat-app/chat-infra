# System architecture (as built)

The current shape of the whole system: which services exist, what each owns, how they talk to each other,
and the conventions every repo follows. **Keep it true:** when a change alters anything here, update this file
in the same task (and add a row to the change log in `PLAN.md`). Plans and phases live in `PLAN.md`.

Last updated: 2026-10-27.

---

## 1. Repositories (GitHub org `jzviagin-chat-app`, all public)

| Repo | What | Status |
|---|---|---|
| `chat-infra` | Terraform (Oracle Cloud), Kubernetes manifests (`k8s/`, deployed by Argo CD), hand-run jobs (`manual/`), **all system docs (`docs/`)** | live |
| `auth-service` | Phone + SMS-code signup/login, devices, tokens. Python 3.14 / async FastAPI / Postgres | deployed: skeleton + tables (`users`, `devices`, `otp_challenges`); no feature endpoints yet |
| `chat-service` | WebSocket messaging. Will use the same stack as auth-service | placeholder (echo server) |
| mobile app (later) | Expo / React Native + TypeScript | not started |

`main` is protected everywhere: changes arrive only through pull requests, admins included.

## 2. Runtime topology

```
                         internet
                            │ 443 (80 redirects)
          jzviagin-chat-app.129-159-150-34.sslip.io  (Let's Encrypt via cert-manager)
                            │
┌───────────────────────────▼───────────────────────────┐
│ lb node     k3s control plane, HAProxy ingress (leastconn), Argo CD, cert-manager,
│             Sealed Secrets controller, Redis (namespace default)
└──────┬───────────────────────────────────────┬────────┘
       │ /auth/*  → Service auth:8000           │ /*  (incl. WebSocket /ws) → Service chat:8000
┌──────▼──────────────┐  ┌──────────────────────▼─┐
│ worker ×2           │  │  auth pods (2), chat pods (2) — stateless, spread over both workers
└──────┬──────────────┘  └──────────┬─────────────┘
       │ Postgres                    │ Cassandra, Redis
┌──────▼─────────────────────────────▼──────────────────┐
│ ops node   Postgres 17 (ns database), Cassandra 5.0.9 (ns chat-db),
│            Loki, Tempo, Prometheus, Grafana, Alloy (ns observability)
└───────────────────────────────────────────────────────┘
        Oracle Object Storage (S3 API): chat-logs, chat-traces, chat-backups
```

Rate limiting at the edge: HAProxy allows 200 requests per 10 s per client IP on every route (`k8s/ingress.yaml`),
then answers `429`. Deliberately generous (carrier-grade NAT); stricter, business-specific limits live in the services.

Client IPs: the HAProxy ingress Service uses `externalTrafficPolicy: Local`, so HAProxy sees the real client IP
and passes it to the apps in `X-Forwarded-For` (apps run uvicorn with `--proxy-headers`). Note: HAProxy is installed
by k3s from `/var/lib/rancher/k3s/server/manifests/haproxy-ingress.yaml` on the lb VM (written by cloud-init from
`terraform/cloud-init/haproxy-ingress.yaml`); changes must be made in both places (Terraform ignores user-data changes).

Oracle Cloud Always Free: 4 ARM VMs (1 OCPU / 6 GB / 50 GB each) = the whole free allowance.
Node labels: `role=lb`, `role=worker`, `role=ops`. Rule: **stateless app pods on workers, stateful things on
`ops` (databases) or `lb` (Redis)**.

## 3. Services

### auth-service (`/auth/*`)
- Owns: users, devices, SMS codes, refresh tokens, signing keys. Database `auth` on Postgres (user `auth`).
- Planned API: `POST /auth/otp/request`, `POST /auth/otp/verify`, `POST /auth/token/refresh`,
  `POST /auth/logout`, `GET/DELETE /auth/devices`, `GET /auth/.well-known/jwks.json`.
  Live today: `GET /healthz`, `GET /auth/healthz`, `POST /auth/otp/request`, `GET /auth/.well-known/jwks.json`.
- Gets `DATABASE_URL` from Secret `auth-db`, `OTP_PEPPER` from Secret `auth-otp` (HMAC key for SMS codes),
  `GLOBALSMS_API_KEY` from Secret `auth-sms`, `JWT_PRIVATE_KEY` from Secret `auth-jwt`, `SMS_PROVIDER=globalsms` and
  `REDIS_URL=redis://redis:6379/1` (rate limits). Migrations: Alembic, run by the `migrate` init container in
  `k8s/auth.yaml` (same image as the app) before the app starts, on every pod start (`DATABASE.md`).
- External dependency: **Global SMS** (Israeli SMS provider, prepaid) sends the login codes, via
  `https://sapi.itnewsletter.co.il` (the `sapi` host has no IP allow-list: the API key alone authorizes sending).
  Host, sender name and daily cap are defaults in the auth-service code (`GLOBALSMS_*` env vars override them).

### chat-service (`/`, WebSocket `/ws`)
- Owns: inboxes, chat lists, conversation members, message history. Keyspace `chat` on Cassandra
  (user `chat_app`). Uses Redis for the connection registry and pub/sub between instances.
- Today: an echo WebSocket (`/ws`) and `/healthz`. The messaging design is in `PLAN.md` section 4.

## 4. Data ownership — each service owns its stores; no service reads another's

| Store | Address in the cluster | Owner | Contents |
|---|---|---|---|
| Postgres 17 | `postgres.database.svc.cluster.local:5432`, db `auth` | auth-service | `users`, `devices`, `otp_challenges` (migration 0001); later `refresh_tokens`, `sms_daily_usage`, `device_links` |
| Cassandra 5.0.9 | `cassandra.chat-db.svc.cluster.local:9042`, keyspace `chat` | chat-service | `inbox_by_device`, `device_inbox_seq`, `messages_by_conversation`, `conversation_seq`, `user_conversations`, `conversation_members`, `devices_by_user` |
| Redis 7.4 | `redis://redis:6379` (namespace default): db `0` chat, db `1` auth | chat-service (db 0), auth-service (db 1) | only rebuildable state: chat's connection registry and pub/sub; auth's per-phone / per-IP rate-limit counters (keys `auth:rl:…`) |
| Object storage | `https://axmmbljjebqv.compat.objectstorage.il-jerusalem-1.oraclecloud.com` | infra | `chat-logs` (Loki), `chat-traces` (Tempo), `chat-backups` (`postgres/`, `cassandra/`); later media |

Network rules: Redis accepts only pods `app=chat` and `app=auth`. Postgres accepts only pods `app=auth`
(namespace default) and pods in `database`;
Cassandra accepts only `app=chat` and pods in `chat-db`. Details: `DATABASE.md`, `CASSANDRA.md`.

## 5. Contracts between services

These are the interfaces other repos depend on. Changing one = a breaking change: update this section,
keep the old behaviour working until every consumer is updated.

### 5.1 Identity and tokens (auth-service → everyone)
- **IDs:** users and devices have **UUIDv7** ids (strings in JSON).
- **Access token:** JWT signed **EdDSA (Ed25519)**, valid **15 minutes**, sent as `Authorization: Bearer <token>`.
  Header has `kid` = the RFC 7638 thumbprint of the Ed25519 public key.
  Claims: `iss="auth-service"`, `sub=<user_id>`, `did=<device_id>`, `iat`, `exp`, `jti`.
- **Public keys (live):** `GET /auth/.well-known/jwks.json` (in the cluster: `http://auth:8000/auth/.well-known/jwks.json`),
  served with `Cache-Control: public, max-age=300`. Consumers fetch and cache it; on an unknown `kid`, refetch once.
  It holds the current key, plus the previous one during a rotation.
- **Key rotation:** put the new private key in `JWT_PRIVATE_KEY` and the old public key in `JWT_PREVIOUS_PUBLIC_KEY`
  (both in Secret `auth-jwt`), deploy; remove `JWT_PREVIOUS_PUBLIC_KEY` 20 minutes after the deploy
  (15 min token lifetime + 5 min JWKS cache).
- **Refresh token:** opaque, only for `POST /auth/token/refresh`; never sent to other services.
- **Revocation:** a signed-out device's access token stays valid up to 15 min. chat-service additionally
  checks a Redis set of revoked device ids when a socket connects (planned).

### 5.2 WebSocket session (app ↔ chat-service)
- Connect to `wss://<host>/ws`, then send `{"type":"auth","token":"<access token>"}` within 5 s, or the
  server closes the socket. Tokens never go in the URL (URLs end up in logs).
- Before the token expires, the app sends a fresh `auth` message on the same socket.

### 5.3 Between chat-service instances (Redis)
- `conn:<device_id>` → pod name of the instance holding that device's socket; TTL refreshed by heartbeat.
- Each instance subscribes to channel `inst:<POD_NAME>`; publishing there means "device X has new messages"
  (notify + pull; the receiver reads the inbox itself).

### 5.4 chat-service's view of devices
- `devices_by_user` (Cassandra) is filled by chat-service when a device connects with a valid token.
  chat-service never reads auth's database.

### 5.5 HTTP API conventions (all services)
- JSON in and out. Errors: `{"error": "<machine_code>", "message": "<human text>"}`; clients branch on `error`.
- Health: `GET /healthz` (Kubernetes probes) and `GET /<prefix>/healthz` (through the ingress).
- Phone numbers are always E.164 (`+972501234567`).

## 6. Conventions every service follows

- **Stack:** Python 3.14, uv, async FastAPI, Pydantic v2; ruff + mypy strict + pytest in CI.
  Async rule: no blocking calls inside `async def` (use async libraries, or `asyncio.to_thread`).
- **Logs:** one JSON object per line on stdout: `ts`, `level`, `logger`, `msg`, `service`, `pod`, later `trace_id`.
  Alloy ships them to Loki (`{app="auth"} | json`). **Never log** OTP codes, tokens, passwords, full phone numbers.
- **Traces:** OpenTelemetry to `alloy.observability.svc:4317` (gRPC) / `:4318` (HTTP); W3C `traceparent` is
  propagated over HTTP, WebSocket and Redis messages (planned).
- **Startup:** retry the first database connection: k3s's NetworkPolicy firewall blocks a brand-new pod for a
  few seconds. Settings come from env vars; `ENVIRONMENT` defaults to `prod`.
- **Secrets:** only from Kubernetes Secrets, committed as SealedSecrets (`SECRETS.md`); never in code or images.
- **IDs:** UUIDv7. **Times:** UTC, `timestamptz` in Postgres.

## 7. Secrets in the cluster (all sealed in `chat-infra/k8s/`)

| Secret | Namespace | Keys | Used by |
|---|---|---|---|
| `auth-db` | default | `DATABASE_URL` | auth-service |
| `auth-otp` | default | `OTP_PEPPER` (32 random bytes, hex) | auth-service: codes are stored as HMAC-SHA256(pepper, phone:code) |
| `auth-sms` | default | `SMS_API_KEY` (Global SMS API key) | auth-service: sending SMS codes (env `GLOBALSMS_API_KEY`) |
| `auth-jwt` | default | `JWT_PRIVATE_KEY` (Ed25519, PEM PKCS#8) (+ `JWT_PREVIOUS_PUBLIC_KEY` during rotation) | auth-service: signs access tokens |
| `chat-db` | default | `CASSANDRA_USERNAME`, `CASSANDRA_PASSWORD` | chat-service (phase 9) |
| `postgres-credentials` | database | `POSTGRES_PASSWORD`, `AUTH_DB_PASSWORD` | Postgres, backup job |
| `cassandra-credentials` | chat-db | `ADMIN_PASSWORD`, `CHAT_APP_PASSWORD` | Cassandra setup/backup |
| `db-backups-s3` | database, chat-db | rclone S3 key for `chat-backups` | backup jobs |
| `object-storage-credentials` | observability | S3 key for logs/traces buckets | Loki, Tempo |

## 8. How a change reaches production

```
service repo: branch → PR (CI: lint, format, types, tests, image build) → merge to main
   → CI pushes ghcr.io/jzviagin-chat-app/<service>:sha-<12> and opens "Deploy <service> sha-…" PR in chat-infra
chat-infra: merge that PR → Argo CD syncs k8s/ (~3 min) → rolling update
```
Infra changes (`k8s/`, `terraform/`) also go through chat-infra PRs; `terraform apply` is run by the owner
from their Mac. Hand-run jobs (setup, schema, restore drills) live in `manual/` and are started with
`kubectl create/apply -f https://raw.githubusercontent.com/jzviagin-chat-app/chat-infra/main/manual/<file>`.

## 9. Where to find more

| Topic | Document |
|---|---|
| Phases, decisions, change log, messaging design, chat data model | `docs/PLAN.md` |
| Postgres: connect, backups, restore | `docs/DATABASE.md` |
| Cassandra: users, tables, backups, restore | `docs/CASSANDRA.md` |
| Logs, traces, metrics, Grafana | `docs/OBSERVABILITY.md` |
| Sealing secrets | `docs/SECRETS.md` |
| auth-service internals | `auth-service/README.md` |
