# Chat App: Project Plan

A WhatsApp-like chat system, built as a learning project and designed so it can scale.
This file is the single source of truth for **what we're building, why, and in what order**.
Update it whenever the plan changes, and push it in the same commit as the change.

---

## 1. Goals and constraints

| Goal | Notes |
|---|---|
| Real-time 1:1 chat first, groups later | Online and typing indicators, delivery ticks |
| Mobile client first | React Native + TypeScript (Expo); web client later |
| Python backend | FastAPI services |
| Ready for later features | Voice memos, video, pictures, end-to-end encryption (E2E), multi-device |
| Scale-ready design | Stateless services, sharded data, horizontal scaling |
| **Costs nothing** | Oracle Cloud Always Free only. Every paid service must have hard caps (see SMS) |

### Working agreements
- Only the owner pushes to `main` in every repo. Deploys happen by merging a PR.
- One step at a time. Explain a phase before building it.
- Every command uses root-anchored paths: `cd "$(git rev-parse --show-toplevel)"` first.
- Every instruction says which machine it runs on (Mac / lb VM / ops VM).
- Never commit `*.tfstate`, `*.tfvars`, `.terraform/` or `sealed-secrets-key-backup*`.
  Run `git status` before every commit.

---

## 2. Repositories (GitHub org `jzviagin-chat-app`, all public)

| Repo | Contents |
|---|---|
| `chat-infra` | Terraform (`terraform/`), Kubernetes manifests watched by Argo CD (`k8s/`, top level only, no subfolders), docs (`docs/`), Sealed Secrets public cert (`sealed-secrets/`) |
| `chat-service` | WebSocket chat service (FastAPI) |
| `auth-service` | Signup/login, OTP, JWT (FastAPI) |
| *(later)* mobile app | Expo / React Native + TypeScript |
| *(later)* `media-service` | Uploads for pictures, voice, video |

### Deploy pipeline (same for every service)
```
push to main (service repo)
  └─ GitHub Actions (ubuntu-24.04-arm runner)
       ├─ build image → ghcr.io/jzviagin-chat-app/<service>:sha-<12 chars>
       └─ open/update PR in chat-infra (branch deploy/<service>) bumping the image tag in k8s/<service>.yaml
owner merges the PR → Argo CD syncs k8s/ → pods roll
```
- Org secret `INFRA_REPO_TOKEN` (fine-grained token with PR rights on chat-infra).
- ghcr packages are public, so the cluster pulls without credentials.

---

## 3. Infrastructure

### 3.1 Cloud: Oracle Cloud Always Free (4 OCPU / 24 GB RAM / 200 GB block storage, ARM)
Terraform (`terraform/`, OCI provider) creates everything. A **free-tier guard**
(`terraform_data` preconditions in `main.tf`) makes `terraform plan` fail if the sizes ever go over
the Always Free limits. A **budget alert** emails `budget_alert_email` if anything costs money.

| Node | Size | k3s role | Runs |
|---|---|---|---|
| `lb` (10.0.0.10, public IP) | 1 OCPU / 6 GB / 50 GB | control plane, label `role=lb` | HAProxy ingress, Argo CD, cert-manager, Sealed Secrets, Redis |
| `worker` ×2 (instance pool) | 1 OCPU / 6 GB / 50 GB each | agent, label `role=worker` | chat-service, auth-service pods |
| `ops` | 1 OCPU / 6 GB / 50 GB | agent, label `role=ops` | Postgres, Cassandra (planned), observability stack |

Total: 4 OCPU / 24 GB / 200 GB, exactly the free limit. **No room for more VMs.**

Network: VCN 10.0.0.0/16, one public subnet, internet gateway. NSGs: `cluster` (all traffic inside the
VCN, plus SSH from `ssh_source_cidr`) and `web` (80/443 to `lb` only).

