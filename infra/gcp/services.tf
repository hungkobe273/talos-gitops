# APIs the lab uses. disable_on_destroy = false: removing a line here only stops
# Terraform tracking the API, it never turns the API off.
locals {
  services = toset([
    "billingbudgets.googleapis.com",
    "cloudkms.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "cloudscheduler.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sqladmin.googleapis.com",
    "storage.googleapis.com",
  ])
}

resource "google_project_service" "this" {
  for_each           = local.services
  service            = each.value
  disable_on_destroy = false
}

import {
  for_each = local.services
  to       = google_project_service.this[each.value]
  id       = "${var.project}/${each.value}"
}
