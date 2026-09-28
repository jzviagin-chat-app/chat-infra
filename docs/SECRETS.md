# Secrets

Secrets live in git **encrypted**, as `SealedSecret` files in `k8s/`. Only the Sealed Secrets
controller in the cluster can decrypt them. Encrypting (sealing) happens on your Mac with the
cluster's public certificate, `sealed-secrets/pub-cert.pem` (safe to commit: it can only encrypt).

The **original values** belong in your password manager. That's the source of truth.

## One-time setup (after the controller is running)

On the LB VM:
```bash
# 1. Public certificate (for sealing)
kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o jsonpath='{.items[0].data.tls\.crt}' | base64 -d > pub-cert.pem

# 2. Private key BACKUP (can decrypt every secret: never commit it)
kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-key-backup.yaml
```

On your Mac:
```bash
brew install kubeseal
scp ubuntu@<lb_public_ip>:pub-cert.pem chat-infra/sealed-secrets/pub-cert.pem
scp ubuntu@<lb_public_ip>:sealed-secrets-key-backup.yaml ~/Documents/
ssh ubuntu@<lb_public_ip> 'rm sealed-secrets-key-backup.yaml'
```
Store `sealed-secrets-key-backup.yaml` in your password manager (as an attachment) or an
encrypted disk, then delete the loose copy.

## Seal a secret

From the `chat-infra` folder on your Mac (`--dry-run=client` means kubectl never contacts a cluster):
```bash
kubectl create secret generic <name> --namespace default \
  --from-literal=<KEY>=<value> [--from-literal=<KEY2>=<value2> ...] \
  --dry-run=client -o yaml \
| kubeseal --cert sealed-secrets/pub-cert.pem --format yaml > k8s/<name>-sealed.yaml

git add k8s/<name>-sealed.yaml && git commit -m "Add <name> secret" && git push
```
Argo CD applies it and the controller creates a normal Secret `<name>`, which pods use as env vars:
```yaml
env:
  - name: DATABASE_PASSWORD
    valueFrom:
      secretKeyRef:
        name: <name>
        key: <KEY>
```
A sealed secret is bound to its name and namespace: renaming the file's secret breaks it; re-seal instead.

**To change a value:** seal again with the new value (same name), commit, push.
Pods read env vars at startup, so restart them afterwards: `kubectl rollout restart deploy/<app>`.

**Tip:** your shell history records `--from-literal` values. Prefix the command with a space
(zsh ignores it with `setopt HIST_IGNORE_SPACE`), or use `--from-file=<KEY>=path` instead.

## Moving to a new cluster (any provider)

1. New cluster + Argo CD (Terraform does both), pointed at this repo.
2. Restore the key, then restart the controller so it picks it up:
   ```bash
   kubectl apply -f sealed-secrets-key-backup.yaml
   kubectl -n kube-system delete pod -l app.kubernetes.io/name=sealed-secrets
   ```
3. All SealedSecrets in git decrypt as before. No re-sealing.

**Without the key backup:** fetch the new cluster's `pub-cert.pem` and re-seal every secret from
the values in your password manager.
