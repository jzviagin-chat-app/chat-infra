variable "oci_profile" {
  description = "Profile name in ~/.oci/config"
  type        = string
  default     = "DEFAULT"
}

variable "region" {
  description = "Your home region identifier, e.g. eu-frankfurt-1 (see ~/.oci/config)"
  type        = string
}

variable "tenancy_ocid" {
  description = "Tenancy OCID (the 'tenancy=' line in ~/.oci/config). Also used as the root compartment."
  type        = string
}

variable "ssh_public_key_path" {
  description = "Public key installed on every VM"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_source_cidr" {
  description = "Who may SSH to the VMs. Put your own IP here as x.x.x.x/32 to lock it down."
  type        = string
  default     = "0.0.0.0/0"
}

variable "availability_domain_index" {
  description = "0, 1 or 2. Change this if you get 'Out of host capacity'."
  type        = number
  default     = 0
}

variable "worker_count" {
  description = "Number of chat worker VMs"
  type        = number
  default     = 2
}

variable "budget_alert_email" {
  description = "Email that gets an alert if anything ever costs money"
  type        = string
}

# Sizes. The free-tier guard in main.tf rejects any combination over the Always Free limits.
variable "lb_ocpus" {
  type    = number
  default = 1
}

variable "lb_memory_gb" {
  type    = number
  default = 6
}

variable "worker_ocpus" {
  type    = number
  default = 1
}

variable "worker_memory_gb" {
  type    = number
  default = 6
}

variable "boot_volume_gb" {
  description = "Per VM. 50 is the minimum; keep it there, the free tier has 200 GB in total."
  type        = number
  default     = 50
}

variable "ops_ocpus" {
  type    = number
  default = 1
}

variable "ops_memory_gb" {
  type    = number
  default = 6
}

variable "observability_user_email" {
  description = "Email for the 'observability' service user (Oracle requires one). A plus-address like you+observability@gmail.com works."
  type        = string
}

variable "logs_bucket_max_days" {
  description = "Safety net: log objects older than this are deleted by the bucket itself"
  type        = number
  default     = 14
}

variable "traces_bucket_max_days" {
  description = "Safety net: trace objects older than this are deleted by the bucket itself"
  type        = number
  default     = 7
}

variable "gitops_repo_url" {
  description = "Repo Argo CD watches; everything under its k8s/ folder is deployed to the cluster"
  type        = string
  default     = "https://github.com/jzviagin-chat-app/chat-infra.git"
}
