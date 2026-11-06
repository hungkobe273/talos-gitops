# Terraform cho GCP

Giai đoạn 1 của [docs/de-xuat-iac.md](../../docs/de-xuat-iac.md). **Xong 06/11/2026:** 40 tài nguyên đã import vào
state, `terraform plan` báo `No changes`. Từ giờ sửa hạ tầng GCP bằng Terraform; sửa tay trên Console thì lần
`plan` sau sẽ báo lệch.

## Chạy hằng ngày

Trên laptop, trong thư mục `infra/gcp`, cần `terraform.tfvars` (xem dưới) và ADC còn hạn:

1. `terraform plan`: đọc kỹ từng dòng `~` (sửa tại chỗ), `-/+` (xoá rồi tạo lại), `-` (xoá).
2. Plan đúng ý thì `terraform plan "-out=x.tfplan"` rồi `terraform apply x.tfplan`, xoá file plan sau đó.
3. Commit code cùng lúc với apply, ghi `docs/nhat-ky-thay-doi.md`.

`terraform.tfvars` (gitignore, repo public) chép từ `terraform.tfvars.example`: `office_cidrs` là IP ra Internet
của văn phòng, `admin_ssh_keys` là giá trị metadata `ssh-keys` của jenkins-1/gitlab-1 (dạng `user:ssh-ed25519 ...`).
Thiếu file này thì `plan` hỏi giá trị; điền sai thì plan sẽ báo đổi firewall hoặc metadata.

## File

| File | Nội dung |
|---|---|
| `versions.tf` | Terraform >= 1.14, provider `hashicorp/google` ~> 7.0 (khoá phiên bản trong `.terraform.lock.hcl`, có commit) |
| `backend.tf` | State ở bucket `talos-kvm-tfstate-vtc`, prefix `gcp` |
| `providers.tf` | Đăng nhập bằng ADC (`gcloud auth application-default login`), không dùng file key |
| `variables.tf` | project, region, zone, `office_cidrs`, `admin_ssh_keys`; đổi biến để dựng ở project khác |
| `services.tf` | 9 API mà lab dùng, viết tay, `disable_on_destroy = false` |
| `imports.tf` | 31 khối import: 3 VM, 2 IP, image, 5 firewall, 2 resource policy, job Scheduler, 3 bucket, 4 SA, 2 custom role, 5 quyền IAM, KMS, Cloud SQL. Giữ lại sau khi import: không làm gì khi tài nguyên đã có trong state, và tự import lại nếu phải dựng state mới |
| `compute.tf` | VM w3, jenkins-1, gitlab-1; 2 IP tĩnh; image Talos |
| `network.tf` | 5 firewall; nguồn văn phòng lấy từ `var.office_cidrs` |
| `storage.tf` | 3 bucket: tfstate, offsite, velero |
| `iam.tf` | 4 SA, 2 custom role, 5 quyền `*_iam_member` |
| `kms.tf` | Key ring và key unseal của Vault |
| `schedule.tf` | Lịch bật/tắt VM, lịch snapshot, job Scheduler tắt w3 T2/T4 |
| `sql.tf` | Cloud SQL `talos-kc-test` (đang dừng) |
| `terraform.tfvars.example` | Mẫu biến; file thật `terraform.tfvars` không commit |

`prevent_destroy` đặt cho VM, IP, image, bucket, KMS, Cloud SQL: plan nào muốn xoá chúng sẽ báo lỗi luôn.

Không import: SA `talos-velero-drill` (đã xoá sau diễn tập), SA mặc định của Compute, snapshot do lịch tự tạo,
budget (thuộc billing account), các quyền legacy mà GCS tự gán trên bucket.

## Đã làm lần đầu (05–06/11), để dựng lại ở project khác

Các lệnh chạy trên laptop, trong thư mục `infra/gcp`.

1. Tạo bucket state bằng tay. Đây là tài nguyên duy nhất phải tạo tay, sau đó Terraform import luôn chính nó:
   `gcloud storage buckets create gs://talos-kvm-tfstate-vtc --location=asia-southeast1 --uniform-bucket-level-access --public-access-prevention`
   rồi `gcloud storage buckets update gs://talos-kvm-tfstate-vtc --versioning`
2. `terraform init`
3. `terraform plan "-generate-config-out=generated.tf"` (PowerShell phải đặt tham số này trong nháy kép, không thì báo `Too many command line arguments`). Lệnh này chỉ đọc GCP và ghi file trên laptop. Chỉ sinh code cho import chưa có resource, nên lần này không cần nữa.
   Lỗi sinh code gặp 05/11 và cách sửa: firewall có các list rỗng xung đột (`source_tags = []`, `destination_ranges = []`...) thì xoá các dòng `= []`; Cloud SQL bỏ `server_certificate_rotation_mode` và khối `read_pool_auto_scale_config`; VM bỏ `vlan = 0`.
4. Dọn `generated.tf` rồi chia file theo bảng trên: bỏ dòng `= null`, thay project/region bằng biến, nối tài nguyên bằng tham chiếu, thêm `prevent_destroy`, đưa IP công ty và khoá SSH ra `terraform.tfvars`. Lưu ý 06/11: IP công khai của w3 là IP tạm, đổi mỗi lần tắt/bật, nên không ghi `nat_ip`; URI của job Scheduler là `compute.googleapis.com`, khác dạng `www.googleapis.com` của các link khác.
5. Lặp lại `terraform plan` cho tới khi chỉ còn `N to import, 0 to add, 0 to change, 0 to destroy`.
6. `terraform plan "-out=import.tfplan"` rồi `terraform apply import.tfplan`: chỉ ghi các import vào state, GCP không đổi gì (06/11: `40 imported, 0 added, 0 changed, 0 destroyed`). Sau đó `plan` phải báo `No changes`.

## Quy tắc

- Không `apply` khi plan có `destroy` hoặc `must be replaced`.
- IAM chỉ dùng `*_iam_member`. Không dùng `*_iam_policy` hay `*_iam_binding`, vì hai loại này ghi đè toàn bộ quyền và
  có thể xoá cả quyền Owner.
- Không quản lý key SA, mật khẩu, token bằng Terraform, vì những thứ đó sẽ nằm trong state.
- Không commit `*.tfstate`, `*.tfvars`, `*.tfplan`, `.terraform/` (đã có trong `.gitignore` ở gốc repo).
