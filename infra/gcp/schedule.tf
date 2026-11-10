# Start/stop schedules and disk snapshots.

# w3, jenkins-1, gitlab-1 run 08:15-17:15 Mon-Fri.
resource "google_compute_resource_policy" "jenkins_office_hours" {
  deletion_policy = "DELETE"
  name            = "jenkins-office-hours"
  project         = var.project
  region          = var.region
  instance_schedule_policy {
    time_zone = "Asia/Ho_Chi_Minh"
    vm_start_schedule {
      schedule = "15 8 * * 1-5"
    }
    vm_stop_schedule {
      schedule = "15 17 * * 1-5"
    }
  }
}

# start_time is UTC: 10:00 UTC = 17:00 VN.
resource "google_compute_resource_policy" "cicd_daily_snap" {
  deletion_policy = "DELETE"
  description     = "Daily 17:00 VN snapshot of jenkins-1/gitlab-1 boot disks, keep 7 days"
  name            = "cicd-daily-snap"
  project         = var.project
  region          = var.region
  snapshot_schedule_policy {
    retention_policy {
      max_retention_days    = 7
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }
    schedule {
      daily_schedule {
        days_in_cycle = 1
        start_time    = "10:00"
      }
    }
    snapshot_properties {
      guest_flush       = false
      labels            = {}
      storage_locations = [var.region]
    }
  }
}

# Mon/Wed the cluster is off from 10:30, so w3 is stopped at 10:40 instead of 17:15.
# 10/11: 11:30 -> 10:40. From 10:30 the API is gone and w3 controllers (argo-rollouts, kube-state-metrics)
# crash-looped for an hour each Mon/Wed (~270 restarts since 30/10).
resource "google_cloud_scheduler_job" "w3_stop_mon_wed" {
  attempt_deadline = "180s"
  deletion_policy  = "DELETE"
  description      = "Stop w3 at 10:40 on Mon/Wed (cluster is off from 10:30)"
  name             = "w3-stop-mon-wed"
  paused           = false
  project          = var.project
  region           = var.region
  schedule         = "40 10 * * 1,3"
  time_zone        = "Asia/Ho_Chi_Minh"
  http_target {
    headers     = {}
    http_method = "POST"
    uri         = "https://compute.googleapis.com/compute/v1/${local.p}/zones/${var.zone}/instances/w3/stop"
    oauth_token {
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
      service_account_email = google_service_account.w3_stopper.email
    }
  }
  retry_config {
    max_backoff_duration = "3600s"
    max_doublings        = 5
    max_retry_duration   = "0s"
    min_backoff_duration = "5s"
    retry_count          = 0
  }
}

# 10/11: Mon/Wed the work day ends at 10:30, but jenkins-1 and gitlab-1 ran until 17:15 (~57 h/month, ~6.5 USD).
# Same stop as w3, same SA. They start again at 08:15 the next day through jenkins-office-hours.
# docs/de-xuat-giam-chi-phi-gcp.md (option A).
locals {
  mon_wed_cicd = [google_compute_instance.jenkins_1.name, google_compute_instance.gitlab_1.name]
}

resource "google_cloud_scheduler_job" "cicd_stop_mon_wed" {
  for_each         = toset(local.mon_wed_cicd)
  attempt_deadline = "180s"
  deletion_policy  = "DELETE"
  description      = "Stop ${each.key} at 10:40 on Mon/Wed (work day ends 10:30)"
  name             = "${each.key}-stop-mon-wed"
  paused           = false
  project          = var.project
  region           = var.region
  schedule         = "40 10 * * 1,3"
  time_zone        = "Asia/Ho_Chi_Minh"
  http_target {
    headers     = {}
    http_method = "POST"
    uri         = "https://compute.googleapis.com/compute/v1/${local.p}/zones/${var.zone}/instances/${each.key}/stop"
    oauth_token {
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
      service_account_email = google_service_account.w3_stopper.email
    }
  }
  retry_config {
    max_backoff_duration = "3600s"
    max_doublings        = 5
    max_retry_duration   = "0s"
    min_backoff_duration = "5s"
    retry_count          = 0
  }
  depends_on = [google_compute_instance_iam_member.cicd_stopper]
}
