# Kế hoạch bỏ Harbor, kéo image thẳng từ GHCR, gỡ NFS

Ngày viết: 09/11. Người làm: Hưng chạy các bước CHANGE.

Tiến độ: bước 1–3 xong sáng 09/11 (`9cdeef9`, `03aaa63`, `f84a995`). Bước 4–5 dự kiến T3 10/11.

## 1. Vì sao

Anh Lý Ngọc Hưng (06/11): "harbor là để các bạn làm quen với công cụ, nếu thấy không cần nữa thì có thể chuyển sang
công cụ khác để tối ưu hạ tầng".

Hiện trạng (đo 09/11):

- CI đã đẩy image lên **GHCR** từ trước: Jenkins build, quét Trivy và ký cosign `ghcr.io/hungkobe273/talos-demo-app`;
  GitHub Actions build `ghcr.io/hungkobe273/talos-keycloak`. Harbor chỉ **pull-replicate** về
  `harbor.talos.internal/talos/*` (demo-app mỗi 10 phút, Keycloak mỗi giờ). Cụm kéo bản sao từ Harbor.
- Harbor không giữ dữ liệu nào là bản gốc: mọi image và chữ ký đều có trên GHCR, cùng digest.
- Harbor tốn: 7 pod trên w2, **448 Mi request**, 5 trong số đó thuộc nhóm `talos-core` (chiếm chỗ trước khi mất một
  worker); 4 PVC local-path trên w2 và 1 PVC NFS (542 MB).
- NFS server trên host2 chỉ còn Harbor registry dùng. csi-driver-nfs tốn **200 Mi request** (controller 80 Mi,
  DaemonSet 60 Mi mỗi worker). Mount NFS kiểu hard: NFS chết thì pod treo.
- w2 đang ở 84% memory request (sau cold start 09/11). Bỏ Harbor và NFS thu về khoảng **650 Mi request**, riêng w2
  khoảng 590 Mi, bớt một điểm hỏng
  (NFS trên host2) và một thành phần phải backup hằng ngày (`harbor-db-backup.sh`).

Đánh đổi:

- Mất Internet thì pod mới không kéo được demo-app, Keycloak từ GHCR. Không mất gì so với hiện nay: các image khác
  (docker.io, quay.io, registry.k8s.io) vốn đã kéo từ Internet, và image đã có trong containerd của node vẫn chạy.
- Mất phần "registry tự host" anh giao 27/10. Đã làm và ghi lại đầy đủ (replication, OIDC, chữ ký), có thể dựng lại
  từ commit cũ.

## 2. Thứ tự

Chuyển chỗ kéo image trước, gỡ Harbor sau. Tới hết bước 3, Harbor vẫn chạy, lùi chỉ là revert một commit.

| Bước | Việc | Gián đoạn | Lùi |
|---|---|---|---|
| 1 | Keycloak kéo từ GHCR | keycloak-0 restart, SSO dừng khoảng 2 phút | revert commit |
| 2 | demo-app kéo từ GHCR | không (rollout mới, cùng digest) | revert commit |
| 3 | Kyverno chỉ đọc chữ ký trên GHCR | không | revert commit |
| 4 | Gỡ Harbor | không (không còn ai kéo từ Harbor) | dựng lại từ commit cũ, PVC giữ 3 ngày |
| 5 | Gỡ NFS | không | dựng lại từ commit cũ |
| 6 | Dọn (sau 3 ngày) | không | không |

### Bước 1. Keycloak

- Tạo SealedSecret `ghcr-pull` cho ns `keycloak` từ Secret `demo/ghcr-pull` đang có: đọc trên host2, đổi namespace,
  đưa thẳng vào `kubeseal`, không in giá trị. Commit `platform/keycloak/manifests/ghcr-pull-sealed.yaml`.
- `platform/keycloak/values.yaml`: `repository: ghcr.io/hungkobe273/talos-keycloak`, giữ nguyên tag,
  `imagePullSecrets: [ghcr-pull]`. Bỏ `harbor-pull-sealed.yaml` khỏi kustomization.
- `.github/workflows/keycloak-image.yml`: sửa chú thích (không còn Harbor replicate).
- Kiểm: keycloak-0 Running, `imageID` trùng digest cũ, đăng nhập Argo CD qua Keycloak được.

### Bước 2. demo-app

- `apps/demo-app/kustomization.yaml`: xoá dòng `newName: harbor.talos.internal/...` (Jenkins chỉ sửa `newTag`, không
  đụng dòng này), bỏ `harbor-pull-sealed.yaml`.
