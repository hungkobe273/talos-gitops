# Vault auto-unseal key. GCP never deletes key rings; destroying a key only
# schedules its versions for deletion after 30 days, and Vault cannot unseal without it.

resource "google_kms_key_ring" "talos_vault" {
  location = var.region
  name     = "talos-vault"
  project  = var.project
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key" "vault_unseal" {
  deletion_policy            = "DELETE"
  destroy_scheduled_duration = "2592000s"
  import_only                = false
  key_ring                   = google_kms_key_ring.talos_vault.id
  labels                     = {}
  name                       = "vault-unseal"
  purpose                    = "ENCRYPT_DECRYPT"
  version_template {
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
    protection_level = "SOFTWARE"
  }
  lifecycle {
    prevent_destroy = true
  }
}
