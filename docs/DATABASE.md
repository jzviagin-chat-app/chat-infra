# Database (Postgres for auth)

One Postgres 17 instance on the `ops` node, namespace `database`. Used only by auth-service.
Chat data will live in Cassandra (see PLAN.md), not here.

```
auth pods (namespace default) ──► postgres.database.svc.cluster.local:5432 ──► data on ops disk (local-path, 5Gi)
                                         │
CronJob postgres-backup (03:30 Asia/Jerusalem) ── pg_dumpall | gzip ──► bucket chat-backups/postgres/  (deleted after 14 days)
```

| What | Where |
|---|---|
| Server | `k8s/database-postgres.yaml` (StatefulSet `postgres`, Service, NetworkPolicy, first-start script) |
| Passwords | `k8s/database-postgres-credentials-sealed.yaml` → Secret `database/postgres-credentials` (`POSTGRES_PASSWORD`, `AUTH_DB_PASSWORD`) |
| auth-service connection string | `k8s/auth-db-sealed.yaml` → Secret `default/auth-db` (`DATABASE_URL`) |
| Backup job | `k8s/database-postgres-backup.yaml` (CronJob `postgres-backup`) |
| Bucket key for backups | `k8s/database-db-backups-s3-sealed.yaml` → Secret `database/db-backups-s3` (from `terraform/backups.tf`) |
| Restore drill | `manual/postgres-restore-test.yaml` (run by hand, never by Argo CD) |

Databases and users:
- `postgres`: superuser, for admin work and backups only.
- `auth`: owns database `auth`, and nothing else. auth-service uses this one.

The `auth` user and database are created by a script that runs only on the very first start
(empty data folder). Changing `AUTH_DB_PASSWORD` later does not change the password inside Postgres:
see "Change a password" below.

## Who can connect
A NetworkPolicy allows only:
- pods labelled `app=auth` in namespace `default`, and
- pods in namespace `database` (the backup job).

Everything else gets "connection refused".

⚠️ **New pods are blocked for their first few seconds** while k3s's firewall catches up. Anything that
connects at startup must retry (the backup job waits up to 60 s; auth-service must retry too).

## Connect (lb VM)
```bash
# psql as the admin user
kubectl -n database exec -it postgres-0 -- psql -U postgres

# psql as the auth user, into the auth database
kubectl -n database exec -it postgres-0 -- sh -c 'PGPASSWORD=$AUTH_DB_PASSWORD psql -h 127.0.0.1 -U auth -d auth'
```
Useful psql commands: `\l` databases, `\du` users, `\dt` tables, `\q` quit.

## Read the passwords (lb VM)
```bash
kubectl -n database get secret postgres-credentials -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d; echo
kubectl -n database get secret postgres-credentials -o jsonpath='{.data.AUTH_DB_PASSWORD}' | base64 -d; echo
kubectl -n default  get secret auth-db              -o jsonpath='{.data.DATABASE_URL}'      | base64 -d; echo
```

## Backups
Every night at 03:30 Israel time, the CronJob dumps **all** databases and users (`pg_dumpall`), gzips the
dump, and uploads it to `chat-backups/postgres/postgres-<UTC date>.sql.gz`. The bucket deletes files
older than 14 days.

```bash
# status of recent runs
kubectl -n database get cronjob postgres-backup
kubectl -n database get jobs

# run one now
kubectl -n database create job --from=cronjob/postgres-backup backup-manual-$(date +%s)
kubectl -n database logs job/<job name> -c dump
kubectl -n database logs job/<job name> -c upload     # ends with the list of files in the bucket
```
The `NOTICE: Config file ... not found` line from rclone is harmless (its settings come from env vars).

## Restore drill (do it after any change to Postgres or the backup job)
Loads the newest backup into a temporary Postgres **inside a throwaway pod**. The real database is never touched.
```bash
kubectl create -f https://raw.githubusercontent.com/jzviagin-chat-app/chat-infra/main/manual/postgres-restore-test.yaml
kubectl -n database get pod postgres-restore-test -w          # wait for Completed
kubectl -n database logs postgres-restore-test -c restore     # must end with RESTORE TEST OK
kubectl -n database delete pod postgres-restore-test
```
Locale warnings (`locale: not found`, `no usable system locales`) are harmless.

## Real restore (disaster: data lost or corrupted)
Only when the live data is actually lost or corrupted. It overwrites the live database.
1. Stop writers: `kubectl -n default scale deploy/auth --replicas=0`
2. Pick a backup in the Oracle console (Storage → Buckets → chat-backups → postgres/), or list them
   with the upload log above.
3. Copy it into the Postgres pod and load it (lb VM). `--clean` in the dump drops and recreates the databases:
   ```bash
   # download on your Mac from the Oracle console, then:
   scp postgres-<date>.sql.gz ubuntu@<lb_public_ip>:
   kubectl -n database cp postgres-<date>.sql.gz postgres-0:/tmp/restore.sql.gz
   kubectl -n database exec postgres-0 -- sh -c 'gunzip -c /tmp/restore.sql.gz | psql -U postgres -d postgres'
   kubectl -n database exec postgres-0 -- rm /tmp/restore.sql.gz
   ```
4. Check: `kubectl -n database exec postgres-0 -- psql -U postgres -c '\l'`
5. Start writers again: `kubectl -n default scale deploy/auth --replicas=2`

If the whole `ops` node is lost: Terraform recreates the VM and Argo CD recreates Postgres, which starts empty.
Then do steps 1–5.

## Change a password
1. Change it inside Postgres (lb VM):
   `kubectl -n database exec -it postgres-0 -- psql -U postgres -c "ALTER ROLE auth PASSWORD '<new>'"`
2. Re-seal `postgres-credentials` and `auth-db` with the new value (see SECRETS.md), commit, push.
3. Restart auth-service: `kubectl -n default rollout restart deploy/auth`

## Troubleshooting
```bash
kubectl -n database get pods -o wide
kubectl -n database logs postgres-0 --tail=50
kubectl -n database exec postgres-0 -- pg_isready -h 127.0.0.1
kubectl -n database get endpoints postgres         # empty = Postgres not ready
kubectl top node ops                               # memory on the shared ops node
```
- **"connection refused" from a pod:** check the NetworkPolicy (right namespace and labels?). For a brand-new pod,
  retry after a few seconds.
- **Backup job `Init:Error`:** `kubectl -n database logs job/<name> -c dump`.
- **Upload fails** with `AccessDenied` / `SignatureDoesNotMatch`: the `db-backups-s3` key, or the policy in
  `terraform/backups.tf`.
