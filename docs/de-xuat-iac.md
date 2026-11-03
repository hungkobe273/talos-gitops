# IaC cho tầng dưới Kubernetes: đề xuất và kế hoạch

Người soạn: Hưng. Ngày 03/11/2026. Trạng thái: **anh đã duyệt toàn bộ (03/11)**, cho làm thoải mái. Kế hoạch chi tiết ở mục 5.

Cập nhật 03/11 chiều: **bước 1 (patch Talos vào Git) đã làm** vì không đổi gì trên cụm, xem [talos/README.md](../talos/README.md). Bước 2–4 theo kế hoạch ở mục 5.

## 1. Hiện trạng

Tầng Kubernetes đã là GitOps: Argo CD đồng bộ 24 app từ repo này, mọi thay đổi có commit và nhật ký. Tầng dưới vẫn làm tay theo runbook:

| Tầng | Thành phần | Đang quản lý bằng | Rủi ro |
|---|---|---|---|
| Google Cloud | 3 VM (`w3`, `jenkins-1`, `gitlab-1`), 5 firewall rule, 2 bucket (`talos-kvm-offsite-gcs-vtc`, `talos-kvm-velero-vtc`), 5 service account và IAM, lịch bật tắt `jenkins-office-hours`, snapshot `cicd-daily-snap`, budget, Cloud SQL `talos-kc-test` (STOPPED), image `talos-v1-14-2` | Lệnh `gcloud` trong runbook và file thiết kế | Không biết cấu hình thật có còn khớp tài liệu không; dựng lại phải chạy tay từng lệnh |
| Talos | Machine config của cp1, w1, w2, w3 và 15 patch (`patch-*.yaml`: KubeSpan, flannel checksum, StaticHostConfig, OIDC cho apiserver, timesync, local-path...) | File trên host2 (`~/talos-kvm/`), có trong bundle backup nhưng **không có trong Git** | Không xem được lịch sử thay đổi, không review được trước khi `apply-config` |
| host2 (KVM) | 3 VM libvirt, mạng `virbr-talos`, systemd (tunnel, watchdog, backup, coldstart-watch), script backup trong `~/bin` | Một phần trong `host2/` của repo, phần còn lại trên máy | Host hỏng thì dựng lại theo trí nhớ và runbook |

## 2. Đề xuất

| Ưu tiên | Việc | Công cụ | Lý do chọn |
|---|---|---|---|
| 1 | **Patch Talos vào Git** (`talos/patches/`), không đưa machine config đầy đủ | Git + `talosctl machineconfig patch` / `apply-config --dry-run` (không `--insecure`) | Rẻ nhất, lợi nhất: patch không chứa secret, review được trước khi áp. Secret cụm (`secrets.yaml`, CA) vẫn chỉ nằm trong bundle mã hoá |
| 2 | **Terraform cho GCP**: import tài nguyên đang có, state trong bucket GCS có versioning | Terraform + provider `google` | Đây là phần thay đổi nhiều nhất (VM, firewall, IAM, lịch). Có `terraform plan` để thấy lệch giữa tài liệu và thực tế. Diễn tập dựng cụm tạm (3 VM + firewall) thành module dùng lại được |
| 3 | **Script dựng VM libvirt** trong `host2/` (`virt-install` + XML mạng), không dùng Terraform | Shell trong Git | Một máy, ít thay đổi; provider libvirt của Terraform do cộng đồng giữ, thêm phụ thuộc mà lợi ít |
| 4 | Gom nốt script và unit của host2 vào `host2/` | Git | Đã làm một phần; còn script backup trong `~/bin` |

Không làm:
- Ansible cho host2: một máy, cấu hình ít, script là đủ.
- Đưa machine config hay secret Talos vào Git, kể cả dạng mã hoá: bundle backup đã có bản mã hoá ngoài máy.
- Quản lý key của service account bằng Terraform: key sẽ nằm trong state. Key vẫn tạo tay rồi niêm phong bằng kubeseal như hiện nay.

## 3. Cách làm và thời gian

