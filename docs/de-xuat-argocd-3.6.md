# Đề xuất: nâng Argo CD v3.5.7 lên v3.6.1

Người soạn: Hưng. Ngày 13/11/2026. Trạng thái: **ĐÃ NÂNG 13/11 13:07** (helm rev 14; rev 13 lỗi, xem mục 8). Phải xong trước 30/11/2026, ngày hết hạn mục bỏ qua CVE-2025-68121 trong `platform/image-scan/image-scan.yaml`.

Đã kiểm 13/11 12:20: values đang chạy (`helm get values`) khớp `bootstrap/argocd-values.yaml`. Render 10.11.7 và 10.12.1 với cùng values: cùng danh sách tài nguyên. Ngoài CRD (thêm trường `disableExtensionFilter`, sửa mô tả), chỉ khác nhãn version và tag image.

## 1. Vấn đề

Job `image-scan` báo `quay.io/argoproj/argocd:v3.5.7` có CVE CRITICAL **CVE-2025-68121** (Go `crypto/tls`, kiểm chứng chỉ sai). Lần nâng 3.5.4 → 3.5.7 hôm 11/11 không hết lỗi này. Image Argo CD đóng gói thêm vài binary phụ (Helm, Kustomize, ...), hai trong số đó vẫn build bằng Go cũ (stdlib v1.25.3 và v1.24.0). Bản 3.5.7 là bản cuối của nhánh 3.5, không có 3.5.8.

## 2. Số liệu (Trivy 0.76.1, 13/11 12:13, `--ignore-unfixed`)

| Image | CRITICAL | HIGH |
|---|---|---|
| `argocd:v3.5.7` (đang chạy) | **2** (CVE-2025-68121 ở 2 binary) | 123 |
| `argocd:v3.6.1` | **0** | 24 |

## 3. Đề xuất

Nâng bằng `helm upgrade` như lần 11/11, chart `argo-cd` **10.11.7 → 10.12.1**. 10.12.1 là bản chart đầu tiên dùng v3.6.1, chọn nó để ngoài app không đổi gì khác. Các chart mới hơn (10.13–10.18) cũng là v3.6.1 nhưng đổi thêm template, để lần sau.

Values giữ nguyên `bootstrap/argocd-values.yaml`.

## 4. Breaking change 3.5 → 3.6 và ảnh hưởng tới cụm

Theo tài liệu upgrading 3.5-3.6 của Argo CD:

| Thay đổi | Ảnh hưởng tới mình |
|---|---|
| OpenTelemetry: đổi tên biến `ARGOCD_REPO_OTLP_HEADERS`, TLS collector, sampler | Không: cụm không bật tracing Argo CD (values không có `otlp`) |
| `argocd app diff --local` thêm `*.tpl`, `Chart.lock` vào mặc định | Không: không dùng diff local |
| **App có `ServerSideApply=true` chuyển sang Server-Side Diff** (dry-run trên apiserver) | **Có**: 6 app `argo-rollouts`, `cert-manager`, `external-secrets`, `kyverno`, `monitoring`, `velero`. Thêm request dry-run lên kube-apiserver trên cp1 lúc refresh (có cache). Webhook validate (Kyverno) chạy cả lúc diff, nên tài nguyên bị Kyverno từ chối sẽ hiện lỗi ngay ở diff |

Dry-run không ghi etcd, nên không làm nặng thêm phần ghi đĩa của cp1 (`de-xuat-ram-cp1.md`). apiserver sẽ tốn thêm CPU và RAM một chút. Nếu thấy nặng, gắn annotation `argocd.argoproj.io/compare-options: ServerSideDiff=false` cho app đó để quay về cách diff cũ.

## 5. Cách làm (Hưng chạy trên host2, giờ làm việc)

