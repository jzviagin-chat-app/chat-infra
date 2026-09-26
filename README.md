# chat-infra

Terraform + k3s on Oracle Cloud Always Free:

```
                 internet
                    │ :80 / :443
┌───────────────────▼──────────────────┐
│ chat-lb        1 OCPU / 6 GB         │  k3s server (control plane)
│ 10.0.0.10      public IP             │  HAProxy ingress (leastconn, 1h tunnel timeout)
│                                      │  Argo CD (deploys whatever k8s/ in this repo says)
└───────────────────┬──────────────────┘
        private network 10.0.0.0/24
┌───────────────────┴──┐   ┌───────────────────────┐
│ chat-worker (pool)   │   │ chat-worker (pool)    │  k3s agents
│ 1 OCPU / 6 GB        │   │ 1 OCPU / 6 GB         │  chat pods run here
└──────────────────────┘   └───────────────────────┘
```

Total: 3 of 4 OCPU, 18 of 24 GB RAM, 150 of 200 GB disk.

```
terraform/            infrastructure (network, firewall, VMs, budget alert)
  cloud-init/         first-boot scripts: server.yaml (LB VM), agent.yaml (workers)
k8s/                  what runs on the cluster. Argo CD applies this folder automatically.
```

The app itself lives in [jzviagin-chat-app/chat-service](https://github.com/jzviagin-chat-app/chat-service).

## How a change reaches the cluster

```
push to chat-service main
  → GitHub Actions: build Arm image → ghcr.io/jzviagin-chat-app/chat-service:sha-<commit>
  → opens a PR here: "Deploy chat-service sha-<commit>" (changes the tag in k8s/chat.yaml)
  → you merge it (the merge IS the deploy)
  → Argo CD notices the change (~3 min) → rolling update, one pod at a time
```

Rollback = revert the merge commit here. Anything you change under `k8s/` (replicas, resources…)
is deployed the same way: commit to main, Argo CD applies it. Manual `kubectl` changes to these
resources get reverted by Argo CD (self-heal): git is the source of truth.

---

## Free tier safety

Several layers keep this free:

1. **Keep your account on the Free Tier.** Don't click "Upgrade to Pay As You Go". A Free Tier
   account cannot be billed; anything that isn't Always Free simply fails to create.
   (During the first 30 days, trial credits *can* be spent on paid resources. That is credit,
   not your card, but it's another reason to use only what this code creates.)
2. **The Terraform code only creates Always Free resources:** the `VM.Standard.A1.Flex` shape
   (hard-coded, not a variable), a VCN with an internet gateway, security groups, and boot
   volumes at the minimum size. It creates no managed load balancer, no NAT gateway and no extra
   block volumes.
3. **A built-in guard:** `terraform plan` fails *before creating anything* if the total goes above
   4 OCPU, 24 GB RAM or 200 GB of disk (for example `worker_count = 4`).
4. **A budget alert:** an email if actual spend ever goes above 1% of a budget of 1 (in your
   account's currency).
5. **Always read `terraform plan`** before typing `yes`. It lists every resource it will create.

---

## Step 0: Delete what you created by hand

The manual VM uses 2 OCPU and 50 GB. With it still running, the new setup doesn't fit the free limits.

1. Compute → Instances → your VM → **Terminate**, and tick **permanently delete the attached boot volume**.
2. Networking → Virtual cloud networks → your VCN → **Delete** (it deletes its subnets and gateways too).

## Step 1: Tools on your Mac

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform kubectl
terraform -version
```

## Step 2: An API key, so Terraform can act on your account

1. Oracle console → top-right profile icon → **My profile** → **API keys** → **Add API key**.
2. Choose **Generate API key pair** → **Download private key** → **Add**.
3. The console shows a **configuration file preview**. Copy it into `~/.oci/config` on your Mac:
   ```bash
   mkdir -p ~/.oci
   mv ~/Downloads/*.pem ~/.oci/oci_api_key.pem
   chmod 600 ~/.oci/oci_api_key.pem
   nano ~/.oci/config        # paste the preview, then set: key_file=~/.oci/oci_api_key.pem
   ```
   It looks like:
   ```
   [DEFAULT]
   user=ocid1.user.oc1..aaaa...
   fingerprint=12:34:...
   tenancy=ocid1.tenancy.oc1..aaaa...
   region=eu-frankfurt-1
   key_file=~/.oci/oci_api_key.pem
   ```

## Step 3: Create the infrastructure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars        # region + tenancy from ~/.oci/config, and your email
terraform init
terraform plan               # read it: VCN, subnet, gateway, NSGs, 1 instance, 1 pool, budget
terraform apply              # type "yes"
```

At the end it prints `lb_public_ip`, `ssh_lb` and `websocket_url`.

**Out of host capacity?** Set `availability_domain_index = 1` (or 2) in `terraform.tfvars` and run
`terraform apply` again. Some regions have only one availability domain; then just retry later.

## Step 4: Check the cluster formed (about 3–5 minutes after apply)

```bash
ssh ubuntu@<lb_public_ip>
sudo cloud-init status --wait     # waits for the first-boot script to finish
kubectl get nodes -o wide         # expect 3 nodes, all Ready (1 lb + 2 workers)
kubectl get pods -A               # haproxy-controller pod should be Running
```

If a worker is missing, SSH to it through the LB and check its log:
```bash
ssh -J ubuntu@<lb_public_ip> ubuntu@<worker_private_ip>   # private IPs: kubectl get nodes -o wide,
sudo tail -50 /var/log/cloud-init-output.log              #   or the Instance Pool page in the console
```

## Step 5: Put this folder in the chat-infra repo

```bash
cd chat-infra                      # the folder from the zip (with README.md, terraform/, k8s/)
git init -b main
git remote add origin https://github.com/jzviagin-chat-app/chat-infra.git
git add . && git commit -m "Initial infra: Terraform + k3s + Argo CD"
git push -u origin main
```

`.gitignore` keeps `terraform.tfstate` and `terraform.tfvars` out of git. Check with `git status`
before the first commit that neither is listed.

Argo CD starts syncing `k8s/` right away. The chat pods will show `ImagePullBackOff` until the
first image exists (next step); that's expected.

## Step 6: Set up chat-service (see its README)

Create the `chat-service` repo, add the `INFRA_REPO_TOKEN` secret, push. The pipeline builds the
image and opens a **"Deploy chat-service sha-…"** PR here. Merge it.

## Step 7: Watch it deploy, then test

```bash
ssh ubuntu@<lb_public_ip>
kubectl get pods -o wide -w        # chat pods go Running, one per worker (Ctrl+C to stop)
```

From your Mac:
```bash
npx wscat -c ws://<lb_public_ip>/ws
# connected to chat-7d9c...-abcde on inst-...   (pod name on worker VM name)
```

**Argo CD dashboard** (shows every resource, its version and health):
```bash
ssh -L 8080:localhost:8080 ubuntu@<lb_public_ip> \
  'kubectl -n argocd port-forward $(kubectl -n argocd get svc -l app.kubernetes.io/component=server -o name) 8080:80'
# open http://localhost:8080, user: admin, password:
ssh ubuntu@<lb_public_ip> 'kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo'
```

## Protect main (both repos)

The repos are public, but only people with write access can push; everyone else can only fork and
open PRs. In the `jzviagin-chat-app` organization, keep that to just you:
- Organization → Settings → Member privileges → **Base permissions: Read**, and don't give anyone
  write access or add outside collaborators to these repos.
- Settings → Rules → Rulesets → **New branch ruleset** → target: default branch → enable
  **Restrict deletions** and **Block force pushes** → Active.
- Settings → Actions → General → **Fork pull request workflows**: require approval for all
  outside contributors. (PRs from forks never get your secrets anyway.)

## Experiments

| Try | How | What happens |
|---|---|---|
| Kill a pod | `kubectl delete pod <chat-pod>` (on the LB VM) | Its sockets drop; k3s starts a replacement within seconds |
| Scale pods | edit `replicas: 4` in `k8s/chat.yaml`, commit, push | Argo CD applies it: 2 more pods, spread across the workers |
| Drain a node (on the LB VM) | `kubectl drain <worker> --ignore-daemonsets` | Pods move to the other worker, one at a time (PodDisruptionBudget) |
| Undo the drain | `kubectl uncordon <worker>` | The node accepts pods again |
| Lose a VM | Console → terminate a worker instance | The instance pool should launch a replacement to keep its size; the new VM joins by itself |
| Add a worker | `worker_count = 3` in tfvars → `terraform apply` | Uses exactly the 4 OCPU / 24 GB / 200 GB allowance |

## Tear down

```bash
terraform destroy
```

This removes everything; `terraform apply` rebuilds it identically.

---

## Notes

- **Firewall:** the cloud firewall is the network security groups in `main.tf`. SSH is open to all by
  default; set `ssh_source_cidr = "<your ip>/32"` to lock it down (`curl ifconfig.me`). Only the LB
  VM accepts ports 80/443. The Kubernetes API (6443) is reachable only inside the VCN.
- **The k3s join token** is generated by Terraform and stored in `terraform.tfstate`. Never commit
  `terraform.tfstate` or `terraform.tfvars` to git.
- **Idle reclaim:** Oracle may reclaim Always Free VMs that stay almost idle for 7 days.
- **Still plain `ws://`:** TLS (`wss://`) and auth come before any real chat code is deployed.
