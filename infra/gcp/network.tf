# Firewall rules on the default network. Office CIDRs come from var.office_cidrs.

resource "google_compute_firewall" "default_allow_icmp" {
  deletion_policy = "DELETE"
  description     = "Allow ICMP from anywhere"
  direction       = "INGRESS"
  disabled        = false
  name            = "default-allow-icmp"
  network         = local.network
  priority        = 65534
  project         = var.project
  source_ranges   = ["0.0.0.0/0"]
  allow {
    ports    = []
    protocol = "icmp"
  }
}

resource "google_compute_firewall" "default_allow_internal" {
  deletion_policy = "DELETE"
  description     = "Allow internal traffic on the default network"
  direction       = "INGRESS"
  disabled        = false
  name            = "default-allow-internal"
  network         = local.network
  priority        = 65534
  project         = var.project
  source_ranges   = ["10.128.0.0/9"]
  allow {
    ports    = ["0-65535"]
    protocol = "tcp"
  }
  allow {
    ports    = ["0-65535"]
    protocol = "udp"
  }
  allow {
    ports    = []
    protocol = "icmp"
  }
}

# Description says "anywhere" but the source was narrowed to the office earlier.
resource "google_compute_firewall" "default_allow_ssh" {
  deletion_policy = "DELETE"
  description     = "Allow SSH from anywhere"
  direction       = "INGRESS"
  disabled        = false
  name            = "default-allow-ssh"
  network         = local.network
  priority        = 65534
  project         = var.project
  source_ranges   = var.office_cidrs
  allow {
    ports    = ["22"]
    protocol = "tcp"
  }
}

# Talos API on w3, reached by talosctl from host2 through the office uplink.
resource "google_compute_firewall" "talos_w3_apid" {
  deletion_policy = "DELETE"
  direction       = "INGRESS"
  disabled        = false
  name            = "talos-w3-apid"
  network         = local.network
  priority        = 1000
  project         = var.project
  source_ranges   = var.office_cidrs
  target_tags     = ["talos-w3"]
  allow {
    ports    = ["50000"]
    protocol = "tcp"
  }
}

# KubeSpan (WireGuard) between the on-prem nodes and w3.
resource "google_compute_firewall" "talos_w3_kubespan" {
  deletion_policy = "DELETE"
  direction       = "INGRESS"
  disabled        = false
  name            = "talos-w3-kubespan"
  network         = local.network
  priority        = 1000
  project         = var.project
  source_ranges   = var.office_cidrs
  target_tags     = ["talos-w3"]
  allow {
    ports    = ["51820"]
    protocol = "udp"
  }
}
