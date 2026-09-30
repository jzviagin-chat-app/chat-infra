# ---------------------------------------------------------------------------
# Object storage for observability data (Loki logs, Tempo traces).
# The ops node's disk only holds a small write buffer; long-term data lives here.
# Always Free includes a limited amount of Object Storage: retention below keeps
# usage small, and Loki/Tempo are configured to make few API requests.
# ---------------------------------------------------------------------------

data "oci_objectstorage_namespace" "ns" {
  compartment_id = var.tenancy_ocid
}

locals {
  # bucket name => days after which objects are deleted no matter what (safety net;
  # Loki/Tempo delete earlier through their own retention settings)
  observability_buckets = {
    "chat-logs"   = var.logs_bucket_max_days
    "chat-traces" = var.traces_bucket_max_days
  }
  bucket_names_condition = join(", ", [for b in keys(local.observability_buckets) : "target.bucket.name='${b}'"])
}

resource "oci_objectstorage_bucket" "observability" {
  for_each = local.observability_buckets

  compartment_id = local.compartment_id
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = each.key
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  versioning     = "Disabled"
}

# Object Storage needs permission to delete objects for lifecycle rules to work.
resource "oci_identity_policy" "objectstorage_lifecycle" {
  compartment_id = var.tenancy_ocid
  name           = "objectstorage-lifecycle"
  description    = "Lets Object Storage run lifecycle (auto-delete) rules in this region"
  statements     = ["Allow service objectstorage-${var.region} to manage object-family in tenancy"]
}

resource "oci_objectstorage_object_lifecycle_policy" "observability" {
  for_each   = local.observability_buckets
  depends_on = [oci_identity_policy.objectstorage_lifecycle]

  namespace = data.oci_objectstorage_namespace.ns.namespace
  bucket    = oci_objectstorage_bucket.observability[each.key].name

  rules {
    name        = "delete-after-${each.value}-days"
    action      = "DELETE"
    target      = "objects"
    is_enabled  = true
    time_amount = each.value
    time_unit   = "DAYS"
  }
}

# ---------------------------------------------------------------------------
# A dedicated user that can ONLY read/write these buckets (least privilege).
# Its S3-compatible key goes into the cluster as a SealedSecret.
# ---------------------------------------------------------------------------
resource "oci_identity_group" "observability" {
  compartment_id = var.tenancy_ocid
  name           = "observability"
  description    = "Loki/Tempo: read and write the observability buckets only"
}

resource "oci_identity_user" "observability" {
  compartment_id = var.tenancy_ocid
  name           = "observability"
  description    = "Service user for Loki/Tempo object storage access"
  email          = var.observability_user_email
}

resource "oci_identity_user_group_membership" "observability" {
  user_id  = oci_identity_user.observability.id
  group_id = oci_identity_group.observability.id
}

resource "oci_identity_policy" "observability_buckets" {
  compartment_id = var.tenancy_ocid
  name           = "observability-buckets"
  description    = "The observability group may use the observability buckets and nothing else"
  statements = [
    "Allow group ${oci_identity_group.observability.name} to read buckets in tenancy where any {${local.bucket_names_condition}}",
    "Allow group ${oci_identity_group.observability.name} to manage objects in tenancy where any {${local.bucket_names_condition}}",
  ]
}

# S3-compatible access key ("Customer Secret Key"). The secret part is shown only
# once, at creation: it is stored in terraform.tfstate (never commit that file).
resource "oci_identity_customer_secret_key" "observability" {
  user_id      = oci_identity_user.observability.id
  display_name = "loki-tempo"
}

output "s3_endpoint" {
  value = "https://${data.oci_objectstorage_namespace.ns.namespace}.compat.objectstorage.${var.region}.oraclecloud.com"
}

output "s3_region" {
  value = var.region
}

output "s3_access_key_id" {
  value = oci_identity_customer_secret_key.observability.id
}

output "s3_secret_access_key" {
  value     = oci_identity_customer_secret_key.observability.key
  sensitive = true # print with: terraform output -raw s3_secret_access_key
}
