#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly VALIDATE_RUNTIME_SCRIPT="${SCRIPT_DIR}/../scripts/validate-runtime.sh"
readonly MAINTENANCE_SCRIPT="${SCRIPT_DIR}/../scripts/maintenance.sh"
readonly DEPLOY_SCRIPT="${SCRIPT_DIR}/../scripts/deploy.sh"

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

# 1. validate-runtime.sh 모드별 계약 검증
runtime_base="$root/runtime-normal.env"
firebase_file="$root/firebase.json"
cat > "$runtime_base" <<'EOF'
APP_ENV=prod
DB_HOST=db.example
DB_PORT=5432
DB_NAME=boatlab
DB_USER=user
DB_PASSWORD=secret
JWT_SECRET_KEY=dummy-jwt
JWT_ALGORITHM=HS256
JWT_ISSUER=boat-backend
JWT_AUDIENCE=boat-api
ACCESS_TOKEN_EXPIRES_MINUTES=60
REFRESH_TOKEN_EXPIRES_DAYS=30
REFRESH_TOKEN_PEPPER=dummy-pepper
PROMOTION_BENEFICIARY_HMAC_SECRET=dummy-hmac
OPENROUTER_API_KEY=dummy-openrouter
OPENROUTER_MODEL=google/gemini-3.1-flash-lite
FILE_STORAGE_BACKEND=s3
S3_BUCKET=boatlab-test
S3_REGION=ap-northeast-2
S3_ENDPOINT_URL=
FIREBASE_PROJECT_ID=boatlab-test
FIREBASE_CHECK_REVOKED=true
PUSH_SEND_ENABLED=true
PUSH_TOKEN_STALE_DAYS=60
OUTBOX_POLLER_ENABLED=true
EOF
printf '%s\n' '{"type":"service_account","project_id":"boatlab-test","private_key":"dummy","client_email":"server@example.com"}' > "$firebase_file"

# 기본(normal) 검증 통과 확인
bash "$VALIDATE_RUNTIME_SCRIPT" "$runtime_base" "$firebase_file"

# OPENROUTER_API_KEY 공란 + PUSH_SEND_ENABLED=false + OUTBOX_POLLER_ENABLED=false 인 중지용 env
runtime_paused="$root/runtime-paused.env"
sed \
    -e 's/^OPENROUTER_API_KEY=.*/OPENROUTER_API_KEY=/' \
    -e 's/^PUSH_SEND_ENABLED=.*/PUSH_SEND_ENABLED=false/' \
    -e 's/^OUTBOX_POLLER_ENABLED=.*/OUTBOX_POLLER_ENABLED=false/' \
    "$runtime_base" > "$runtime_paused"

# normal 모드에서는 차단되어야 한다.
if bash "$VALIDATE_RUNTIME_SCRIPT" "$runtime_paused" "$firebase_file" >/dev/null 2>&1; then
    printf 'normal 모드에서 OPENROUTER_API_KEY 공란 설정이 통과했습니다.\n' >&2
    exit 1
fi

# stage1, stage2 모드에서는 통과해야 한다.
bash "$VALIDATE_RUNTIME_SCRIPT" --mode stage1 "$runtime_paused" "$firebase_file"
MAINTENANCE_MODE=stage2 bash "$VALIDATE_RUNTIME_SCRIPT" "$runtime_paused" "$firebase_file"

# stage1/stage2 모드에서도 정적 S3 키 금지 계약은 그대로 유지되어야 한다.
runtime_static_s3="$root/runtime-static-s3.env"
cp "$runtime_paused" "$runtime_static_s3"
printf 'S3_ACCESS_KEY_ID=forbidden\n' >> "$runtime_static_s3"
if bash "$VALIDATE_RUNTIME_SCRIPT" --mode stage1 "$runtime_static_s3" "$firebase_file" >/dev/null 2>&1; then
    printf 'stage1 모드에서 정적 S3 키가 통과했습니다.\n' >&2
    exit 1
fi

# 2. maintenance.sh 상태 전환 및 deploy.sh 보호 테스트
export FAKE_DOCKER_LOG="$root/docker.log"
export FAKE_SYSTEMCTL_LOG="$root/systemctl.log"
export FAKE_BACKEND_RUNNING="true"
export FAKE_OUTBOX_PENDING="0"

