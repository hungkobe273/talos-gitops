# Bucket created by hand with gcloud on 06/11 (step 1 of stage 1), then imported
# below. Backend blocks cannot use variables.
terraform {
  backend "gcs" {
    bucket = "talos-kvm-tfstate-vtc"
    prefix = "gcp"
  }
}
