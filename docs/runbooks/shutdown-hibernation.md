# 보트랩(Boatlab) 서버 일시 중지(동면) 전환·백업·재개 런북

이 문서는 보트랩(`receipt-keeper`) 서버·API를 데이터 파기 없이 **일시 중지(동면 — PostgreSQL·S3 보관, 소개 웹 `https://boatlab.site` 유지)** 상태로 전환하고, 추후 재개(원복)하기 위한 운영(Prod) 및 개발(Dev) 표준 절차를 정의합니다.

---

## 1. 핵심 설계 원칙 및 PR 선머지 안전성

1. **`normal` 기본값 100% 보존 (선머지 즉시 영향 없음)**
   - 운영 Nginx 템플릿(`deploy/prod/nginx/default.conf.template`)은 기본 모드가 `"normal"`로 고정되어 있으며, 기존 `deploy.sh`처럼 `__BACKEND_SLOT__`만 치환해도 정상 운영(`normal`)과 100% 동일하게 동작합니다.
   - 개발 Helm 차트(`charts/boatlab/values-dev.yaml`)는 `backend.replicas: 1`, `pushNotificationScheduler.enabled: true`, `pushNotificationScheduler.suspend: false`를 그대로 유지합니다.
   - 따라서 이 구성을 먼저 `main`에 병합하더라도 운영 배포나 Argo CD(`selfHeal: true`, `prune: true`) 자동 동기화로 인해 서버가 즉시 중지되지 않습니다.
2. **모바일 강제 로그아웃(`401`) 원천 차단**
   - Android(`TokenAuthenticator.kt`)와 iOS(`AuthInterceptor.swift`)는 `401` 수신 후 `/api/v1/auth/refresh`가 `503`/네트워크 오류로 실패하면 즉시 로컬 토큰을 삭제해 Room/SwiftData 캐시 영수증까지 열람할 수 없게 됩니다.
   - 따라서 차단 대상 요청은 백엔드로 전달되어 `401`을 발생시키기 전에 **앞단 Nginx에서 직접 HTTP `503` (`Content-Type: application/json; charset=utf-8`) 공통 에러 Envelope**를 반환합니다.
3. **백엔드 컨테이너 정지 후에도 Nginx·Certbot 단독 기동 보장 (`stage2`)**
   - `stage2` 렌더링 시 Nginx `upstream`을 `127.0.0.1:8000`(IP 리터럴)으로 전환하여, `backend-blue`/`backend-green` 컨테이너가 정지되어 Docker DNS에서 호스트명이 사라진 뒤에도 `nginx -t`, `nginx -s reload`, 서버 재부팅, 일일 Certbot 인증서 갱신(`boatlab-certbot-renew.timer`)이 실패 없이 동작합니다.

---

## 2. 모드별 요청 처리 매트릭스 및 `503` 응답 규격

### 2.1 앞단 Nginx 공통 `503` JSON 응답 규격

- **HTTP Status**: `503 Service Unavailable`
- **Headers**:
  - `Content-Type: application/json; charset=utf-8`
  - `Strict-Transport-Security: max-age=31536000`
  - `Cache-Control: no-store`
- **Body**:

```json
{
  "success": false,
  "status": 503,
  "data": {
    "code": "SERVICE_UNAVAILABLE",
    "message": "보트랩 서비스 일시 점검으로 현재 기능을 이용할 수 없습니다.",
    "path": "/api/v1/ocr",
    "errors": []
  }
}
```