1. Kiểm values đang chạy khớp repo: `helm get values argocd -n argocd` so với `bootstrap/argocd-values.yaml`.
2. Render 2 chart cùng values (`helm template` 10.11.7 và 10.12.1), đọc `diff`. Chỉ mong thấy đổi tag image, nhãn version và phần liên quan 3.6. Thấy gì lạ thì dừng.
3. `helm upgrade argocd argo/argo-cd --version 10.12.1 -n argocd -f bootstrap/argocd-values.yaml`.
4. Kiểm:
   - mọi pod `argocd:v3.6.1`, 0 restart;
   - 23 app `Synced Healthy`;
   - 6 app SSA không báo `ComparisonError`;
   - log controller không có lỗi;
   - đăng nhập Keycloak OIDC được.
5. Bỏ mục CVE-2025-68121 khỏi `trivyignore.yaml`, chạy image-scan tay (`kubectl -n demo create job --from=cronjob/image-scan image-scan-manual`).
6. Ghi `nhat-ky-thay-doi.md`, sửa phiên bản trong `kien-truc.md`.

## 6. Đường lùi

`helm rollback argocd <revision trước> -n argocd` (lần trước là rev 12). CRD của 3.6 tương thích ngược với 3.5 theo tài liệu. Các Application không bị xoá khi Argo CD chạy lại, chỉ phải chờ Argo CD sync lại.

## 7. Rủi ro còn lại

- Lần đầu lên minor kể từ khi dựng cụm. Khi controller khởi động lại, cả 23 app được refresh cùng lúc, apiserver trên cp1 sẽ có một đợt tải ngắn. Làm lúc không có rollout nào và cụm đã chạy ổn trên 30 phút.
- 24 HIGH còn lại ở 3.6.1 không chặn (job chỉ chặn CRITICAL).

## 8. Kết quả 13/11

- 12:21 rev 13 **failed**: hook `argocd-redis-secret-init` (limit 64Mi trong values) không chứa nổi binary 3.6.1, đọc lại binary từ đĩa liên tục (`D (disk sleep)`, 33k major fault), sau 10 phút `--wait` hết hạn. Hook chạy trước upgrade nên chưa pod nào bị đổi, Argo CD vẫn 3.5.7.
- Sửa: `redisSecretInit` request 64Mi, limit 256Mi. Xoá job kẹt, upgrade lại 13:07:28: rev 14 `deployed`, xong 13:08:37.
- Kiểm 13:10: mọi pod `argocd:v3.6.1`, 0 restart; 23/23 app `Synced Healthy`, không app nào có condition (6 app SSA không `ComparisonError`); controller 5 phút không log error; `/api/version` v3.6.1; `/auth/login` 303 sang Keycloak.
- Bỏ CVE-2025-68121 khỏi `trivyignore.yaml`.
- Bài học: trước khi nâng, so cả `resources.limits` tự đặt trong values với bản mới, không chỉ so manifest render.

## 9. Đo sau khi nâng (13/11 15:35, Prometheus, cửa sổ 13:08–15:30 so với cùng giờ 12/11 lúc còn 3.5.7)

| argocd-application-controller | 3.5.7 (12/11) | 3.6.1 (13/11) |
|---|---|---|
| RSS trung bình | 603 MiB | **527 MiB** |
| RSS đỉnh | 994 MiB | 853 MiB (đỉnh 13:29 sau lần khởi động; từ 14:00, lúc nâng Talos w1/w2, tối đa 763) |
| CPU trung bình | 64 millicore | 74 millicore (+15 %) |
| Request dry-run lên apiserver | 0,03/s | **0,52/s** (Server-Side Diff của 6 app SSA) |

RAM không tăng, limit 1280Mi còn dư. Server-Side Diff thêm khoảng 0,5 request/s dry-run lên apiserver cp1. Dry-run không ghi etcd. Tổng request apiserver 11,8/s so với 7,6/s hôm qua, nhưng chiều nay còn có nâng Talos 2 worker và Kyverno, descheduler chạy tay, nên chưa tách được phần của Argo CD. Đo lại tổng request lúc cụm yên, thứ 2 16/11.