docker() {
    printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
    if [[ "$1" == inspect ]]; then
        if [[ "$*" == *'.State.Health'* ]]; then
            printf 'healthy\n'
        elif [[ "$*" == *'mock-nginx'* ]]; then
            printf 'true\n'
        else
            printf '%s\n' "$FAKE_BACKEND_RUNNING"
        fi
        return 0
    fi
    if [[ "$1" == compose && "$*" == *' ps -q nginx'* ]]; then
        printf 'mock-nginx\n'
        return 0
    fi
    if [[ "$1" == compose && "$*" == *' ps -q backend-'* ]]; then
        if [[ "$FAKE_BACKEND_RUNNING" == "true" ]]; then
            printf 'mock-backend\n'
        fi
        return 0
    fi
    if [[ "$1" == compose && "$*" == *' python -c '* ]]; then
        printf '{"total":%s,"pending":%s,"dead_letter":0}\n' "$FAKE_OUTBOX_PENDING" "$FAKE_OUTBOX_PENDING"
        return 0
    fi
    if [[ "$1" == compose && "$*" == *' stop --timeout 30 backend-blue backend-green'* ]]; then
        FAKE_BACKEND_RUNNING="false"
        export FAKE_BACKEND_RUNNING
        return 0
    fi
    if [[ "$1" == compose && "$*" == *' up -d backend-'* ]]; then
        FAKE_BACKEND_RUNNING="true"
        export FAKE_BACKEND_RUNNING
        return 0
    fi
    return 0
}

systemctl() {
    printf '%s\n' "$*" >> "$FAKE_SYSTEMCTL_LOG"
    return 0
}

curl() {
    local output_file=''
    local url="${*: -1}"
    local prev=''
    local arg
    for arg in "$@"; do
        if [[ "$prev" == "--output" ]]; then
            output_file="$arg"
        fi
        prev="$arg"
    done

    local code="200"
    case "${EXPECTED_PUBLIC_MODE:-normal}" in
        normal)
            code="200"
            if [[ -n "$output_file" ]]; then
                printf '{"status":"ok"}\n' > "$output_file"
            fi
            ;;
        stage1)
            if [[ "$url" == */health ]]; then
                code="200"
                [[ -z "$output_file" ]] || printf '{"status":"ok"}\n' > "$output_file"
            else
                code="503"
                [[ -z "$output_file" ]] || printf '{"success":false,"status":503,"data":{"code":"SERVICE_UNAVAILABLE","message":"점검","path":"/api/v1/ocr","errors":[]}}\n' > "$output_file"
            fi
            ;;
        stage2)
            code="503"
            [[ -z "$output_file" ]] || printf '{"success":false,"status":503,"data":{"code":"SERVICE_UNAVAILABLE","message":"점검","path":"/api/v1/receipts","errors":[]}}\n' > "$output_file"
            ;;
    esac
    printf '%s' "$code"
}

sleep() {
    return 0
}

export -f docker systemctl curl sleep

case_root="$root/state"
mkdir -p "$case_root/config/firebase" "$case_root/config/nginx" "$case_root/letsencrypt/live/api.boatlab.co.kr" "$case_root/webroot"
cp "$runtime_base" "$case_root/config/runtime.env"
cp "$firebase_file" "$case_root/config/firebase/service-account.json"
printf 'cert\n' > "$case_root/letsencrypt/live/api.boatlab.co.kr/fullchain.pem"
printf 'key\n' > "$case_root/letsencrypt/live/api.boatlab.co.kr/privkey.pem"
printf '%s\n' \
    'RELEASE_VERSION=1.0.1' \
    'GIT_TAG=v1.0.1' \
    'GIT_REVISION=a802989a5bd821006ce05b316e859738f1621910' \
    'BACKEND_IMAGE_REPOSITORY=ghcr.io/receipt-keeper/boat-backend' \
    'IMAGE_TAG=sha-a802989' \
    'IMAGE_DIGEST=sha256:ff1e923c2b7c8b7e4debd2a69a0cf94f6c7d07c5a790f298161f68d9689c3ab3' \
    > "$case_root/config/release.env"
