# Cassandra (chat data)

One Cassandra 5.0 node on the `ops` node, namespace `chat-db`. Holds all chat data: device inboxes,
chat lists, conversation members and message history. Used only by chat-service.
(Auth data is in Postgres; see DATABASE.md.)

```
chat pods (namespace default) ──► cassandra.chat-db.svc.cluster.local:9042 ──► data on ops disk (local-path, 10Gi)
                                        │
cassandra-0 pod: [cassandra] + [backup sidecar] ── 00:45 UTC nightly: snapshot ─► tar.gz ─► chat-backups/cassandra/ (14 days)
```

| What | Where |
|---|---|
| Server + backup sidecar + NetworkPolicy | `k8s/chat-db-cassandra.yaml` (StatefulSet `cassandra`) |
| Backup scripts | `k8s/chat-db-cassandra-backup.yaml` (ConfigMap `cassandra-backup-scripts`) |
| Passwords | `k8s/chat-db-cassandra-credentials-sealed.yaml` → Secret `chat-db/cassandra-credentials` (`ADMIN_PASSWORD`, `CHAT_APP_PASSWORD`) |
| chat-service credentials | `k8s/chat-db-sealed.yaml` → Secret `default/chat-db` (`CASSANDRA_USERNAME`, `CASSANDRA_PASSWORD`) |
| Bucket key for backups | `k8s/chat-db-db-backups-s3-sealed.yaml` → Secret `chat-db/db-backups-s3` |
| One-time setup (users, keyspace) | `manual/cassandra-setup.yaml` |
| Tables | `manual/cassandra-schema.yaml` |
| Numbering benchmark | `manual/cassandra-seq-bench.yaml` |
| Restore drill | `manual/cassandra-restore-test.yaml` |

`manual/` files are never run by Argo CD. Run them by hand from the lb VM. Each file's header has the commands.
Files with a ConfigMap inside (schema, bench) use `kubectl apply -f`; the others use `kubectl create -f`.
To run one again, delete its finished pod first: `kubectl -n chat-db delete pod <name>`.

## Settings
- Cluster `chat`, datacenter `dc1` (GossipingPropertyFileSnitch), keyspace `chat` with replication `dc1: 1`.
  When more nodes are added: raise to 3 and run a repair.
- Heap 1.5 GB, direct memory 512 MB, container limit 2.5 GiB. Takes ~1.5 min to start on 1 OCPU.
- Password login on. The built-in `cassandra` user is disabled.

## Users
| User | Can do | Used by |
|---|---|---|
| `admin` | everything (superuser) | setup, schema, backups' restore checks, you |
| `chat_app` | SELECT + MODIFY on keyspace `chat` only | chat-service |

## Who can connect
A NetworkPolicy allows only pods labelled `app=chat` in namespace `default`, plus pods in `chat-db`.
⚠️ Brand-new pods are blocked for their first few seconds: clients must retry the first connection.

## Connect (lb VM)
```bash
PW=$(kubectl -n chat-db get secret cassandra-credentials -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d)
kubectl -n chat-db exec -it cassandra-0 -c cassandra -- cqlsh -u admin -p "$PW"
```
Useful: `DESCRIBE KEYSPACE chat;`, `SELECT * FROM chat.<table> LIMIT 10;`, `exit`.

## Tables (keyspace `chat`)
| Table | Key | Notes |
|---|---|---|
| `inbox_by_device` | device → inbox_seq | 30-day TTL + TimeWindowCompaction: rows expire, nothing deletes them one by one |
| `device_inbox_seq` | device | last inbox number handed out (lightweight transactions) |
| `messages_by_conversation` | (conversation, month) → seq desc | full history |
| `conversation_seq` | conversation | last history number handed out |
| `user_conversations` | user → conversation | chat list |
| `conversation_members` | conversation → user | fan-out |
| `devices_by_user` | user → device | which devices to deliver to (filled by chat-service) |

**Change the schema:** add new statements at the END of `schema.cql` in `manual/cassandra-schema.yaml`
(`ALTER TABLE …`, `CREATE TABLE IF NOT EXISTS …`). Never edit or remove old ones. Push, then run the schema pod.