### 3.2 Platform components
| Component | What it does |
|---|---|
| k3s | Kubernetes (Traefik disabled) |
| HAProxy ingress | Entry point on `lb`, `leastconn` balancing (good for long-lived WebSockets) |
| cert-manager + Let's Encrypt | HTTPS for `jzviagin-chat-app.129-159-150-34.sslip.io`; HTTP redirects to 443 |
| Argo CD | GitOps: deploys everything in `chat-infra/k8s/` |
| Sealed Secrets | Secrets are encrypted offline with `sealed-secrets/pub-cert.pem` (`kubeseal`) and committed safely. The controller key backup lives outside git |
| Redis | On `lb`. Connection registry + pub/sub between chat instances. **Holds only rebuildable state** |

Ingress routes: `/auth` → `auth:8000`, `/` → `chat:8000`.

### 3.3 Object storage (Oracle Object Storage, S3-compatible API)
One least-privilege IAM user per purpose; each can touch only its own buckets.

| Bucket | Used by | IAM user | Lifecycle safety net |
|---|---|---|---|
| `chat-logs` | Loki | `observability` | 14 days |
| `chat-traces` | Tempo | `observability` | 7 days |
| `chat-backups` | Postgres (and later Cassandra) backups | `db-backups` | 14 days |

S3 keys are stored in the cluster as SealedSecrets. Watch monthly **request counts** in the Oracle console
(bucket → Metrics) during the first weeks. The current estimate is ~50k/month.

### 3.4 Observability (namespace `observability`, all on `ops`), see `docs/OBSERVABILITY.md`
```
pods stdout ─► Alloy ─► Loki ─► chat-logs     (7 days)
OTLP traces ─► Alloy :4317/:4318 ─► Tempo ─► chat-traces (3 days)
Prometheus scrapes nodes/pods every 60 s (local disk, 7 days)
Grafana reads all three (reachable only through an SSH tunnel)
```
- Logs: one JSON object per line, with `level`, `msg` and `trace_id`. Never log OTP codes, tokens or full phone numbers.
- Traces: W3C `traceparent` header propagated across HTTP, WebSocket and Redis messages.
- Grafana tunnel (Mac): `ssh -N -o ServerAliveInterval=30 -L 3000:<grafana ClusterIP>:80 ubuntu@129.159.150.34`.

### 3.5 Memory budget on `ops` (6 GB) ⚠️
The `ops` node runs Loki, Tempo, Prometheus, Grafana (1 GiB limit), Alloy, Postgres and Cassandra.
- Cassandra target: ~1.5 GB heap (~2.5 GB container).
- Postgres target: ~512 MB.

Measured on 2026-10-09 with everything running (including Cassandra): `ops` at ~60% (3.5 GB of 5.8 GB).

Before each new database is added, check with `kubectl top node ops`. If it's too tight:
- lower the Cassandra heap to 1 GB, or
- reduce Prometheus retention.

---

## 4. Messaging design (chat-service)

### 4.1 Transport
- The client keeps **one WebSocket** to the server: relay through the server, no peer-to-peer.
- **Push notifications are only a "doorbell".** They wake the app, which then connects and pulls. They never carry the message.
- Typing and online indicators are ephemeral WebSocket events and are never stored.

### 4.2 Per-device inbox (the core idea)
Every **device** has an inbox: an append-only list of messages it hasn't confirmed, ordered by a
**gap-free `inbox_seq`**.
- The client stores messages in local SQLite, keeps a **cursor** (last seq it persisted), then sends a
  **cumulative ack** ("I have everything up to N"). Persist first, ack second.
- Dedup by `msg_id` (client-generated UUID), so retries are always safe.
- Reconnect = "give me everything after my cursor".

### 4.3 Send flow
```
sender ──ws──► chat instance A (ingress)
   A: write message into each recipient device's inbox (Cassandra)
   A: ack sender  ✓  (server has it)
   A: look up conn:<device> in Redis → instance B
   A: PUBLISH inst:<B> "device X has new messages"
   B: (notify + pull) read inbox after sent_up_to[X], push over ws
recipient device: persist → ack ✓✓ (delivered)
```
- **Coalescing:** each instance keeps in memory `sent_up_to` for each connected device. Many notifications
  become one read.
- **Registry:** `conn:<device_id>` → pod name, with a TTL refreshed by a heartbeat. Each instance subscribes
  to its own channel `inst:<POD_NAME>`.