1. Patch Talos (khoảng nửa ngày): chép 15 patch, bỏ patch cũ không dùng (`cp2`, `cp3`, `authn-rollback`), kiểm từng patch khớp cấu hình đang chạy bằng `talosctl get machineconfig` (lọc trường, không in secret).
2. Terraform GCP (khoảng 1,5 ngày): viết resource, `terraform import` từng cái, chạy `plan` tới khi **không còn thay đổi** thì mới coi là xong. Không `apply` gì mới trong bước này. Bucket state riêng, chỉ Owner đọc được.
3. Module cụm diễn tập (khoảng nửa ngày): 3 VM tự xoá sau 9 giờ và firewall, thay cho các lệnh `gcloud` ở Bước 9 và Bước 20 của thiết kế diễn tập.
4. Script libvirt (khoảng nửa ngày): sinh từ `virsh dumpxml` của VM hiện tại, thử bằng một VM tạm.

Tổng khoảng 3 ngày công. Mỗi bước có commit riêng, ghi nhật ký; bước nào lỗi thì lùi bằng commit cụ thể, không ảnh hưởng cụm đang chạy vì bước 1–2 chỉ đọc và đối chiếu.

## 4. Quyết định (03/11)

- Anh duyệt cả 4 bước, cho thử thoải mái.
- Thứ tự: patch Talos (đã xong) → Terraform GCP → module cụm diễn tập → libvirt và host2.
- Không bắt đầu Terraform trước diễn tập Velero T5 05/11: diễn tập là ưu tiên số 1, và chính buổi diễn tập cho số đo "dựng cụm tạm bằng tay mất bao lâu" để so với Terraform.
- Công cụ: Terraform (bản ổn định mới nhất lúc cài, ghim phiên bản trong `versions.tf`), provider `google` ghim phiên bản. Hạn chót mềm: xong phần GCP trước khi Free Trial hết hạn 22/01/2027, để chuyển project/tài khoản chỉ còn là đổi biến.

## 5. Kế hoạch chi tiết

### Quy tắc an toàn (áp cho mọi giai đoạn)

1. **Import trước, sửa sau.** Tài nguyên đang chạy được đưa vào Terraform bằng khối `import {}`. Chỉ coi là xong khi `terraform plan` báo `No changes`.
2. **Không `apply` khi plan có `destroy` hoặc `must be replaced`.** Dừng, đọc lại, sửa code cho khớp thực tế.
3. `lifecycle { prevent_destroy = true }` cho: 3 VM, 2 IP tĩnh, các bucket, KMS key `vault-unseal`, Cloud SQL `talos-kc-test`.
4. IAM chỉ dùng loại cộng thêm (`google_*_iam_member`). **Không** dùng `google_project_iam_policy` hay `_binding` dạng ghi đè toàn bộ: một lần apply sai có thể xoá quyền Owner.
5. Không quản lý key của service account, mật khẩu, token bằng Terraform (sẽ nằm trong state). Key vẫn tạo tay và niêm phong bằng kubeseal.
6. State ở bucket riêng, private, có versioning. Không commit `*.tfstate`, `*.tfvars` có dữ liệu thật, thư mục `.terraform/`. Có commit `.terraform.lock.hcl`.
7. Repo talos-gitops đang public: trước mỗi commit kiểm code sinh ra không có metadata nhạy cảm. Đã kiểm 03/11: `w3` không có metadata, `jenkins-1`/`gitlab-1` chỉ có `ssh-keys` (khoá công khai).
8. Mỗi giai đoạn một hoặc vài commit, ghi `docs/nhat-ky-thay-doi.md`. Lùi bằng commit cụ thể rồi `plan` lại.

### Giai đoạn 0: chuẩn bị (T4 04/11, không đụng GCP)

| Việc | Ai | Ghi chú |
|---|---|---|
| Cài Terraform trên laptop (Windows), kiểm `terraform version` | Hưng | Tải từ trang chính thức của HashiCorp |
| `gcloud auth application-default login` bằng tài khoản Owner | Hưng | Mở trình duyệt; Terraform dùng thông tin này. Hiện chưa có |
| Đọc nhanh Terraform: provider, resource, state, plan/apply, import | Hưng | Dùng session học |

### Giai đoạn 1: Terraform cho GCP hiện có (T6 06/11, khoảng 1,5 ngày)

1. Tạo bucket state `talos-kvm-tfstate-vtc` bằng `gcloud` (asia-southeast1, versioning, uniform access, chặn public). Đây là tài nguyên duy nhất tạo tay; sau đó import chính nó.
2. Tạo thư mục `infra/gcp/`: `versions.tf`, `backend.tf` (gcs), `providers.tf`, `imports.tf`, `.gitignore`, `README.md`.
3. Viết khối `import {}` cho từng tài nguyên, chạy `terraform plan -generate-config-out=generated.tf` để Terraform tự sinh code, rồi dọn và chia file theo loại (`compute.tf`, `network.tf`, `storage.tf`, `iam.tf`, `kms.tf`, `schedule.tf`).
4. Lặp `plan` → sửa tới khi `No changes`. Rồi `apply` lần đầu: chỉ ghi các import vào state, không đổi gì trên GCP.

