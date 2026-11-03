# Đề xuất IaC cho tầng dưới Kubernetes

Người soạn: Hưng. Ngày 03/11/2026. Trạng thái: **chờ anh duyệt**, dự kiến làm sau diễn tập Velero (05/11).

Cập nhật 03/11 chiều: **bước 1 (patch Talos vào Git) đã làm** vì không đổi gì trên cụm, xem [talos/README.md](../talos/README.md). Bước 2–4 vẫn chờ anh duyệt.

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

## 4. Cần anh quyết

- Có làm Terraform cho GCP không, hay giữ `gcloud` trong runbook (GCP đang ở Free Trial, hạn 22/01/2027).
- Thứ tự: Terraform trước hay patch Talos trước (đề xuất: patch Talos trước vì rẻ và rủi ro thấp).