- **If Redis is lost**, nothing breaks permanently. Clients reconnect, the registry rebuilds itself, and inboxes are in the DB.
- **Multi-device:** users → devices. A message fans out to every recipient device **and** the sender's
  other devices.

### 4.4 Later: commit log
Redpanda (Kafka API) as a pipeline partitioned by `conv_id`, for fan-out workers and push-notification
workers. A plain queue doesn't fit per-device mailboxes. The log feeds the inbox writers; it doesn't replace them.

---

## 5. Data storage decisions

| Data | Store | Why |
|---|---|---|
| Users, devices, phone numbers, OTP attempts, refresh tokens | **Postgres** (auth DB) | Relational, transactional, small, needs unique constraints |
| Device inboxes, chat lists, conversation members, **message history** | **Cassandra** (chat DB) | High write throughput, eventual consistency is fine, reads by key, deletes are rare, scales out by adding nodes |
| Connection registry, pub/sub | **Redis** | Ephemeral and rebuildable |
| Media files *(later)* | Object storage | Large blobs; the DB stores only references |

**Why Cassandra and not ScyllaDB:** ScyllaDB became source-available (free only up to 50 vCPU / 10 TB;
the last open-source release is 6.2.x). Cassandra is Apache 2.0. Both speak CQL, so switching later is
cheap if ever needed.

