# Credentials: Application Default Credentials on the laptop
# (gcloud auth application-default login). No key file.
provider "google" {
  project = var.project
  region  = var.region
  zone    = var.zone
}