printf 'blue\n' > "$case_root/config/active-slot"
: > "$FAKE_DOCKER_LOG"
: > "$FAKE_SYSTEMCTL_LOG"

run_maintenance() {
    RUNTIME_ENV_FILE="$case_root/config/runtime.env" \
    RELEASE_ENV_FILE="$case_root/config/release.env" \
    ACTIVE_SLOT_FILE="$case_root/config/active-slot" \
    MAINTENANCE_MODE_FILE="$case_root/config/maintenance-mode" \
    NGINX_CONFIG_ROOT="$case_root/config/nginx" \
    NGINX_CONFIG_FILE="$case_root/config/nginx/default.conf" \
    FIREBASE_CREDENTIALS_FILE="$case_root/config/firebase/service-account.json" \
    LETSENCRYPT_ROOT="$case_root/letsencrypt" \
    CERTBOT_WEBROOT="$case_root/webroot" \
    bash "$MAINTENANCE_SCRIPT" "$@"
}

# 초기 상태는 normal이어야 한다.
status_out="$(run_maintenance status)"
printf '%s\n' "$status_out" | grep -q '^maintenance_mode=normal$'
printf '%s\n' "$status_out" | grep -q '^active_slot=blue$'

# stage1 전환 검증
export EXPECTED_PUBLIC_MODE="stage1"
run_maintenance apply stage1 >/dev/null
[[ "$(< "$case_root/config/maintenance-mode")" == "stage1" ]]
grep -q 'default "stage1"; # __MAINTENANCE_MODE__' "$case_root/config/nginx/default.conf"
grep -q 'server backend-blue:8000;' "$case_root/config/nginx/default.conf"
grep -q 'disable --now boatlab-scheduler.timer' "$FAKE_SYSTEMCTL_LOG"

# stage2 전환 및 백엔드 컨테이너 정지 검증
export EXPECTED_PUBLIC_MODE="stage2"
run_maintenance apply stage2 --stop-backends >/dev/null
[[ "$(< "$case_root/config/maintenance-mode")" == "stage2" ]]
grep -q 'default "stage2"; # __MAINTENANCE_MODE__' "$case_root/config/nginx/default.conf"
grep -q 'server 127.0.0.1:8000;' "$case_root/config/nginx/default.conf"
grep -q 'stop --timeout 30 backend-blue backend-green' "$FAKE_DOCKER_LOG"

# stage2 상태에서 실수로 deploy.sh 실행 시 차단되어야 한다.
if RELEASE_MANIFEST_FILE="$case_root/config/release.env" \
    RUNTIME_ENV_FILE="$case_root/config/runtime.env" \
    RELEASE_ENV_FILE="$case_root/config/release.env" \
    ACTIVE_SLOT_FILE="$case_root/config/active-slot" \
    MAINTENANCE_MODE_FILE="$case_root/config/maintenance-mode" \
    NGINX_CONFIG_FILE="$case_root/config/nginx/default.conf" \
    FIREBASE_CREDENTIALS_FILE="$case_root/config/firebase/service-account.json" \
    LETSENCRYPT_ROOT="$case_root/letsencrypt" \
    CERTBOT_WEBROOT="$case_root/webroot" \
    LETSENCRYPT_EMAIL=test@example.com \
    bash "$DEPLOY_SCRIPT" deploy 1.0.1 >/dev/null 2>&1; then
    printf 'stage2 모드에서 deploy.sh가 차단되지 않았습니다.\n' >&2
    exit 1
fi
[[ "$(< "$case_root/config/maintenance-mode")" == "stage2" ]]

# normal 복구 검증
export EXPECTED_PUBLIC_MODE="normal"
run_maintenance apply normal >/dev/null
[[ "$(< "$case_root/config/maintenance-mode")" == "normal" ]]
grep -q 'default "normal"; # __MAINTENANCE_MODE__' "$case_root/config/nginx/default.conf"
grep -q 'server backend-blue:8000;' "$case_root/config/nginx/default.conf"
grep -q 'up -d backend-blue' "$FAKE_DOCKER_LOG"
grep -q 'enable --now boatlab-scheduler.timer boatlab-certbot-renew.timer' "$FAKE_SYSTEMCTL_LOG"

printf 'maintenance mode: OK\n'