- Argo Rollouts chạy rollout mới với đủ phân tích (smoke, error rate, ZAP), Kyverno kiểm chữ ký trên GHCR (glob ghcr
  đã có sẵn trong policy).
- Kiểm: rollout `Healthy`, `https://demo.talos.internal` trả 200, chạy một build Jenkins để chắc luồng CI không đổi.

### Bước 3. Kyverno

- `imagevalidatingpolicy-demo-app.yaml`: bỏ glob Harbor, `credentials.secrets: [ghcr-pull]`.
- Xoá `platform/kyverno/manifests/harbor-pull-sealed.yaml`, `talos-internal-ca-secret.yaml`; trong
  `argocd-apps/kyverno.yaml` bỏ `SSL_CERT_DIR` và volume CA nội bộ (chỉ dùng để đọc chữ ký trên Harbor).
- Kiểm: tạo thử pod demo-app không có chữ ký trong ns `demo` → bị chặn; pod có chữ ký → qua.

### Bước 4. Gỡ Harbor

- Trước khi gỡ: chạy `harbor-db-backup.sh` lần cuối, bản dump đi theo bundle offsite thường lệ.
- `argocd-apps/harbor.yaml` hiện **không có** finalizer `resources-finalizer.argocd.argoproj.io`: xoá file luôn thì
  root app xoá Application nhưng bỏ lại toàn bộ pod Harbor. Vì vậy: commit thêm finalizer, chờ sync, rồi mới xoá file.
  PVC đều Retain nên PV còn lại.
- Xoá theo: `platform/harbor/`, client `harbor` trong `realm-import.json` và `keycloak-oidc-clients-sealed.yaml`
  (xoá cả trong Keycloak đang chạy), mục Harbor trong `priority-core.yaml`/`priority-pinned.yaml`
  (`talos-pinned` không còn ai dùng thì xoá luôn PriorityClass), chú thích trong `image-scan.yaml`.
- host2 (Hưng chạy): bỏ `ExecStart=.../harbor-db-backup.sh` khỏi `talos-etcd-backup.service`, không thì backup báo
  `LOI` mỗi chiều. Giữ các bản dump cũ trong `~/talos-kvm/harbor-backups/`.
- Talos (cp1, w1, w2): gỡ patch `talos/patches/harbor-registry.yaml` (tên `harbor.talos.internal` và CA cho
  containerd), `--mode=no-reboot`. Không gấp, để lại cũng không hại.
- Tài liệu: `docs/truy-cap.md` (bỏ dòng Harbor và tên trong file hosts), `docs/kien-truc.md`, README.

### Bước 5. Gỡ NFS

- Xoá PVC `harbor/harbor-registry-nfs`, PV, thư mục `/srv/nfs/k8s/harbor` trên host2.
- Thêm finalizer vào `argocd-apps/csi-driver-nfs.yaml`, chờ sync, rồi xoá file và `platform/csi-driver-nfs/`.
- host2 (Hưng chạy): `systemctl disable --now nfs-server`, xoá dòng trong `/etc/exports`.
- Watchdog: bỏ `chk_nfs` (`host2/bin/talos-watchdog.sh`), cài lại lên host2.

### Bước 6. Dọn sau 3 ngày

- Xoá 4 PVC/PV local-path cũ của Harbor trên w2 (postgres, redis, jobservice, registry) và ns `harbor`.

## 3. Sau đó: Vault sang Longhorn

Vault là app cuối còn dữ liệu quan trọng trên local-path w2 (PVC `data-vault-0`, `audit-vault-0`): w2 chết thì
Vault dừng tới khi w2 lên lại, và External Secrets không làm mới được Secret. Làm sau khi xong Harbor, kế hoạch chi tiết
viết riêng. Hướng: snapshot Raft, Vault về 0 pod, Job copy dữ liệu sang PVC Longhorn (cách đã dùng cho Grafana 06/11),
đổi `storageClass` trong values, tạo lại StatefulSet. Unseal tự động bằng GCP KMS nên không phải nhập khoá.

## 4. Kết quả mong đợi

- Không còn Harbor, NFS: bớt khoảng 650 Mi request (w2 từ 84% xuống khoảng 69%), bớt 10 pod, bớt NFS server
  trên host2.
- Luồng CI/CD giữ nguyên: Jenkins build, quét, ký trên GHCR, sửa tag trong Git; Argo CD đồng bộ; Kyverno kiểm chữ ký.
