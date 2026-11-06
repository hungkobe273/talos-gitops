variable "project" {
  type    = string
  default = "project-df6719af-b37c-4a54-b3b"
}

variable "region" {
  type    = string
  default = "asia-southeast1"
}

variable "zone" {
  type    = string
  default = "asia-southeast1-b"
}

# Set in terraform.tfvars (gitignored, see terraform.tfvars.example): this repo is public.
variable "office_cidrs" {
  description = "Office egress CIDRs allowed to SSH, Talos apid, KubeSpan and Cloud SQL"
  type        = list(string)
}

variable "admin_ssh_keys" {
  description = "Value of the ssh-keys metadata on jenkins-1 and gitlab-1 (user:key lines)"
  type        = string
}

data "google_project" "this" {}

locals {
  p          = "projects/${var.project}"
  sa         = "${var.project}.iam.gserviceaccount.com"
  key_id     = "${local.p}/locations/${var.region}/keyRings/talos-vault/cryptoKeys/vault-unseal"
  api        = "https://www.googleapis.com/compute/v1"
  network    = "${local.api}/${local.p}/global/networks/default"
  subnetwork = "${local.api}/${local.p}/regions/${var.region}/subnetworks/default"
  compute_sa = "${data.google_project.this.number}-compute@developer.gserviceaccount.com"
}
