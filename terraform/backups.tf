# ---------------------------------------------------------------------------
# Database backups: a bucket for nightly pg_dump files, and a user that can use
# ONLY this bucket (separate from the observability user: least privilege).
# ---------------------------------------------------------------------------

resource "oci_objectstorage_bucket" "backups" {
  compartment_id = local.compartment_id
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = "chat-backups"
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  versioning     = "Disabled"
}

resource "oci_objectstorage_object_lifecycle_policy" "backups" {
  depends_on = [oci_identity_policy.objectstorage_lifecycle]

  namespace = data.oci_objectstorage_namespace.ns.namespace
  bucket    = oci_objectstorage_bucket.backups.name

  rules {
    name        = "delete-after-${var.backups_max_days}-days"
    action      = "DELETE"
    target      = "objects"
    is_enabled  = true
    time_amount = var.backups_max_days
    time_unit   = "DAYS"
  }
}

resource "oci_identity_group" "backups" {
  compartment_id = var.tenancy_ocid
  name           = "db-backups"
  description    = "Postgres backup job: read and write the chat-backups bucket only"
}

resource "oci_identity_user" "backups" {
  compartment_id = var.tenancy_ocid
  name           = "db-backups"
  description    = "Service user for the nightly Postgres backup job"
  email          = var.backups_user_email
}

resource "oci_identity_user_group_membership" "backups" {
  user_id  = oci_identity_user.backups.id
  group_id = oci_identity_group.backups.id
}

resource "oci_identity_policy" "backups" {
  compartment_id = var.tenancy_ocid
  name           = "db-backups-bucket"
  description    = "The db-backups group may use the chat-backups bucket and nothing else"
  statements = [
    "Allow group ${oci_identity_group.backups.name} to read buckets in tenancy where target.bucket.name='${oci_objectstorage_bucket.backups.name}'",
    "Allow group ${oci_identity_group.backups.name} to manage objects in tenancy where target.bucket.name='${oci_objectstorage_bucket.backups.name}'",
  ]
}

resource "oci_identity_customer_secret_key" "backups" {
  user_id      = oci_identity_user.backups.id
  display_name = "postgres-backup"
}

output "backups_access_key_id" {
  value = oci_identity_customer_secret_key.backups.id
}

output "backups_secret_access_key" {
  value     = oci_identity_customer_secret_key.backups.key
  sensitive = true # print with: terraform output -raw backups_secret_access_key
}
