# Terraform cho GCP

Giai đoạn 1 của [docs/de-xuat-iac.md](../../docs/de-xuat-iac.md). Khung viết 04/11/2026 và **chưa chạy `plan`**.
Các khối `import {}` lấy từ kiểm kê chỉ đọc lúc 04/11. Phần code của từng tài nguyên sẽ để Terraform tự sinh vào
thứ Sáu 06/11.

## File

| File | Nội dung |
|---|---|
| `versions.tf` | Terraform >= 1.14, provider `hashicorp/google` ~> 7.0 (khoá phiên bản trong `.terraform.lock.hcl`, có commit) |
| `backend.tf` | State ở bucket `talos-kvm-tfstate-vtc`, prefix `gcp` |
| `providers.tf` | Đăng nhập bằng ADC (`gcloud auth application-default login`), không dùng file key |
| `variables.tf` | project, region, zone; đổi biến để dựng ở project khác |
| `services.tf` | 9 API mà lab dùng, viết tay, `disable_on_destroy = false` |
| `imports.tf` | 31 khối import: 3 VM, 2 IP, image, 5 firewall, 2 resource policy, job Scheduler, 3 bucket, 4 SA, 2 custom role, 5 quyền IAM, KMS, Cloud SQL |

Không import: SA `talos-velero-drill` (sẽ xoá sau diễn tập), SA mặc định của Compute, snapshot do lịch tự tạo,
budget (thuộc billing account), các quyền legacy mà GCS tự gán trên bucket.

## Chạy lần đầu (06/11)

Các lệnh chạy trên laptop, trong thư mục `infra/gcp`.

1. Tạo bucket state bằng tay. Đây là tài nguyên duy nhất phải tạo tay, sau đó Terraform import luôn chính nó:
   `gcloud storage buckets create gs://talos-kvm-tfstate-vtc --location=asia-southeast1 --uniform-bucket-level-access --public-access-prevention`
   rồi `gcloud storage buckets update gs://talos-kvm-tfstate-vtc --versioning`
2. `terraform init`
3. `terraform plan -generate-config-out=generated.tf`. Lệnh này chỉ đọc GCP và ghi file trên laptop.
4. Dọn `generated.tf` rồi chia thành `compute.tf`, `network.tf`, `storage.tf`, `iam.tf`, `kms.tf`, `schedule.tf`:
   - Xoá các trường chỉ đọc mà plan báo lỗi.
   - Thêm `lifecycle { prevent_destroy = true }` cho VM, IP, bucket, KMS, Cloud SQL.
   - Kiểm tra code không chứa metadata nhạy cảm (repo đang public).
5. Lặp lại `terraform plan` cho tới khi chỉ còn `N to import, 0 to add, 0 to change, 0 to destroy`.
6. `terraform apply`: chỉ ghi các import vào state, GCP không đổi gì. Sau đó `plan` phải báo `No changes`.

## Quy tắc

- Không `apply` khi plan có `destroy` hoặc `must be replaced`.
- IAM chỉ dùng `*_iam_member`. Không dùng `*_iam_policy` hay `*_iam_binding`, vì hai loại này ghi đè toàn bộ quyền và
  có thể xoá cả quyền Owner.
- Không quản lý key SA, mật khẩu, token bằng Terraform, vì những thứ đó sẽ nằm trong state.
- Không commit `*.tfstate`, `*.tfvars`, `.terraform/` (đã có trong `.gitignore` ở gốc repo).
