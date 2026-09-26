locals {
  # The only Always Free Arm shape. Deliberately not a variable.
  shape = "VM.Standard.A1.Flex"

  vcn_cidr      = "10.0.0.0/16"
  subnet_cidr   = "10.0.0.0/24"
  lb_private_ip = "10.0.0.10" # fixed, so workers know where to join

  compartment_id = var.tenancy_ocid
  ad_name        = data.oci_identity_availability_domains.ads.availability_domains[var.availability_domain_index].name
  ssh_key        = file(pathexpand(var.ssh_public_key_path))

  total_ocpus     = var.lb_ocpus + var.worker_count * var.worker_ocpus
  total_memory_gb = var.lb_memory_gb + var.worker_count * var.worker_memory_gb
  total_disk_gb   = (1 + var.worker_count) * var.boot_volume_gb
}

# ---------------------------------------------------------------------------
# Free-tier guard: `terraform plan` fails before anything is created if the
# requested sizes exceed the Always Free allowance.
# ---------------------------------------------------------------------------
resource "terraform_data" "free_tier_guard" {
  lifecycle {
    precondition {
      condition     = local.total_ocpus <= 4
      error_message = "Total OCPUs would be ${local.total_ocpus}; Always Free allows 4."
    }
    precondition {
      condition     = local.total_memory_gb <= 24
      error_message = "Total memory would be ${local.total_memory_gb} GB; Always Free allows 24 GB."
    }
    precondition {
      condition     = local.total_disk_gb <= 200
      error_message = "Total boot volumes would be ${local.total_disk_gb} GB; Always Free allows 200 GB."
    }
  }
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

# Latest Ubuntu 24.04 build for the Arm shape.
data "oci_core_images" "ubuntu" {
  compartment_id           = local.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = local.shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

# ---------------------------------------------------------------------------
# Network: VCN, internet gateway, route, one public subnet
# ---------------------------------------------------------------------------
resource "oci_core_vcn" "main" {
  compartment_id = local.compartment_id
  cidr_blocks    = [local.vcn_cidr]
  display_name   = "chat-vcn"
  dns_label      = "chatvcn"
}

resource "oci_core_internet_gateway" "igw" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "chat-igw"
  enabled        = true
}

resource "oci_core_route_table" "public" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "chat-public-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}

# Subnet-level list only allows outbound traffic; all inbound rules live in the
# per-VM network security groups below (these map 1:1 to AWS security groups).
resource "oci_core_security_list" "egress_only" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "chat-egress-only"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }
}

resource "oci_core_subnet" "public" {
  compartment_id             = local.compartment_id
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = local.subnet_cidr
  display_name               = "chat-public-subnet"
  dns_label                  = "public"
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.egress_only.id]
  prohibit_public_ip_on_vnic = false
}

# ---------------------------------------------------------------------------
# Network security groups
# ---------------------------------------------------------------------------

# Every VM: SSH from you, anything from inside the VCN (k3s node-to-node traffic).
resource "oci_core_network_security_group" "cluster" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "chat-cluster-nsg"
}

resource "oci_core_network_security_group_security_rule" "cluster_internal" {
  network_security_group_id = oci_core_network_security_group.cluster.id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = local.vcn_cidr
  source_type               = "CIDR_BLOCK"
}

resource "oci_core_network_security_group_security_rule" "cluster_ssh" {
  network_security_group_id = oci_core_network_security_group.cluster.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = var.ssh_source_cidr
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cluster_egress" {
  network_security_group_id = oci_core_network_security_group.cluster.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}

# LB VM only: web traffic from the internet.
resource "oci_core_network_security_group" "web" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "chat-web-nsg"
}

resource "oci_core_network_security_group_security_rule" "web" {
  for_each = toset(["80", "443"])

  network_security_group_id = oci_core_network_security_group.web.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = tonumber(each.value)
      max = tonumber(each.value)
    }
  }
}

