# chat-infra — Claude Code context

This repo is the **hub** of the chat system: Terraform for Oracle Cloud (`terraform/`), everything that runs on
the k3s cluster (`k8s/`, applied automatically by Argo CD), hand-run jobs (`manual/`), and **the system docs
(`docs/`), which every other repo loads at session start**.

## System design (source of truth — loaded below)
@docs/ARCHITECTURE.md
@docs/PLAN.md

Other docs, read when relevant: `docs/DATABASE.md`, `docs/CASSANDRA.md`, `docs/OBSERVABILITY.md`, `docs/SECRETS.md`.

## Working with the owner
- The owner is learning; explain the why, give trade-offs, and **don't guess** UI layouts or facts — say
  when unsure. One step at a time; do only what was asked; explain a phase before building it.
- `main` is protected: work on a branch, open a PR; the owner merges (or asks you to).
- Commands for the owner: root-anchored (`cd "$(git rev-parse --show-toplevel)"`), and always say which machine
  (Mac / lb VM / ops VM). Never commit `*.tfstate`, `*.tfvars`, `.terraform/`, `sealed-secrets-key-backup*`.

## Repo rules
- `k8s/` is flat (no subfolders); every file there is live once merged. Image tags in `k8s/auth.yaml` and
  `k8s/chat.yaml` are bumped by the services' CI ("Deploy … sha-…" PRs) — don't change them by hand.
- Secrets only as SealedSecrets, sealed offline with `sealed-secrets/pub-cert.pem` (`docs/SECRETS.md`).
- Terraform is applied by the owner from their Mac; keep the free-tier guard in `main.tf` intact.

## Keeping the design current
When a change alters anything described in `docs/ARCHITECTURE.md` or decided in `docs/PLAN.md`, update them in
the same branch and add a row to the PLAN.md change log. Run `/sync-design` before finishing a task.
