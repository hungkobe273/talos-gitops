# Service accounts, custom roles and grants. Grants are *_iam_member only:
# *_iam_policy / *_iam_binding replace every member of a role and can drop Owner.
# Keys for these SAs are not managed here (they would end up in the state).

resource "google_service_account" "talos_backup_writer" {
  account_id      = "talos-backup-writer"
  deletion_policy = "DELETE"
  disabled        = false
  display_name    = "host2 backup upload (create only)"
  project         = var.project
}

resource "google_service_account" "talos_velero" {
  account_id      = "talos-velero"
  deletion_policy = "DELETE"
  disabled        = false
  display_name    = "Velero, only bucket talos-kvm-velero-vtc"
  project         = var.project
}

resource "google_service_account" "vault_unseal" {
  account_id      = "vault-unseal"
  deletion_policy = "DELETE"
  disabled        = false
  display_name    = "Vault auto-unseal (talos-kvm)"
  project         = var.project
}

resource "google_service_account" "w3_stopper" {
  account_id      = "w3-stopper"
  deletion_policy = "DELETE"
  disabled        = false
  display_name    = "Cloud Scheduler: stop w3 at 11:30 Mon/Wed"
  project         = var.project
}

resource "google_project_iam_custom_role" "velero_object_store" {
  deletion_policy = "DELETE"
  permissions     = ["storage.objects.create", "storage.objects.delete", "storage.objects.get", "storage.objects.list"]
  project         = var.project
  role_id         = "veleroObjectStore"
  stage           = "GA"
  title           = "Velero object store"
}

resource "google_project_iam_custom_role" "w3_stopper" {
  deletion_policy = "DELETE"
  permissions     = ["compute.instances.stop"]
  project         = var.project
  role_id         = "w3Stopper"
  stage           = "GA"
  title           = "Stop w3 only"
}

# host2 can add objects to the offsite bucket but not read, overwrite or delete them.
resource "google_storage_bucket_iam_member" "offsite_backup_writer" {
  bucket = "b/${google_storage_bucket.offsite.name}"
  member = "serviceAccount:${google_service_account.talos_backup_writer.email}"
  role   = "roles/storage.objectCreator"
}

resource "google_storage_bucket_iam_member" "velero_object_store" {
  bucket = "b/${google_storage_bucket.velero.name}"
  member = "serviceAccount:${google_service_account.talos_velero.email}"
  role   = google_project_iam_custom_role.velero_object_store.id
}

resource "google_kms_crypto_key_iam_member" "vault_unseal_encrypter" {
  crypto_key_id = google_kms_crypto_key.vault_unseal.id
  member        = "serviceAccount:${google_service_account.vault_unseal.email}"
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
}

resource "google_kms_crypto_key_iam_member" "vault_unseal_viewer" {
  crypto_key_id = google_kms_crypto_key.vault_unseal.id
  member        = "serviceAccount:${google_service_account.vault_unseal.email}"
  role          = "roles/cloudkms.viewer"
}

# The scheduler SA may stop w3 and nothing else.
resource "google_compute_instance_iam_member" "w3_stopper" {
  instance_name = "${local.p}/zones/${var.zone}/instances/${google_compute_instance.w3.name}"
  member        = "serviceAccount:${google_service_account.w3_stopper.email}"
  project       = var.project
  role          = google_project_iam_custom_role.w3_stopper.id
  zone          = var.zone
}