# ---------------------------------------------------------------------------
# LB VM: k3s server (control plane) + HAProxy ingress
# ---------------------------------------------------------------------------
resource "oci_core_instance" "lb" {
  depends_on = [terraform_data.free_tier_guard]

  compartment_id      = local.compartment_id
  availability_domain = local.ad_name
  display_name        = "chat-lb"
  shape               = local.shape

  shape_config {
    ocpus         = var.lb_ocpus
    memory_in_gbs = var.lb_memory_gb
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = true
    private_ip       = local.lb_private_ip
    hostname_label   = "lb"
    nsg_ids = [
      oci_core_network_security_group.cluster.id,
      oci_core_network_security_group.web.id,
    ]
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_gb
  }

  metadata = {
    ssh_authorized_keys = local.ssh_key
    user_data = base64encode(templatefile("${path.module}/cloud-init/server.yaml", {
      k3s_token      = random_password.k3s_token.result
      vcn_cidr       = local.vcn_cidr
      haproxy_values = file("${path.module}/cloud-init/haproxy-ingress.yaml")
      argocd_values  = file("${path.module}/cloud-init/argocd.yaml")
      argocd_apps = templatefile("${path.module}/cloud-init/argocd-apps.yaml", {
        gitops_repo_url = var.gitops_repo_url
      })
    }))
  }

  lifecycle {
    # A newer Ubuntu image must not silently replace the running VM.
    ignore_changes = [source_details[0].source_id, metadata]
  }
}

# ---------------------------------------------------------------------------
# Workers: a template (instance configuration) + a pool of N copies.
# Later, a node autoscaler only has to change the pool size.
# ---------------------------------------------------------------------------
resource "oci_core_instance_configuration" "worker" {
  compartment_id = local.compartment_id
  display_name   = "chat-worker-template"

  instance_details {
    instance_type = "compute"

    launch_details {
      compartment_id = local.compartment_id
      shape          = local.shape

      shape_config {
        ocpus         = var.worker_ocpus
        memory_in_gbs = var.worker_memory_gb
      }

      create_vnic_details {
        subnet_id        = oci_core_subnet.public.id
        assign_public_ip = true # needed to download k3s and images; no inbound web ports are open
        nsg_ids          = [oci_core_network_security_group.cluster.id]
      }

      source_details {
        source_type             = "image"
        image_id                = data.oci_core_images.ubuntu.images[0].id
        boot_volume_size_in_gbs = var.boot_volume_gb
      }

      metadata = {
        ssh_authorized_keys = local.ssh_key
        user_data = base64encode(templatefile("${path.module}/cloud-init/agent.yaml", {
          k3s_token = random_password.k3s_token.result
          server_ip = local.lb_private_ip
          vcn_cidr  = local.vcn_cidr
        }))
      }
    }
  }

  lifecycle {
    ignore_changes = [instance_details[0].launch_details[0].source_details[0].image_id]
  }
}

resource "oci_core_instance_pool" "workers" {
  depends_on = [terraform_data.free_tier_guard, oci_core_instance.lb]

  compartment_id            = local.compartment_id
  instance_configuration_id = oci_core_instance_configuration.worker.id
  size                      = var.worker_count
  display_name              = "chat-workers"

  placement_configurations {
    availability_domain = local.ad_name
    primary_subnet_id   = oci_core_subnet.public.id
  }
}

# ---------------------------------------------------------------------------
# Budget alert: emails you if actual spend ever goes above 1 (in your
# account's currency). Budgets themselves are free.
# ---------------------------------------------------------------------------
resource "oci_budget_budget" "guard" {
  compartment_id = var.tenancy_ocid
  amount         = 1
  reset_period   = "MONTHLY"
  target_type    = "COMPARTMENT"
  targets        = [var.tenancy_ocid]
  display_name   = "free-tier-guard"
}

resource "oci_budget_alert_rule" "any_spend" {
  budget_id      = oci_budget_budget.guard.id
  type           = "ACTUAL"
  threshold      = 1
  threshold_type = "PERCENTAGE"
  recipients     = var.budget_alert_email
  display_name   = "any-spend"
  message        = "Your Oracle Cloud account has started costing money. Check Billing > Cost Analysis."
}
