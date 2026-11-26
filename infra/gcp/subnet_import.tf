import {
  to = google_compute_subnetwork.default_sea
  id = "${local.p}/regions/${var.region}/subnetworks/default"
}

# Default subnet of asia-southeast1 (w3, jenkins-1). Imported 26/11 to turn on
# VPC Flow Logs while debugging w3 KubeSpan; set flow_logs = false afterwards.
resource "google_compute_subnetwork" "default_sea" {
  name                       = "default"
  ip_cidr_range              = "10.148.0.0/20"
  network                    = local.network
  project                    = var.project
  region                     = var.region
  private_ip_google_access   = false
  private_ipv6_google_access = "DISABLE_GOOGLE_ACCESS"
  purpose                    = "PRIVATE"
  stack_type                 = "IPV4_ONLY"

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 1.0
    metadata             = "INCLUDE_ALL_METADATA"
  }

  lifecycle {
    prevent_destroy = true
  }
}
