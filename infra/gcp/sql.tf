# Cloud SQL test instance for Keycloak, kept STOPPED (activation_policy NEVER).

resource "google_sql_database_instance" "talos_kc_test" {
  database_version                     = "POSTGRES_16"
  deletion_policy                      = "DELETE"
  deletion_protection                  = true
  enforce_new_sql_network_architecture = true
  instance_type                        = "CLOUD_SQL_INSTANCE"
  maintenance_version                  = "POSTGRES_16_15.R20260712.01_44"
  name                                 = "talos-kc-test"
  node_count                           = 0
  project                              = var.project
  region                               = var.region
  replica_names                        = []
  replication_cluster {
  }
  settings {
    activation_policy                = "NEVER"
    auto_upgrade_enabled             = false
    availability_type                = "ZONAL"
    connector_enforcement            = "NOT_REQUIRED"
    data_disk_provisioned_iops       = 0
    data_disk_provisioned_throughput = 0
    deletion_protection_enabled      = false
    disk_autoresize                  = false
    disk_autoresize_limit            = 0
    disk_size                        = 10
    disk_type                        = "PD_SSD"
    edition                          = "ENTERPRISE"
    enable_dataplex_integration      = true
    enable_google_ml_integration     = false
    pricing_plan                     = "PER_USE"
    replication_lag_max_seconds      = 31536000
    retain_backups_on_delete         = false
    tier                             = "db-f1-micro"
    user_labels                      = {}
    backup_configuration {
      binary_log_enabled             = false
      enabled                        = false
      point_in_time_recovery_enabled = false
      start_time                     = "00:00"
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = 7
        retention_unit   = "COUNT"
      }
    }
    data_cache_config {
      data_cache_enabled = false
    }
    ip_configuration {
      custom_subject_alternative_names              = []
      enable_private_path_for_google_cloud_services = false
      ipv4_enabled                                  = true
      server_ca_mode                                = "GOOGLE_MANAGED_INTERNAL_CA"
      ssl_mode                                      = "ENCRYPTED_ONLY"
      dynamic "authorized_networks" {
        for_each = var.office_cidrs
        content {
          value = authorized_networks.value
        }
      }
    }
    location_preference {
      zone = "asia-southeast1-c"
    }
  }
  lifecycle {
    prevent_destroy = true
    # Google bumps the minor maintenance version by itself.
    ignore_changes = [maintenance_version]
  }
}
