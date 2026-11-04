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

locals {
  p      = "projects/${var.project}"
  sa     = "${var.project}.iam.gserviceaccount.com"
  key_id = "${local.p}/locations/${var.region}/keyRings/talos-vault/cryptoKeys/vault-unseal"
}
