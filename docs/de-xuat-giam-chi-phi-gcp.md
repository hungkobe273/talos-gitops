# Đề xuất giảm chi phí GCP (10/11/2026)

Trạng thái: **chờ anh duyệt**. Chưa thay đổi gì trên GCP.

## 1. Vấn đề

- Budget `talos-lab` là 1.300.000 VND/tháng (khoảng 50 USD). Ước tính chi tiêu hiện tại khoảng **68–70 USD/tháng (khoảng 1,8 triệu VND)**, vượt khoảng 20 USD.
- Đang dùng credit trial (300 USD, tới 22/01/2027) nên chưa mất tiền thật, nhưng budget sẽ báo vượt mỗi tháng. Hết trial thì đây là tiền thật.

## 2. Đang tốn ở đâu

Ước tính theo giá niêm yết asia-southeast1. Giờ chạy theo lịch: Jenkins và GitLab chạy 08:15–17:15 T2–T6 (khoảng 196 giờ/tháng). w3 cũng vậy, riêng T2/T4 tắt lúc 10:40 (khoảng 138 giờ/tháng). Số thật xem ở Billing → Reports, nhóm theo SKU.

| Khoản | Cách tính | USD/tháng |
|---|---|---|
| gitlab-1 (e2-standard-2) | 196 h × 0,083 | 16,2 |
| w3 (e2-standard-2) | 138 h × 0,083 | 11,4 |
| jenkins-1 (e2-medium) | 196 h × 0,041 | 8,1 |
| Đĩa pd-balanced 130 GB (50 + 50 + 30) | tính cả lúc VM tắt | 14,3 |
| 2 IP tĩnh (Jenkins, GitLab) | lúc VM tắt 0,01/h, lúc chạy 0,005/h | 12,6 |
| Cloud SQL `talos-kc-test` (đang tắt, 10 GB SSD) | chỉ tính đĩa | 2,2 |
| Snapshot hằng ngày (giữ 7 ngày, khoảng 28 GB) | | 0,8 |
| IP tạm của w3, KMS, bucket, Scheduler, egress | | khoảng 2–3 |
| **Tổng** | | **khoảng 68–70** |

Điểm đáng chú ý:
- IP tĩnh và đĩa vẫn bị tính tiền cả buổi tối và cuối tuần, chiếm gần 40% tổng.
- Ngày T2 và T4 em chỉ làm tới 10:30, nhưng Jenkins và GitLab vẫn chạy tới 17:15.

## 3. Các cách giảm

| # | Cách | Tiết kiệm (USD/tháng) | Đánh đổi | Đề xuất |
|---|---|---|---|---|
| A | T2/T4 tắt Jenkins và GitLab lúc 10:40, giống w3 (thêm job Cloud Scheduler trong `infra/gcp/schedule.tf`) | khoảng 6,5 | CI không chạy chiều T2/T4. Cần hỏi Phúc và anh có dùng giờ đó không | Nên làm |
| B | GitLab chỉ bật khi cần: bỏ khỏi lịch tự bật, khi cần thì bật tay hoặc qua script | khoảng 15 | Mỗi lần dùng GitLab phải bật trước khoảng 3–5 phút. Jenkins là deployer chính (27/10), GitLab chỉ để build, nên ít ảnh hưởng | Nên làm, cần anh duyệt |
| C | Bỏ IP tĩnh, dùng IP tạm | khoảng 10,7 | IP đổi mỗi lần bật: phải sửa webhook GitHub → Jenkins, DNS, danh sách IP được phép của HAProxy, URL Jenkins mỗi sáng | Không nên |
| D | w3 xuống e2-medium (4 GB) | khoảng 5,7 | w3 đang dùng thật khoảng 2,6 GB, request 2,9 GiB (Prometheus 760 MiB, Argo CD controller 660 MiB); 4 GB quá sát | Không nên |
| E | Thu nhỏ đĩa w3 hoặc GitLab (50 GB xuống 20–30 GB) | khoảng 2–3 mỗi đĩa | Không thu nhỏ tại chỗ được, phải dựng lại đĩa. Đĩa w3 chứa PV local-path của Prometheus và VictoriaLogs | Không nên lúc này |
| F | Xoá Cloud SQL `talos-kc-test` | khoảng 2,2 | Anh đã bảo giữ | Giữ |

## 4. Đề xuất

Làm **A + B**: còn khoảng **47–48 USD/tháng (khoảng 1,25 triệu VND)**, dưới budget.

- A chỉ cần sửa Terraform: thêm 2 job giống `w3-stop-mon-wed` và cấp quyền stop cho 2 VM. Hưng chạy `terraform plan`/`apply` như lần dời giờ w3.
- B: bỏ `gitlab-1` khỏi resource policy `jenkins-office-hours` (Terraform), ghi vào runbook cách bật và tắt GitLab khi cần.
- Nếu chỉ được làm A thì còn khoảng 62 USD, vẫn vượt budget khoảng 12 USD.

## 5. Cần anh xác nhận

1. Chiều T2/T4 có ai cần Jenkins hoặc GitLab không (A)?
2. GitLab có thể chuyển sang chỉ bật khi cần không (B)?
