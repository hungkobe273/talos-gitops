# VMs, reserved IPs and the Talos image. Imported 06/11 from the live project
# (generated with plan -generate-config-out, then cleaned by hand).

resource "google_compute_instance" "w3" {
  can_ip_forward      = false
  deletion_policy     = "DELETE"
  deletion_protection = false
  enable_display      = false
  labels              = {}
  machine_type        = "e2-standard-2"
  metadata            = {}
  name                = "w3"
  project             = var.project
  resource_policies   = [google_compute_resource_policy.jenkins_office_hours.self_link]
  tags                = ["talos-w3"]
  zone                = var.zone
  boot_disk {
    auto_delete       = true
    device_name       = "persistent-disk-0"
    force_attach      = false
    guest_os_features = ["VIRTIO_SCSI_MULTIQUEUE"]
    mode              = "READ_WRITE"
    source            = "${local.api}/${local.p}/zones/${var.zone}/disks/w3"
    initialize_params {
      enable_confidential_compute = false
      image                       = google_compute_image.talos_v1_14_2.self_link
      labels                      = {}
      provisioned_iops            = 0
      provisioned_throughput      = 0
      replica_zones               = []
      resource_manager_tags       = {}
      resource_policies           = []
      size                        = 50
      type                        = "pd-balanced"
    }
  }
  network_interface {
    internal_ipv6_prefix_length = 0
    network                     = local.network
    network_ip                  = "10.148.0.4"
    queue_count                 = 0
    stack_type                  = "IPV4_ONLY"
    subnetwork                  = local.subnetwork
    subnetwork_project          = var.project
    # Ephemeral public IP: changes on every stop/start, so nat_ip is not pinned here.
    access_config {
      network_tier = "PREMIUM"
    }
  }
  scheduling {
    automatic_restart          = true
    availability_domain        = 0
    host_error_timeout_seconds = 0
    min_node_cpus              = 0
    on_host_maintenance        = "MIGRATE"
    preemptible                = false
    provisioning_model         = "STANDARD"
  }
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_instance" "jenkins_1" {
  can_ip_forward      = false
  deletion_policy     = "DELETE"
  deletion_protection = false
  enable_display      = false
  labels              = {}
  machine_type        = "e2-medium"
  metadata = {
    ssh-keys = var.admin_ssh_keys
  }
  name              = "jenkins-1"
  project           = var.project
  resource_policies = [google_compute_resource_policy.jenkins_office_hours.self_link]
  tags              = []
  zone              = var.zone
  boot_disk {
    auto_delete       = true
    device_name       = "persistent-disk-0"
    force_attach      = false
    guest_os_features = ["UEFI_COMPATIBLE", "VIRTIO_SCSI_MULTIQUEUE", "GVNIC", "SEV_CAPABLE", "SEV_LIVE_MIGRATABLE_V2", "SUSPEND_SAFE_FPR"]
    mode              = "READ_WRITE"
    source            = "${local.api}/${local.p}/zones/${var.zone}/disks/jenkins-1"
    initialize_params {
      architecture                = "X86_64"
      enable_confidential_compute = false
      image                       = "${local.api}/projects/debian-cloud/global/images/debian-12-bookworm-v20261014"
      labels                      = {}
      provisioned_iops            = 0
      provisioned_throughput      = 0
      replica_zones               = []
      resource_manager_tags       = {}
      resource_policies           = [google_compute_resource_policy.cicd_daily_snap.self_link]
      size                        = 30
      type                        = "pd-balanced"
    }
  }
  network_interface {
    internal_ipv6_prefix_length = 0
    network                     = local.network
    network_ip                  = "10.148.0.2"
    queue_count                 = 0
    stack_type                  = "IPV4_ONLY"
    subnetwork                  = local.subnetwork
    subnetwork_project          = var.project
    access_config {
      nat_ip       = google_compute_address.jenkins_ip.address
      network_tier = "PREMIUM"
    }
  }
  scheduling {
    automatic_restart          = true
    availability_domain        = 0
    host_error_timeout_seconds = 0
    min_node_cpus              = 0
    on_host_maintenance        = "MIGRATE"
    preemptible                = false
    provisioning_model         = "STANDARD"
  }
  service_account {
    email  = local.compute_sa
    scopes = ["https://www.googleapis.com/auth/devstorage.read_only", "https://www.googleapis.com/auth/logging.write", "https://www.googleapis.com/auth/monitoring.write", "https://www.googleapis.com/auth/pubsub", "https://www.googleapis.com/auth/service.management.readonly", "https://www.googleapis.com/auth/servicecontrol", "https://www.googleapis.com/auth/trace.append"]
  }
  shielded_instance_config {
    enable_integrity_monitoring = true
    enable_secure_boot          = false
    enable_vtpm                 = true
  }
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_instance" "gitlab_1" {
  can_ip_forward      = false
  deletion_policy     = "DELETE"
  deletion_protection = false
  enable_display      = false
  labels              = {}
  machine_type        = "e2-standard-2"
  metadata = {
    ssh-keys = var.admin_ssh_keys
  }
  name              = "gitlab-1"
  project           = var.project
  resource_policies = [google_compute_resource_policy.jenkins_office_hours.self_link]
  tags              = []
  zone              = var.zone
  boot_disk {
    auto_delete       = true
    device_name       = "persistent-disk-0"
    force_attach      = false
    guest_os_features = ["UEFI_COMPATIBLE", "VIRTIO_SCSI_MULTIQUEUE", "GVNIC", "SEV_CAPABLE", "SEV_LIVE_MIGRATABLE_V2", "SUSPEND_SAFE_FPR"]
    mode              = "READ_WRITE"
    source            = "${local.api}/${local.p}/zones/${var.zone}/disks/gitlab-1"
    initialize_params {
      architecture                = "X86_64"
      enable_confidential_compute = false
      image                       = "${local.api}/projects/debian-cloud/global/images/debian-12-bookworm-v20261014"
      labels                      = {}
      provisioned_iops            = 0
      provisioned_throughput      = 0
      replica_zones               = []
      resource_manager_tags       = {}
      resource_policies           = [google_compute_resource_policy.cicd_daily_snap.self_link]
      size                        = 50
      type                        = "pd-balanced"
    }
  }
  network_interface {
    internal_ipv6_prefix_length = 0
    network                     = local.network
    network_ip                  = "10.148.0.3"
    queue_count                 = 0
    stack_type                  = "IPV4_ONLY"
    subnetwork                  = local.subnetwork
    subnetwork_project          = var.project
    access_config {
      nat_ip       = google_compute_address.gitlab_ip.address
      network_tier = "PREMIUM"
    }
  }
  scheduling {
    automatic_restart          = true
    availability_domain        = 0
    host_error_timeout_seconds = 0
    min_node_cpus              = 0
    on_host_maintenance        = "MIGRATE"
    preemptible                = false
    provisioning_model         = "STANDARD"
  }
  service_account {
    email  = local.compute_sa
    scopes = ["https://www.googleapis.com/auth/devstorage.read_only", "https://www.googleapis.com/auth/logging.write", "https://www.googleapis.com/auth/monitoring.write", "https://www.googleapis.com/auth/pubsub", "https://www.googleapis.com/auth/service.management.readonly", "https://www.googleapis.com/auth/servicecontrol", "https://www.googleapis.com/auth/trace.append"]
  }
  shielded_instance_config {
    enable_integrity_monitoring = true
    enable_secure_boot          = false
    enable_vtpm                 = true
  }
  lifecycle {
    prevent_destroy = true
  }
}

# Static IPs: the address itself is assigned by GCP, not written here.
resource "google_compute_address" "jenkins_ip" {
  address_type    = "EXTERNAL"
  deletion_policy = "DELETE"
  labels          = {}
  name            = "jenkins-ip"
  network_tier    = "PREMIUM"
  prefix_length   = 0
  project         = var.project
  region          = var.region
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_address" "gitlab_ip" {
  address_type    = "EXTERNAL"
  deletion_policy = "DELETE"
  labels          = {}
  name            = "gitlab-ip"
  network_tier    = "PREMIUM"
  prefix_length   = 0
  project         = var.project
  region          = var.region
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_image" "talos_v1_14_2" {
  deletion_policy   = "DELETE"
  description       = "Talos v1.14.2 GCP (factory vanilla), w3 worker"
  disk_size_gb      = 11
  labels            = {}
  licenses          = []
  name              = "talos-v1-14-2"
  project           = var.project
  storage_locations = ["asia"]
  guest_os_features {
    type = "VIRTIO_SCSI_MULTIQUEUE"
  }
  lifecycle {
    prevent_destroy = true
  }
}
