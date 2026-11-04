# Existing resources, inventoried read-only on 04/11.
# Stage 1 (06/11): terraform plan -generate-config-out=generated.tf
# writes a resource block for every import below that has none yet; then split
# generated.tf into compute.tf, network.tf, storage.tf, iam.tf, kms.tf,
# schedule.tf and add lifecycle { prevent_destroy = true } where the plan says.
# Done when plan shows "No changes".
#
# Not imported: SA talos-velero-drill (deleted after the drill), Compute default
# SA, snapshots made by cicd-daily-snap, budgets (billing account), legacy
# project-level bucket roles (convenience bindings GCS adds by itself).

# --- Compute ---------------------------------------------------------------

import {
  to = google_compute_instance.w3
  id = "${local.p}/zones/${var.zone}/instances/w3"
}

import {
  to = google_compute_instance.jenkins_1
  id = "${local.p}/zones/${var.zone}/instances/jenkins-1"
}

import {
  to = google_compute_instance.gitlab_1
  id = "${local.p}/zones/${var.zone}/instances/gitlab-1"
}

import {
  to = google_compute_address.jenkins_ip
  id = "${local.p}/regions/${var.region}/addresses/jenkins-ip"
}

import {
  to = google_compute_address.gitlab_ip
  id = "${local.p}/regions/${var.region}/addresses/gitlab-ip"
}

import {
  to = google_compute_image.talos_v1_14_2
  id = "${local.p}/global/images/talos-v1-14-2"
}

# --- Network ---------------------------------------------------------------

import {
  to = google_compute_firewall.default_allow_icmp
  id = "${local.p}/global/firewalls/default-allow-icmp"
}

import {
  to = google_compute_firewall.default_allow_internal
  id = "${local.p}/global/firewalls/default-allow-internal"
}

import {
  to = google_compute_firewall.default_allow_ssh
  id = "${local.p}/global/firewalls/default-allow-ssh"
}

import {
  to = google_compute_firewall.talos_w3_apid
  id = "${local.p}/global/firewalls/talos-w3-apid"
}

import {
  to = google_compute_firewall.talos_w3_kubespan
  id = "${local.p}/global/firewalls/talos-w3-kubespan"
}

# --- Schedules -------------------------------------------------------------

import {
  to = google_compute_resource_policy.jenkins_office_hours
  id = "${local.p}/regions/${var.region}/resourcePolicies/jenkins-office-hours"
}

import {
  to = google_compute_resource_policy.cicd_daily_snap
  id = "${local.p}/regions/${var.region}/resourcePolicies/cicd-daily-snap"
}

import {
  to = google_cloud_scheduler_job.w3_stop_mon_wed
  id = "${local.p}/locations/${var.region}/jobs/w3-stop-mon-wed"
}

# --- Storage ---------------------------------------------------------------

import {
  to = google_storage_bucket.tfstate
  id = "talos-kvm-tfstate-vtc"
}

import {
  to = google_storage_bucket.offsite
  id = "talos-kvm-offsite-gcs-vtc"
}

import {
  to = google_storage_bucket.velero
  id = "talos-kvm-velero-vtc"
}

# --- Identity --------------------------------------------------------------

import {
  to = google_service_account.talos_backup_writer
  id = "${local.p}/serviceAccounts/talos-backup-writer@${local.sa}"
}

import {
  to = google_service_account.talos_velero
  id = "${local.p}/serviceAccounts/talos-velero@${local.sa}"
}

import {
  to = google_service_account.vault_unseal
  id = "${local.p}/serviceAccounts/vault-unseal@${local.sa}"
}

import {
  to = google_service_account.w3_stopper
  id = "${local.p}/serviceAccounts/w3-stopper@${local.sa}"
}

import {
  to = google_project_iam_custom_role.velero_object_store
  id = "${local.p}/roles/veleroObjectStore"
}

import {
  to = google_project_iam_custom_role.w3_stopper
  id = "${local.p}/roles/w3Stopper"
}

# IAM: additive *_iam_member only, never *_iam_policy or *_iam_binding.
# Import id = "<resource> <role> <member>".

import {
  to = google_storage_bucket_iam_member.offsite_backup_writer
  id = "b/talos-kvm-offsite-gcs-vtc roles/storage.objectCreator serviceAccount:talos-backup-writer@${local.sa}"
}

import {
  to = google_storage_bucket_iam_member.velero_object_store
  id = "b/talos-kvm-velero-vtc ${local.p}/roles/veleroObjectStore serviceAccount:talos-velero@${local.sa}"
}

import {
  to = google_kms_crypto_key_iam_member.vault_unseal_encrypter
  id = "${local.key_id} roles/cloudkms.cryptoKeyEncrypterDecrypter serviceAccount:vault-unseal@${local.sa}"
}

import {
  to = google_kms_crypto_key_iam_member.vault_unseal_viewer
  id = "${local.key_id} roles/cloudkms.viewer serviceAccount:vault-unseal@${local.sa}"
}

import {
  to = google_compute_instance_iam_member.w3_stopper
  id = "${local.p}/zones/${var.zone}/instances/w3 ${local.p}/roles/w3Stopper serviceAccount:w3-stopper@${local.sa}"
}

# --- KMS (key rings can never be deleted in GCP) ---------------------------

import {
  to = google_kms_key_ring.talos_vault
  id = "${local.p}/locations/${var.region}/keyRings/talos-vault"
}

import {
  to = google_kms_crypto_key.vault_unseal
  id = local.key_id
}

# --- Cloud SQL (STOPPED, kept on request) ----------------------------------

import {
  to = google_sql_database_instance.talos_kc_test
  id = "${local.p}/instances/talos-kc-test"
}