**Why not Postgres for chat:** the inbox workload (append, read once, expire) creates constant deletes
and vacuum pressure, and scaling writes means manual sharding. Cassandra handles append + TTL natively
(with TimeWindowCompactionStrategy, whole expired files are dropped, so tombstones don't pile up).

Each service owns its own database. No service reads another service's DB.

### 5.1 Chat data model
The final tables are in `manual/cassandra-schema.yaml` and described in `docs/CASSANDRA.md`. On top of the
sketch below they add `device_inbox_seq` and `conversation_seq` (number counters) and `devices_by_user`
(chat-service's own list of each user's devices, so it never reads auth's database).
```sql
-- Per-device inbox: append + cursor + bulk expiry
CREATE TABLE inbox_by_device (
  device_id  uuid,
  inbox_seq  bigint,
  msg_id     uuid,
  conv_id    uuid,
  sender_id  uuid,
  payload    blob,          -- ciphertext once E2E exists
  created_at timestamp,
  PRIMARY KEY ((device_id), inbox_seq)
) WITH default_time_to_live = 2592000           -- 30 days for offline devices
  AND compaction = {'class': 'TimeWindowCompactionStrategy',
                    'compaction_window_unit': 'DAYS', 'compaction_window_size': 1};

-- Chat list ("my conversations"), per user
CREATE TABLE user_conversations (
  user_id uuid, conv_id uuid, kind text, title text, joined_at timestamp,
  PRIMARY KEY ((user_id), conv_id)
);

-- Members of a conversation (used for fan-out)
CREATE TABLE conversation_members (
  conv_id uuid, user_id uuid, role text, joined_at timestamp,
  PRIMARY KEY ((conv_id), user_id)
);

-- Server-side history, bucketed by month so no partition grows forever
CREATE TABLE messages_by_conversation (
  conv_id uuid, month_bucket int,  -- e.g. 202610
  seq bigint, msg_id uuid, sender_id uuid, payload blob, created_at timestamp,
  PRIMARY KEY ((conv_id, month_bucket), seq)
) WITH CLUSTERING ORDER BY (seq DESC);
```
Rules:
- **All writes are idempotent.** Retrying with the same key overwrites with the same value.
- The ack cursor lives on the device. Inbox rows simply expire; nothing deletes them one by one.
- **Decided (phase 6): numbers come from lightweight transactions (LWT)** on a per-device / per-conversation
  counter row: "set from N to N+1 only if it is still N, else retry".
  - Benchmark on this cluster: 287 numbers/s with 20 writers on 20 devices (median 66 ms); 43/s with 20 writers
    on one device; 0 duplicates, 0 gaps.
  - If the one-busy-device case ever matters: queue each device's numbering inside a chat-service process.
    Fallback: option B, a single owner per device that allocates in memory (same tables).
  - **Reader rule:** a number can be handed out slightly before its message is written. So a device advances its
    cursor only over numbers with nothing missing below. If a hole stays for longer than a few seconds, skip it:
    its writer died, and the sender (not yet acked ✓) resends with the same `msg_id`.
- Optional later: archive old history months to object storage.
- Under E2E the server stores only ciphertext. Restoring history on a new device needs a key-backup
  design (later).

---

## 6. Auth design (auth-service)

- **Signup / login with SMS OTP:**
  - phone → OTP → verify → account + device registration.
  - Codes are hashed, short-lived (≈5 min), max ~5 attempts.
- **SMS provider:** Twilio, prepaid through **PayPal only** (no credit card). Hard spending protection:
  - Auto-recharge **off**, and the PayPal automatic-payment authorisation cancelled after topping up.
  - SMS geo permissions: **Israel only**.
  - A global daily SMS cap in our code, plus per-phone and per-IP rate limits (stored in Postgres/Redis).
  - **Development: a fake SMS sender** that logs a masked notice, with the code readable only in dev. Costs ₪0.
- **Tokens:**
  - Short-lived access JWT (≈15 min), signed with an asymmetric key. Public keys are published at `/auth/.well-known/jwks.json`, so chat-service verifies locally.
  - Refresh tokens are opaque and stored hashed. They **rotate on every use**, and reuse revokes the whole family.
- **Device keypair:** each device generates a keypair and registers its public key. This is the base for E2E and multi-device later.
- **Observability:** JSON logs with `trace_id`, OpenTelemetry traces to Alloy, Prometheus metrics. Phone numbers are always masked in logs.
- **Later:** device attestation (Play Integrity / App Attest) against SMS pumping.

---

## 7. Phases

| # | Phase | Status |
|---|---|---|
| 0 | Local HAProxy + WebSocket playground (docker-compose) | ✅ done |
| 0b | Oracle VCN, VMs, Terraform, k3s cluster (lb + 2 workers), service repos, CI → ghcr → deploy PR → Argo CD | ✅ done |
| 0c | Redis on the cluster (registry + pub/sub infra only) | ✅ done |
| 1 | HTTPS: cert-manager, Let's Encrypt, sslip.io host, HTTP→HTTPS redirect | ✅ done |
| 2 | Sealed Secrets (offline `kubeseal` with `pub-cert.pem`) | ✅ done |
| 3 | `ops` node | ✅ done |
| 4 | Observability: buckets + IAM user (Terraform), Loki, Tempo, Prometheus, Grafana, Alloy | ✅ done (verify objects appear in `chat-logs`; watch request counts) |
| 5 | Postgres for auth + nightly backups | ✅ done (restore drill passed) |
| 6 | Cassandra for chat | ✅ done (restore drill passed) |
| **7** | **Production auth-service** | ⏳ next |
| 8 | Dummy Expo app (signup flow) | ⏳ |
| 9 | Real chat-service messaging | ⏳ |
| 10+ | Later items (section 8) | ⏳ |

### Phase 5: Postgres for auth + backups ✅
How to use it: `docs/DATABASE.md`.
1. Terraform `backups.tf`:
   - bucket `chat-backups` (14-day lifecycle),
   - IAM group, user and policy `db-backups` (this bucket only),
   - S3 key outputs `backups_access_key_id` / `backups_secret_access_key`.

   New variables: `backups_user_email` and `backups_max_days`.
2. Namespace `database`, with a Postgres 17 StatefulSet pinned to `ops` (local-path volume 5Gi, 768 MB memory limit).
3. SealedSecrets:
   - `postgres-credentials` (superuser),
   - `auth-db` (DB `auth`, user `auth`, connection URL for auth-service),
   - `db-backups-s3` (bucket key).
4. NetworkPolicy: only auth-service pods and the backup job can reach Postgres on port 5432.
5. Nightly CronJob (03:30 Asia/Jerusalem): `pg_dumpall` | gzip → `rclone` → `chat-backups/postgres/`.
   Restore drill `manual/postgres-restore-test.yaml` (run by hand; `manual/` is not watched by Argo CD).
   It passed on 2026-10-08.
   - Lesson: k3s's network-policy firewall blocks a brand-new pod for a few seconds. Anything that connects at
     startup must retry (the backup job waits up to 60 s; auth-service must too).
6. Docs: `docs/DATABASE.md` (connect, backup, restore).

### Phase 6: Cassandra for chat ✅
How to use it: `docs/CASSANDRA.md`.
1. Cassandra 5.0.9 on `ops` (namespace `chat-db`), 1.5 GB heap, datacenter `dc1`, replication 1 for now.
2. Password login on. Users:
   - `admin` (superuser);
   - `chat_app` (read/write on `chat` only).

   The built-in `cassandra` user is disabled. A NetworkPolicy lets in only chat pods and `chat-db` pods.
3. 7 tables (`manual/cassandra-schema.yaml`). Numbering decided: LWT (section 5.1, with benchmark).
4. Backups: a sidecar in the Cassandra pod. At 00:45 UTC it runs `nodetool snapshot` → tar.gz → `chat-backups/cassandra/`.
   - Lesson: rclone copied into another image needs the CA certificate list too (`SSL_CERT_FILE`).
5. Restore drill (`manual/cassandra-restore-test.yaml`): restores into a temporary Cassandra on a worker and checks a test row.

### Phase 7: Production auth-service
- Schema migrations with Alembic. DB connection retries at startup (see the phase 5 lesson).
- Endpoints: `request-otp`, `verify-otp`, `refresh`, `logout`, device registration, `jwks`.
- Fake SMS sender in dev; the Twilio adapter is behind a flag and isn't switched on until the guards from section 6 are in place.
- Rate limits, JSON logs, OTel traces, metrics, unit tests.

### Phase 8: Dummy Expo app
- Phone entry → OTP → token storage (secure store) → a "hello" screen that calls an authenticated endpoint.
- Proves the end-to-end trace from app → ingress → auth → Postgres in Grafana.

### Phase 9: Real chat-service
- JWT validation through JWKS.
- WebSocket session, the Redis registry and heartbeat, `inst:<POD_NAME>` subscription.
- Inbox writes, acks, notify + pull with coalescing, typing/online events, history reads.
- Message numbers via LWT; the device's cursor only advances over numbers with nothing missing below (section 5.1).
- Fill `devices_by_user` when a device connects with a valid token. Retry the first Cassandra connection
  (new pods are blocked for a few seconds).
- Client side: SQLite store, cursor, cumulative acks.

---

## 8. Later (not scheduled yet)
- **Before any public launch:** a real domain behind Cloudflare (free plan) for DDoS protection, HAProxy rate
  limits, and connection caps.
- Push notifications (FCM / APNs) as the doorbell.
- Redpanda commit log, fan-out and push workers.
- Groups (fan-out through `conversation_members`).
- Multi-device sync.
- E2E encryption (Signal-protocol style; server stores ciphertext only).
- Media service: pictures, voice memos, video, stored in object storage with presigned URLs.
- Web client.
- Ops hygiene:
  - Ubuntu updates with node reboots, one node at a time (drain → reboot → uncordon).
  - Monitoring object-storage request counts.
  - Alerting in Grafana.
- Autoscaling of pods. Node autoscaling and migration to AWS are only for if we ever leave the free tier.

---

## 9. Change log
| Date | Change |
|---|---|
| 2026-10-08 | First version of this plan. Decided: Postgres for auth only; Cassandra for all chat data including server-side history. Phase 5 rescoped to auth DB + backups; new phase 6 for Cassandra. |
| 2026-10-08 | Phase 5 done: Postgres on ops, NetworkPolicy, nightly `pg_dumpall` backup to `chat-backups`, restore drill passed. Added `docs/DATABASE.md` and the `manual/` folder for hand-run jobs. |
| 2026-10-09 | Phase 6 done: Cassandra 5.0.9 on ops, users + NetworkPolicy, 7 chat tables, numbering decided (LWT, benchmarked), nightly snapshot backup sidecar, restore drill passed. Added `docs/CASSANDRA.md`. |