## Message numbers (decided in phase 6)
Numbers come from lightweight transactions: "set the counter from N to N+1 only if it is still N, else retry".
Benchmark on this cluster: 287 numbers/s with 20 writers on 20 devices (median 66 ms), 43/s with 20 writers
fighting over one device, 0 duplicates. Rule for readers: a number can be handed out slightly before its
message is written, so devices advance their cursor only over numbers with nothing missing below.

## Backups
The `backup` container in the `cassandra-0` pod sleeps until **00:45 UTC** and then:
`nodetool snapshot` (instant hard links) → tar.gz streamed to `chat-backups/cassandra/cassandra-chat-<UTC time>.tar.gz`
→ the snapshot is deleted. The bucket deletes files older than 14 days.
```bash
kubectl -n chat-db logs cassandra-0 -c backup                          # past runs (BACKUP OK / BACKUP FAILED)
kubectl -n chat-db exec cassandra-0 -c backup -- /scripts/backup.sh    # run one now
```
Harmless lines: `WARNING: package jdk.internal…`, rclone's `Config file … not found`.

## Restore drill (after any change to Cassandra or the backup)
Restores the newest backup into a temporary Cassandra inside a throwaway pod on a worker node. The real Cassandra is never touched.
```bash
PW=$(kubectl -n chat-db get secret cassandra-credentials -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d)
# 1. test row
kubectl -n chat-db exec cassandra-0 -c cassandra -- cqlsh -u admin -p "$PW" -e \
  "INSERT INTO chat.conversation_members (conv_id, user_id, role) VALUES (00000000-0000-0000-0000-000000000001, 00000000-0000-0000-0000-000000000001, 'restore-test')"
# 2. backup
kubectl -n chat-db exec cassandra-0 -c backup -- /scripts/backup.sh
# 3. restore test (2-4 minutes), must end with RESTORE TEST OK
kubectl -n chat-db delete pod cassandra-restore-test --ignore-not-found
kubectl create -f https://raw.githubusercontent.com/jzviagin-chat-app/chat-infra/main/manual/cassandra-restore-test.yaml
kubectl -n chat-db logs -f cassandra-restore-test -c restore
# 4. remove the test row
kubectl -n chat-db exec cassandra-0 -c cassandra -- cqlsh -u admin -p "$PW" -e \
  "DELETE FROM chat.conversation_members WHERE conv_id = 00000000-0000-0000-0000-000000000001"
```

## Real restore (data lost)
Only when the live data is actually lost or corrupted. This follows the same steps as the drill script, but against the live node:
1. Stop writers: `kubectl -n default scale deploy/chat --replicas=0`
2. Download the backup to the lb VM, then copy it into the pod:
   `kubectl -n chat-db cp cassandra-chat-<time>.tar.gz cassandra-0:/tmp/ -c cassandra`
3. In the pod (`kubectl -n chat-db exec -it cassandra-0 -c cassandra -- bash`): extract it in `/tmp`.
   If a table is missing, create it with the `schema.cql` in its folder. Then load each table:
   `chown -R cassandra:cassandra /tmp/chat && env -u MAX_HEAP_SIZE nodetool import chat <table> /tmp/chat/<table>-<id>/snapshots/<tag>/`
4. Check with cqlsh. Then start writers again: `kubectl -n default scale deploy/chat --replicas=2`

If the ops node is lost: Terraform recreates the VM and Argo CD recreates Cassandra (empty). Then run the setup and schema pods, and do steps 1–4.

## Troubleshooting
```bash
kubectl -n chat-db get pods -o wide
kubectl -n chat-db logs cassandra-0 -c cassandra --tail=50
kubectl -n chat-db exec cassandra-0 -c cassandra -- nodetool status      # UN = up/normal
kubectl -n chat-db describe pod cassandra-0 | tail -30                    # OOMKilled? probe failures?
kubectl top node ops
```
- **Stuck `0/2`/`1/2` for >10 min**: check the cassandra log. A cluster name or datacenter change after the first start is refused.
- **`Unable to lock JVM memory (ENOMEM)`**: harmless (no swap on these VMs).
- **Stopping shows `Error`**: harmless, Cassandra exits non-zero on SIGTERM.
- **Password changes**: Cassandra refuses two password changes for the same user within 5 seconds.
- **rclone `x509: certificate signed by unknown authority`**: `SSL_CERT_FILE` / the certificate copy in the `get-rclone` init container.