> [!NOTE]
> 요청 경로에 따옴표(`"`), 역슬래시(`\`), 제어문자 등이 포함된 비정상 입력이 들어오더라도 JSON이 깨지지 않도록 `^/[A-Za-z0-9._~:/@-]{0,200}$` 정규식 화이트리스트를 통과한 경로만 `path`에 반영하며, 그 외 입력은 `"/api"`로 안전하게 정규화합니다.

### 2.2 모드별 경로 처리 대조표

| 구분 / 경로 | `normal` (기본) | `stage1` (1차 선중지: 읽기 전용) | `stage2` (2차 전면 중지 · 동면) |
|---|---|---|---|
| `GET /.well-known/acme-challenge/*` (80/443) | `200` Certbot webroot | `200` Certbot webroot | `200` Certbot webroot |
| `GET /health`, `HEAD /health` | `200` 백엔드 전달 | `200` 백엔드 전달 | `503` JSON (Nginx 직접 응답) |
| `GET`/`HEAD` 조회 (`/api/v1/receipts*`, `/api/v1/files/*/content`, `/api/v1/users/me`, `/api/v1/credits*`, `/api/v1/usage`, `/api/v1/promotions`, `/api/v1/notifications*`) | 백엔드 전달 | **백엔드 전달 (유지)** | **`503` JSON (Nginx 직접 응답)** |
| `OPTIONS /api/v1/*` (프리플라이트) | 백엔드 전달 | **백엔드 전달 (유지)** | **`503` JSON (Nginx 직접 응답)** |
| `POST /api/v1/auth/login`, `POST /api/v1/auth/refresh` | 백엔드 전달 | **백엔드 전달 (세션·토큰 갱신 유지)** | **`503` JSON (Nginx 직접 응답)** |
| `POST /api/v1/ocr` (유료 OpenRouter OCR) | 백엔드 전달 | **`503` JSON 차단** | **`503` JSON 차단** |
| `POST /api/v1/files`, `DELETE /api/v1/files/*` | 백엔드 전달 | **`503` JSON 차단** | **`503` JSON 차단** |
| `POST/PUT/PATCH/DELETE /api/v1/receipts*` | 백엔드 전달 | **`503` JSON 차단** | **`503` JSON 차단** |
| `POST /api/v1/auth/signup`, `POST /api/v1/auth/logout` | 백엔드 전달 | **`503` JSON 차단** | **`503` JSON 차단** |
| `POST /api/v1/promotions/*/redemptions`, `POST /api/v1/promotions/redemptions` | 백엔드 전달 | **`503` JSON 차단** | **`503` JSON 차단** |
| `PUT/DELETE /api/v1/notifications/devices*`, `PATCH/DELETE /api/v1/notifications*`, `PUT/DELETE /api/v1/users/me*` | 백엔드 전달 | **`503` JSON 차단** | **`503` JSON 차단** |
| `boatlab-scheduler.timer` (5분 주기 푸시 스케줄러) | `active` | **중지 (`inactive` / `disabled`)** | **중지 (`inactive` / `disabled`)** |
| `boatlab-certbot-renew.timer` (일일 TLS 갱신) | `active` | `active` (유지) | `active` (유지) |
| `backend-blue` / `backend-green` 컨테이너 | 활성 슬롯 1개 실행 | 활성 슬롯 1개 실행 | **전체 정지 (`stopped`)** |

---

## 3. 운영(Prod — `api.boatlab.co.kr`) 단계별 전환 절차

> [!IMPORTANT]
> 이 PR을 `main`에 병합한 뒤 전환 스크립트(`/opt/boatlab/prod/scripts/maintenance.sh`)와 새 Nginx 템플릿을 운영 서버에 반영하려면, 기존 정상 릴리스 버전으로 배포를 1회 실행하거나 서버의 배포 디렉터리에 최신 `deploy/prod/` 파일을 먼저 설치합니다. 설치 직후에도 모드는 `normal`로 유지됩니다.

### 3.0 사전 상태 점검 및 (선택) 마케팅 유도 푸시 선중지

운영 서버에 SSH 접속 후 현재 슬롯·타이머·모드를 확인합니다.

```bash
sudo /opt/boatlab/prod/scripts/maintenance.sh status
sudo /opt/boatlab/prod/scripts/maintenance.sh check-outbox
```

`stage1` 진입 전(예: D-7)에 가전 무상 AS 만료 알림(`warranty_receipt`)은 유지하면서 상시 마케팅 유도 알림 3종(`engagement_*`)만 먼저 비활성화하려면 아래 명령을 실행합니다.

```bash
ACTIVE_SLOT="$(sudo cat /etc/boatlab/prod/active-slot)"
sudo docker compose --project-name boatlab-prod --file /opt/boatlab/prod/compose.yaml \
  exec -T "backend-${ACTIVE_SLOT}" python -c '
import asyncio, asyncpg
from app.core.config.settings import get_settings

async def main() -> None:
    s = get_settings()
    dsn = s.database_url.render_as_string(hide_password=False).replace("postgresql+asyncpg://", "postgresql://", 1)
    conn = await asyncpg.connect(dsn)
    try:
        updated = await conn.execute(
            "UPDATE notification_schedule_rules SET enabled = FALSE, updated_at = NOW() "
            "WHERE target_kind LIKE \x27engagement_%\x27"
        )
        print(updated)
    finally:
        await conn.close()

asyncio.run(main())
'
```

---

### 3.1 1차 선중지(`stage1`) 전환 — 유료 OCR·푸시·쓰기 차단, 조회·로그인/갱신 유지

1. **`stage1` 전환 실행**
   아래 명령은 ① `boatlab-scheduler.timer` 비활성화·정지 → ② `outbox_events` 미발송분(`retry_count < outbox_max_retry`) 0건 소진 대기(최대 60초) → ③ Nginx `stage1` 렌더링·검증·무중단 reload → ④ 로컬 HTTPS 응답 검증(`/health` `200`, `POST /api/v1/ocr` `503` JSON)을 순서대로 수행합니다.

   ```bash
   sudo /opt/boatlab/prod/scripts/maintenance.sh apply stage1
   sudo /opt/boatlab/prod/scripts/maintenance.sh status
   ```

2. **유료 외부 API 키 비활성화 및 런타임 환경변수 검증**
   - OpenRouter 콘솔에서 운영 `OPENROUTER_API_KEY`를 비활성화(또는 한도 0 설정)합니다.
   - Google Cloud 콘솔에서 Android 테스트용으로 빌드 주입된 `VISION_API_KEY`를 비활성화합니다.
   - 운영 서버 `/etc/boatlab/prod/runtime.env`(및 GitHub `production` Environment의 `PRODUCTION_RUNTIME_ENV`)에서 `OPENROUTER_API_KEY=` 공란 또는 `PUSH_SEND_ENABLED=false`로 변경해 검증할 때는 `--mode stage1` 옵션을 사용합니다.

   ```bash
   sudo /opt/boatlab/prod/scripts/validate-runtime.sh \
     --mode stage1 \
     /etc/boatlab/prod/runtime.env \
     /etc/boatlab/prod/firebase/service-account.json
   ```

3. **전환 후 외부 스모크 검증**

   ```bash
   # 1) 헬스체크 유지 확인 (200)
   curl -fsS -o /dev/null -w '%{http_code}\n' https://api.boatlab.co.kr/health

   # 2) 유료 OCR 및 쓰기 요청 차단 확인 (503 + JSON 파싱 성공)
   curl -sS -X POST https://api.boatlab.co.kr/api/v1/ocr | python3 -m json.tool
   curl -sS -X POST https://api.boatlab.co.kr/api/v1/auth/signup | python3 -m json.tool
   curl -sS -X POST https://api.boatlab.co.kr/api/v1/receipts | python3 -m json.tool
   ```

---

### 3.2 2차 전면 중지(`stage2` · 동면) 전환 및 최종 백업

데이터 정합성을 위해 **① 앞단 Nginx 전역 `503` 전환(신규 변경 유입 완전 차단) → ② `outbox_events` 0건 최종 확인 → ③ DB·S3·설정 백업 → ④ 백엔드 컨테이너 정지** 순서로 진행합니다.

#### Step 1. 앞단 Nginx 전역 `503` 선전환 (백엔드 정지 전 유입 차단)

```bash
sudo /opt/boatlab/prod/scripts/maintenance.sh apply stage2
sudo /opt/boatlab/prod/scripts/maintenance.sh check-outbox --wait 60
```

#### Step 2. 최종 백업 (PostgreSQL · S3 · `/etc/boatlab/prod` 설정 및 시크릿)

> [!CAUTION]
> 추후 서비스 재개 시 기존 회원 세션·해시·프로모션 이력을 유지하려면 `/etc/boatlab/prod/runtime.env`의 `JWT_SECRET_KEY`, `REFRESH_TOKEN_PEPPER`, `PROMOTION_BENEFICIARY_HMAC_SECRET` 원본 값을 반드시 암호화된 안전 저장소에 보관해야 합니다. 특히 `PROMOTION_BENEFICIARY_HMAC_SECRET`이 바뀌면 기존 프로모션 수혜자 식별 해시와 불일치합니다.

1. **백업 디렉터리 준비 및 설정·시크릿·인증서 아카이브 백업**

   ```bash
   BACKUP_TS="$(date +%Y%m%d-%H%M%S)"
   BACKUP_DIR="/root/boatlab-hibernation-backup-${BACKUP_TS}"
   sudo install -d -m 0700 "$BACKUP_DIR"

   sudo tar -czf "${BACKUP_DIR}/etc-boatlab-prod.tgz" -C /etc/boatlab prod
   sudo tar -czf "${BACKUP_DIR}/etc-letsencrypt.tgz" -C /etc letsencrypt
   sudo chmod 0600 "${BACKUP_DIR}"/*.tgz
   ```

2. **PostgreSQL 전체 데이터베이스(22개 ORM 테이블) `pg_dump` 백업 및 검증**
   - 관리형 PostgreSQL 콘솔에서 수동 전체 스냅샷을 1개 생성합니다.
   - 동시에 논리 덤프(`pg_dump --format=custom`)를 생성하고 목차(`pg_restore --list`)로 무결성을 검증합니다. (호스트에 `pg_dump`가 없어도 `postgres:16-alpine` 컨테이너로 즉시 수행 가능합니다.)

   ```bash
   sudo docker run --rm \
     --env-file /etc/boatlab/prod/runtime.env \
     -v "${BACKUP_DIR}:/backup" \
     postgres:16-alpine sh -ceu '
       export PGPASSWORD="$DB_PASSWORD"
       pg_dump \
         --host="$DB_HOST" \
         --port="$DB_PORT" \
         --username="$DB_USER" \
         --dbname="$DB_NAME" \
         --format=custom \
         --no-owner \
         --no-privileges \
         --file="/backup/boatlab-prod.dump"
       pg_restore --list "/backup/boatlab-prod.dump" > "/backup/boatlab-prod.toc.txt"
     '
   sudo chmod 0600 "${BACKUP_DIR}/boatlab-prod.dump" "${BACKUP_DIR}/boatlab-prod.toc.txt"
   sudo grep -E 'TABLE DATA public (users|receipts|files|user_credits|promotions|outbox_events)' \
     "${BACKUP_DIR}/boatlab-prod.toc.txt"
   ```

3. **AWS S3 영수증 원본·프로필 이미지 버킷 동기화 백업**
   - 인스턴스 IAM Role 권한을 사용해 프라이빗 버킷 전체 객체를 백업 스토리지(또는 별도 보관 버킷/아카이브 경로)로 동기화합니다.

   ```bash
   S3_BUCKET_NAME="$(sudo awk -F= '$1 == "S3_BUCKET" {print $2}' /etc/boatlab/prod/runtime.env)"
   sudo docker run --rm \
     -v "${BACKUP_DIR}:/backup" \
     amazon/aws-cli:2.27.0 \
     s3 sync "s3://${S3_BUCKET_NAME}" "/backup/s3-${S3_BUCKET_NAME}" --region ap-northeast-2
   ```

4. **체크섬 기록 및 외부 안전 저장소 이관**

   ```bash
   sudo sh -c "cd '${BACKUP_DIR}' && sha256sum *.* > SHA256SUMS"
   ```

#### Step 3. 백엔드 컨테이너 정지 및 동면 진입 완료

```bash
sudo /opt/boatlab/prod/scripts/maintenance.sh apply stage2 --stop-backends
sudo /opt/boatlab/prod/scripts/maintenance.sh status
sudo docker ps --format 'table {{.Names}}\t{{.Status}}'
```

확인 항목:
- `backend-blue`, `backend-green` 컨테이너가 실행 목록에서 내려가고 **`nginx` 컨테이너만 실행 중**이어야 합니다.
- `boatlab-scheduler.timer`는 `inactive`, `boatlab-certbot-renew.timer`는 `active` 상태여야 합니다.
- 아래 요청이 모두 `401`이나 `502`가 아닌 **`503` JSON**을 반환해야 합니다:

```bash
curl -sS -i -H 'Authorization: Bearer expired-token' https://api.boatlab.co.kr/api/v1/receipts
curl -sS -i -X POST https://api.boatlab.co.kr/api/v1/auth/refresh
curl -sS -i https://api.boatlab.co.kr/health
```

- 소개 웹(`https://boatlab.site` 및 `https://boatlab.site/app-ads.txt`)은 별도 정적 호스팅이므로 동면 기간에도 정상 응답(`200`)을 유지하는지 확인합니다.
- 필요 시 Firebase 콘솔에서 서버용 서비스 계정 키를 비활성화합니다(재개 시 새 서비스 계정 JSON 발급 후 `/etc/boatlab/prod/firebase/service-account.json` 및 `PRODUCTION_FIREBASE_JSON` 교체).

---

## 4. 개발(Dev — `boatlab-dev.luigi99.cloud` · K3s / Argo CD) 동면 전환 절차

> [!WARNING]
> `argocd/applications/boatlab-dev.yaml`에는 `automated.selfHeal: true`, `automated.prune: true`가 활성화되어 있습니다. 클러스터에서 `kubectl scale deployment/boatlab-backend --replicas=0`만 실행하면 Argo CD가 즉시 `1`로 되돌리므로, **반드시 `charts/boatlab/values-dev.yaml`을 Git으로 변경**해 전환해야 합니다.
> 또한 `postgresql.persistence`(`data` PVC `5Gi`)와 `backend.fileStorage`(`boatlab-backend-files` PVC `10Gi`)는 동면 기간 동안 절대 삭제하지 않습니다.

### 4.1 Dev DB 사전 백업 (권장)

```bash
kubectl -n boatlab-dev exec statefulset/boatlab-postgresql -- sh -ceu '
  PGPASSWORD="$POSTGRES_PASSWORD" pg_dump \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_DB" \
    -Fc
' > "boatlab-dev-$(date +%Y%m%d-%H%M%S).dump"
```

### 4.2 Dev 1차(스케줄러 일시 중지) → 2차(API 동면 + 앞단 `503` JSON) 전환

별도 동면 전환 시점에 `charts/boatlab/values-dev.yaml`을 아래와 같이 수정해 PR 병합합니다.

- **1차 (푸시 스케줄러만 일시 중지)**:
  ```yaml
  pushNotificationScheduler:
    enabled: true
    suspend: true
  ```
- **2차 (백엔드 Scale-to-Zero + PreSync migration 비활성화 + Ingress `503` JSON 응답)**:
  ```yaml
  backend:
    replicas: 0

  migration:
    enabled: false

  pushNotificationScheduler:
    enabled: true
    suspend: true

  ingress:
    annotations:
      nginx.ingress.kubernetes.io/proxy-body-size: 60m
      nginx.ingress.kubernetes.io/configuration-snippet: |
        default_type application/json;
        add_header Cache-Control "no-store" always;
        return 503 '{"success":false,"status":503,"data":{"code":"SERVICE_UNAVAILABLE","message":"보트랩 서비스 일시 점검으로 현재 기능을 이용할 수 없습니다.","path":"/api","errors":[]}}\n';
  ```
  > 참고: 클러스터 `ingress-nginx` 정책에서 `configuration-snippet`이 비활성화(`allow-snippet-annotations: "false"`)된 경우 snippet annotation은 생략하고 `backend.replicas: 0` + `pushNotificationScheduler.suspend: true`만 적용합니다.

---

## 5. 서비스 재개(원복 · Wake-up) 절차

### 5.1 운영(Prod) 재개 절차

1. **외부 API 키 및 런타임 시크릿 복원**
   - OpenRouter API 키 활성화(또는 신규 키 발급 후 `/etc/boatlab/prod/runtime.env` 및 GitHub `PRODUCTION_RUNTIME_ENV`의 `OPENROUTER_API_KEY` 갱신, `PUSH_SEND_ENABLED=true`, `OUTBOX_POLLER_ENABLED=true` 확인).
   - Firebase 서비스 계정을 재발급한 경우 `/etc/boatlab/prod/firebase/service-account.json` 및 GitHub `PRODUCTION_FIREBASE_JSON`을 함께 갱신합니다.
   - 정상(`normal`) 모드 계약 검증을 통과하는지 확인합니다:
     ```bash
     sudo /opt/boatlab/prod/scripts/validate-runtime.sh \
       /etc/boatlab/prod/runtime.env \
       /etc/boatlab/prod/firebase/service-account.json
     ```

2. **`normal` 모드 복구 실행**
   아래 명령은 ① 활성 슬롯(`active-slot`) 백엔드 컨테이너 기동 및 `healthy` 대기 → ② Nginx `normal` 설정 렌더링·검증·reload → ③ 로컬 `/health` `200` 확인 → ④ `boatlab-scheduler.timer` 및 `boatlab-certbot-renew.timer` 재활성화를 자동으로 수행합니다.

   ```bash
   sudo /opt/boatlab/prod/scripts/maintenance.sh apply normal
   sudo /opt/boatlab/prod/scripts/maintenance.sh status
   ```

3. **마케팅 유도 푸시 규칙 재활성화 (선택 — 앞서 비활성화한 경우)**

   ```bash
   ACTIVE_SLOT="$(sudo cat /etc/boatlab/prod/active-slot)"
   sudo docker compose --project-name boatlab-prod --file /opt/boatlab/prod/compose.yaml \
     exec -T "backend-${ACTIVE_SLOT}" python -c '
   import asyncio, asyncpg
   from app.core.config.settings import get_settings

   async def main() -> None:
       s = get_settings()
       dsn = s.database_url.render_as_string(hide_password=False).replace("postgresql+asyncpg://", "postgresql://", 1)
       conn = await asyncpg.connect(dsn)
       try:
           updated = await conn.execute(
               "UPDATE notification_schedule_rules SET enabled = TRUE, updated_at = NOW() "
               "WHERE target_kind LIKE \x27engagement_%\x27"
           )
           print(updated)
       finally:
           await conn.close()

   asyncio.run(main())
   '
   ```

4. **재개 후 스모크 확인**
   - `curl -fsS https://api.boatlab.co.kr/health` (`200 OK`)
   - 앱 로그인·토큰 갱신·영수증 목록 조회·이미지 조회·OCR 분석 정상 동작 확인

### 5.2 개발(Dev) 재개 절차

`charts/boatlab/values-dev.yaml`을 정상 운영 값으로 되돌리는 PR을 병합합니다:
- `backend.replicas: 1`
- `migration.enabled: true` (기본값 사용 시 `values-dev.yaml`에서 제거)
- `pushNotificationScheduler.suspend: false` (또는 키 제거)
- `ingress.annotations`에서 점검용 snippet 제거

병합 후 Argo CD가 자동 동기화하여 `boatlab-backend` Pod가 `1/1 Running`이 되고 `https://boatlab-dev.luigi99.cloud/health`가 `200`을 반환하는지 확인합니다.
