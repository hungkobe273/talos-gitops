# GCS buckets. Bucket access is granted in iam.tf.

# Terraform state (created by hand on 05/11, then imported here).
resource "google_storage_bucket" "tfstate" {
  default_event_based_hold    = false
  deletion_policy             = "DELETE"
  enable_object_retention     = false
  force_destroy               = false
  labels                      = {}
  location                    = "ASIA-SOUTHEAST1"
  name                        = "talos-kvm-tfstate-vtc"
  project                     = var.project
  public_access_prevention    = "enforced"
  requester_pays              = false
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  hierarchical_namespace {
    enabled = false
  }
  soft_delete_policy {
    retention_duration_seconds = 604800
  }
  versioning {
    enabled = true
  }
  lifecycle {
    prevent_destroy = true
  }
}

# Daily offsite bundle from host2 (talos-offsite-*), kept 30 days.
resource "google_storage_bucket" "offsite" {
  default_event_based_hold    = false
  deletion_policy             = "DELETE"
  enable_object_retention     = false
  force_destroy               = false
  labels                      = {}
  location                    = "ASIA-SOUTHEAST1"
  name                        = "talos-kvm-offsite-gcs-vtc"
  project                     = var.project
  public_access_prevention    = "enforced"
  requester_pays              = false
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  hierarchical_namespace {
    enabled = false
  }
  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age                                     = 30
      days_since_custom_time                  = 0
      days_since_noncurrent_time              = 0
      matches_prefix                          = []
      matches_storage_class                   = []
      matches_suffix                          = []
      num_newer_versions                      = 0
      send_age_if_zero                        = false
      send_days_since_custom_time_if_zero     = false
      send_days_since_noncurrent_time_if_zero = false
      send_num_newer_versions_if_zero         = false
      size_above_bytes                        = 0
      size_below_bytes                        = 0
      with_state                              = "ANY"
    }
  }
  soft_delete_policy {
    retention_duration_seconds = 604800
  }
  lifecycle {
    prevent_destroy = true
  }
}

# Velero backups (schedule velero-daily).
resource "google_storage_bucket" "velero" {
  default_event_based_hold    = false
  deletion_policy             = "DELETE"
  enable_object_retention     = false
  force_destroy               = false
  labels                      = {}
  location                    = "ASIA-SOUTHEAST1"
  name                        = "talos-kvm-velero-vtc"
  project                     = var.project
  public_access_prevention    = "enforced"
  requester_pays              = false
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  hierarchical_namespace {
    enabled = false
  }
  soft_delete_policy {
    retention_duration_seconds = 604800
  }
  lifecycle {
    prevent_destroy = true
  }
}