Danh sách import (kiểm kê 03/11):

| Nhóm | Tài nguyên |
|---|---|
| Compute | VM `w3`, `jenkins-1`, `gitlab-1` (đĩa boot đi theo VM); IP tĩnh `jenkins-ip`, `gitlab-ip`; image `talos-v1-14-2` |
| Mạng | Firewall `default-allow-icmp`, `default-allow-internal`, `default-allow-ssh`, `talos-w3-apid`, `talos-w3-kubespan`; mạng `default` đọc bằng data source |
| Lịch | Resource policy `jenkins-office-hours` (bật 08:15, tắt 17:15, gắn cả 3 VM), `cicd-daily-snap` (snapshot 17:00, giữ 7 ngày) |
| Lưu trữ | Bucket `talos-kvm-offsite-gcs-vtc`, `talos-kvm-velero-vtc` (cả lifecycle) và quyền trên bucket |
| Danh tính | Service account `talos-backup-writer`, `talos-velero`, `vault-unseal`; custom role `veleroObjectStore`; các quyền cấp cho chúng |
| KMS | Keyring `talos-vault`, key `vault-unseal` (keyring GCP không xoá được, càng phải `prevent_destroy`) |
| Khác | Cloud SQL `talos-kc-test` (STOPPED, anh bảo giữ); các API đang bật (`google_project_service`, `disable_on_destroy = false`) |
| Không import | SA `talos-velero-drill` (tạm, xoá sau diễn tập); SA mặc định của Compute; 14 snapshot do lịch tự tạo; 2 budget (nằm ở billing account, cần quyền khác; thử, không được thì để ngoài và ghi lại) |

Xong khi: `terraform plan` báo `No changes`, state nằm trong bucket, code đã push, `infra/gcp/README.md` có cách chạy.

### Giai đoạn 2: module cụm diễn tập và kiểm tra tự động (tuần 09–13/11, khoảng 1 ngày)

1. `infra/gcp/drill/` với state riêng: N VM Talos (`e2-standard-2`, image `talos-v1-14-2`, `max_run_duration` 9 giờ tự xoá) và 2 firewall của diễn tập. `apply` để dựng, `destroy` để dọn.
2. Thử với 1 VM rồi `destroy` (chi phí vài nghìn đồng), đo thời gian so với số đo diễn tập ngày 05/11.
3. Thay Bước 9 và Bước 20 trong thiết kế diễn tập bằng lệnh Terraform.
4. GitHub Actions cho `infra/`: `terraform fmt -check` và `terraform validate` (không cần quyền GCP). Chạy `plan` tự động để sau, khi có service account chỉ đọc.

### Giai đoạn 3: libvirt và host2 (tuần 09–13/11, khoảng 1 ngày)

1. `host2/libvirt/`: XML của mạng `talos-net` và 3 VM (`virsh net-dumpxml`, `virsh dumpxml --inactive`), script `define-vms.sh` (tạo đĩa, `net-define`, `define`, autostart).
2. Thử bằng cách `define` một bản đổi tên, **không bật** (host2 còn khoảng 2 GB RAM trống), rồi `undefine`.
3. Gom `~/bin/*.sh` (backup, watchdog) và unit systemd còn thiếu vào `host2/`, đọc từng file để chắc không có secret (các script hiện đọc secret từ file và LoadCredential).
4. Cập nhật runbook: dựng lại host2 từ đầu theo thứ tự libvirt → patch Talos → Argo CD.

### Thứ tự và mốc

| Ngày | Việc |
|---|---|
| T4 04/11 | Giai đoạn 0 |
| T5 05/11 | Diễn tập Velero, ghi thời gian từng bước làm tay |
| T6 06/11 | Giai đoạn 1 |
| 09–13/11 | Giai đoạn 2 và 3; cập nhật `kien-truc.md`, `bao-cao.md`, showcase |
| Trước 22/01/2027 | Thử dựng lại toàn bộ GCP ở một project khác bằng đổi biến (kiểm chứng cuối) |
