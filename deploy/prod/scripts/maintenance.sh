#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROD_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly PROD_ROOT
readonly COMPOSE_FILE="${COMPOSE_FILE:-${PROD_ROOT}/compose.yaml}"
readonly NGINX_TEMPLATE="${NGINX_TEMPLATE:-${PROD_ROOT}/nginx/default.conf.template}"
readonly RUNTIME_ENV_FILE="${RUNTIME_ENV_FILE:-/etc/boatlab/prod/runtime.env}"
readonly RELEASE_ENV_FILE="${RELEASE_ENV_FILE:-/etc/boatlab/prod/release.env}"
readonly ACTIVE_SLOT_FILE="${ACTIVE_SLOT_FILE:-/etc/boatlab/prod/active-slot}"
readonly MAINTENANCE_MODE_FILE="${MAINTENANCE_MODE_FILE:-$(dirname -- "$ACTIVE_SLOT_FILE")/maintenance-mode}"
readonly NGINX_CONFIG_ROOT="${NGINX_CONFIG_ROOT:-/etc/boatlab/prod/nginx}"
readonly NGINX_CONFIG_FILE="${NGINX_CONFIG_FILE:-${NGINX_CONFIG_ROOT}/default.conf}"
readonly FIREBASE_CREDENTIALS_FILE="${FIREBASE_CREDENTIALS_FILE:-/etc/boatlab/prod/firebase/service-account.json}"
readonly LETSENCRYPT_ROOT="${LETSENCRYPT_ROOT:-/etc/letsencrypt}"
readonly CERTBOT_WEBROOT="${CERTBOT_WEBROOT:-/var/www/boatlab-certbot}"
readonly PRODUCTION_DOMAIN="${PRODUCTION_DOMAIN:-api.boatlab.co.kr}"

export RUNTIME_ENV_FILE NGINX_CONFIG_ROOT NGINX_CONFIG_FILE
export FIREBASE_CREDENTIALS_FILE LETSENCRYPT_ROOT CERTBOT_WEBROOT
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-boatlab-prod}"

# shellcheck source=deploy/prod/scripts/release-contract.sh
source "$SCRIPT_DIR/release-contract.sh"

die() {
    printf '오류: %s\n' "$1" >&2
    exit 1
}

usage() {
    cat <<'EOF'
사용법:
  maintenance.sh status
  maintenance.sh render <normal|stage1|stage2> [--slot <blue|green|none>] [--output <path>]
  maintenance.sh check-outbox [--wait <seconds>]
  maintenance.sh apply <normal|stage1|stage2> [--stop-backends] [--skip-outbox-check] [--skip-systemctl] [--skip-public-check]

모드 설명:
  normal  정상 운영 모드 (모든 경로를 활성 백엔드 슬롯으로 전달, scheduler 타이머 활성화)
  stage1  1차 선중지 모드 (scheduler 타이머 중지, GET/HEAD/OPTIONS 및 로그인·토큰 갱신만 허용, 쓰기·OCR 503 JSON 차단)
  stage2  2차 전면 중지 모드 (모든 /api/ 및 백엔드 경로에 앞단 Nginx가 즉시 503 JSON 반환, --stop-backends 지정 시 백엔드 컨테이너 정지)
EOF
}

validate_mode_name() {
    case "$1" in
        normal|stage1|stage2) ;;
        *) die "지원하지 않는 점검 모드입니다: $1 (허용: normal, stage1, stage2)" ;;
    esac
}

compose() {
    docker compose --project-name "$COMPOSE_PROJECT_NAME" --file "$COMPOSE_FILE" "$@"
}

load_installed_release() {
    local manifest_source="$RELEASE_ENV_FILE"
    if [[ ! -s "$manifest_source" ]]; then
        manifest_source="${PROD_ROOT}/config/release.env"
    fi
    load_release_manifest "$manifest_source" || die "release manifest 검증에 실패했습니다: $manifest_source"
}

read_active_slot() {
    if [[ ! -s "$ACTIVE_SLOT_FILE" ]]; then
        printf 'none\n'
        return
    fi

    local slot
    slot="$(< "$ACTIVE_SLOT_FILE")"
    case "$slot" in
        blue|green) printf '%s\n' "$slot" ;;
        *) die "active-slot 파일 값이 올바르지 않습니다: $ACTIVE_SLOT_FILE" ;;
    esac
}

read_maintenance_mode() {
    if [[ ! -s "$MAINTENANCE_MODE_FILE" ]]; then
        printf 'normal\n'
        return
    fi

    local mode
    mode="$(< "$MAINTENANCE_MODE_FILE")"
    validate_mode_name "$mode"
    printf '%s\n' "$mode"
}

write_maintenance_mode() {
    local mode="$1"
    local temporary_file
    validate_mode_name "$mode"

    install -d -m 0750 "$(dirname -- "$MAINTENANCE_MODE_FILE")"
    temporary_file="$(mktemp "${MAINTENANCE_MODE_FILE}.tmp.XXXXXX")"
    printf '%s\n' "$mode" > "$temporary_file"
    chmod 0640 "$temporary_file"
    mv -f "$temporary_file" "$MAINTENANCE_MODE_FILE"
}

render_nginx_to_file() {
    local mode="$1"
    local slot="$2"
    local output_file="$3"
    local upstream_host
    local temporary_file

    validate_mode_name "$mode"
    [[ -s "$NGINX_TEMPLATE" ]] || die "Nginx template 파일이 없습니다: $NGINX_TEMPLATE"

    case "$mode" in
        normal|stage1)
            case "$slot" in
                blue|green) upstream_host="backend-${slot}" ;;
                *) die "${mode} 모드 렌더링에는 유효한 백엔드 슬롯(blue|green)이 필요합니다." ;;
            esac
            ;;
        stage2)
            upstream_host="127.0.0.1"
            ;;
    esac

    install -d -m 0750 "$(dirname -- "$output_file")"
    temporary_file="$(mktemp "${output_file}.tmp.XXXXXX")"
    sed \
        -e "s/__BACKEND_SLOT__/${upstream_host}/g" \
        -e "s/default \"normal\"; # __MAINTENANCE_MODE__/default \"${mode}\"; # __MAINTENANCE_MODE__/" \
        "$NGINX_TEMPLATE" > "$temporary_file"
    chmod 0644 "$temporary_file"
    mv -f "$temporary_file" "$output_file"
}

is_service_running() {
    local service="$1"
    local container_id
    container_id="$(compose ps -q "$service")"
    [[ -n "$container_id" ]] && [[ "$(docker inspect --format '{{.State.Running}}' "$container_id")" == "true" ]]
}

wait_for_healthy() {
    local service="$1"
    local container_id
    local status

    container_id="$(compose ps -q "$service")"
    [[ -n "$container_id" ]] || die "$service 컨테이너가 생성되지 않았습니다."

    for _ in {1..60}; do
        status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' "$container_id")"
        case "$status" in
            healthy) return 0 ;;
            unhealthy) die "$service health check가 실패했습니다." ;;
        esac
        sleep 2
    done

    die "$service가 제한 시간 안에 healthy 상태가 되지 않았습니다."
}

reload_or_start_nginx() {
    compose run --rm --no-deps nginx nginx -t
    if is_service_running nginx; then
        compose exec -T nginx nginx -t
        compose exec -T nginx nginx -s reload
    else
        compose up -d nginx
    fi
}

query_outbox_counts() {
    local py_code
    py_code='
import asyncio
import json
import asyncpg
from app.core.config.settings import get_settings

async def main() -> None:
    s = get_settings()
    dsn = s.database_url.render_as_string(hide_password=False).replace("postgresql+asyncpg://", "postgresql://", 1)
    conn = await asyncpg.connect(dsn, timeout=5)
    try:
        row = await conn.fetchrow(
            "SELECT COUNT(*)::int AS total, "
            "COALESCE(SUM(CASE WHEN retry_count < $1 THEN 1 ELSE 0 END), 0)::int AS pending, "
            "COALESCE(SUM(CASE WHEN retry_count >= $1 THEN 1 ELSE 0 END), 0)::int AS dead_letter "
            "FROM outbox_events",
            s.outbox_max_retry,
        )
        print(json.dumps(dict(row)))
    finally:
        await conn.close()

asyncio.run(main())
'

    local slot
    slot="$(read_active_slot)"
    if [[ "$slot" != none ]] && is_service_running "backend-${slot}"; then
        compose exec -T "backend-${slot}" python -c "$py_code"
        return
    fi
    for candidate in backend-blue backend-green; do
        if is_service_running "$candidate"; then
            compose exec -T "$candidate" python -c "$py_code"
            return
        fi
    done

    compose run --rm --no-deps scheduler python -c "$py_code"
}

check_outbox_drained() {
    local wait_seconds="${1:-0}"
    local deadline=$((SECONDS + wait_seconds))
    local stats_json
    local pending
    local dead_letter
    local total

    load_installed_release

    while true; do
        stats_json="$(query_outbox_counts)"
        read -r total pending dead_letter < <(
            python3 -c 'import json, sys; d = json.loads(sys.argv[1]); print(d["total"], d["pending"], d["dead_letter"])' "$stats_json"
        )

        if [[ "$pending" -eq 0 ]]; then
            printf 'outbox_events 확인 완료: total=%s, pending=%s, dead_letter=%s\n' \
                "$total" "$pending" "$dead_letter"
            return 0
        fi

        if (( SECONDS >= deadline )); then
            printf '경고: 미발송 outbox_events가 남아 있습니다: total=%s, pending=%s, dead_letter=%s\n' \
                "$total" "$pending" "$dead_letter" >&2
            return 1
        fi

        sleep 5
    done
}

stop_scheduler_units() {
    local skip_systemctl="$1"
    if [[ "$skip_systemctl" == true ]]; then
        return 0
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        printf '안내: systemctl이 없어 타이머 중지를 건너뜁니다.\n'
        return 0
    fi

    systemctl disable --now boatlab-scheduler.timer >/dev/null 2>&1 || true
    systemctl stop boatlab-scheduler.service >/dev/null 2>&1 || true
}

enable_normal_timers() {
    local skip_systemctl="$1"
    if [[ "$skip_systemctl" == true ]]; then
        return 0
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        printf '안내: systemctl이 없어 타이머 재활성화를 건너뜁니다.\n'
        return 0
    fi

    systemctl enable --now boatlab-scheduler.timer boatlab-certbot-renew.timer
    systemctl is-active --quiet boatlab-scheduler.timer
    systemctl is-active --quiet boatlab-certbot-renew.timer
}

verify_public_mode() {
    local mode="$1"
    local skip_public_check="$2"
    local status_code
    local body_file

    if [[ "$skip_public_check" == true ]]; then
        return 0
    fi
    command -v curl >/dev/null 2>&1 || die "전환 후 응답 검증에 curl이 필요합니다."

    body_file="$(mktemp)"
    trap 'rm -f "$body_file"' RETURN

    case "$mode" in
        normal)
            status_code="$(curl --silent --show-error --max-time 5 \
                --output "$body_file" --write-out '%{http_code}' \
                --resolve "${PRODUCTION_DOMAIN}:443:127.0.0.1" \
                "https://${PRODUCTION_DOMAIN}/health")"
            [[ "$status_code" == "200" ]] || die "normal 모드 /health 응답 코드가 200이 아닙니다: $status_code"
            ;;
        stage1)
            status_code="$(curl --silent --show-error --max-time 5 \
                --output "$body_file" --write-out '%{http_code}' \
                --resolve "${PRODUCTION_DOMAIN}:443:127.0.0.1" \
                "https://${PRODUCTION_DOMAIN}/health")"
            [[ "$status_code" == "200" ]] || die "stage1 모드 /health 응답 코드가 200이 아닙니다: $status_code"

            status_code="$(curl --silent --show-error --max-time 5 \
                --request POST \
                --output "$body_file" --write-out '%{http_code}' \
                --resolve "${PRODUCTION_DOMAIN}:443:127.0.0.1" \
                "https://${PRODUCTION_DOMAIN}/api/v1/ocr")"
            [[ "$status_code" == "503" ]] || die "stage1 모드 POST /api/v1/ocr 응답 코드가 503이 아닙니다: $status_code"
            python3 -m json.tool "$body_file" >/dev/null
            ;;
        stage2)
            local check_path
            for check_path in "/api/v1/receipts" "/api/v1/auth/refresh" "/health"; do
                local method="GET"
                if [[ "$check_path" == "/api/v1/auth/refresh" ]]; then
                    method="POST"
                fi
                status_code="$(curl --silent --show-error --max-time 5 \
                    --request "$method" \
                    --output "$body_file" --write-out '%{http_code}' \
                    --resolve "${PRODUCTION_DOMAIN}:443:127.0.0.1" \
                    "https://${PRODUCTION_DOMAIN}${check_path}")"
                [[ "$status_code" == "503" ]] || die "stage2 모드 ${method} ${check_path} 응답 코드가 503이 아닙니다: $status_code"
                python3 -m json.tool "$body_file" >/dev/null
            done
            ;;
    esac
}

show_status() {
    local current_mode
    local active_slot
    local rendered_mode="missing"
    local rendered_upstream="missing"
    local scheduler_timer="unavailable"
    local certbot_timer="unavailable"

    current_mode="$(read_maintenance_mode)"
    active_slot="$(read_active_slot)"

    if [[ -s "$NGINX_CONFIG_FILE" ]]; then
        rendered_mode="$(sed -n 's/^[[:space:]]*default "\([a-z0-9]*\)"; # __MAINTENANCE_MODE__$/\1/p' "$NGINX_CONFIG_FILE" | head -n 1)"
        [[ -n "$rendered_mode" ]] || rendered_mode="normal(implicit)"
        rendered_upstream="$(sed -n 's/^[[:space:]]*server \([^;]*\);$/\1/p' "$NGINX_CONFIG_FILE" | head -n 1)"
        [[ -n "$rendered_upstream" ]] || rendered_upstream="unknown"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet boatlab-scheduler.timer; then
            scheduler_timer="active"
        else
            scheduler_timer="inactive"
        fi
        if systemctl is-active --quiet boatlab-certbot-renew.timer; then
            certbot_timer="active"
        else
            certbot_timer="inactive"
        fi
    fi

    printf 'maintenance_mode=%s\n' "$current_mode"
    printf 'active_slot=%s\n' "$active_slot"
    printf 'nginx_rendered_mode=%s\n' "$rendered_mode"
    printf 'nginx_upstream=%s\n' "$rendered_upstream"
    printf 'scheduler_timer=%s\n' "$scheduler_timer"
    printf 'certbot_timer=%s\n' "$certbot_timer"
}

run_render_command() {
    [[ $# -ge 1 ]] || { usage >&2; exit 2; }
    local target_mode="$1"
    shift

    local slot=''
    local output_file="$NGINX_CONFIG_FILE"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --slot)
                [[ $# -ge 2 ]] || die "--slot 값이 필요합니다."
                slot="$2"
                shift 2
                ;;
            --output)
                [[ $# -ge 2 ]] || die "--output 경로가 필요합니다."
                output_file="$2"
                shift 2
                ;;
            *)
                die "알 수 없는 옵션입니다: $1"
                ;;
        esac
    done

    if [[ -z "$slot" ]]; then
        slot="$(read_active_slot)"
    fi
    render_nginx_to_file "$target_mode" "$slot" "$output_file"
    printf 'Nginx 설정 렌더링 완료: mode=%s, output=%s\n' "$target_mode" "$output_file"
}

run_check_outbox_command() {
    local wait_seconds=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --wait)
                [[ $# -ge 2 ]] || die "--wait 초 단위 숫자가 필요합니다."
                [[ "$2" =~ ^[0-9]+$ ]] || die "--wait 값은 0 이상의 정수여야 합니다."
                wait_seconds="$2"
                shift 2
                ;;
            *)
                die "알 수 없는 옵션입니다: $1"
                ;;
        esac
    done

    check_outbox_drained "$wait_seconds"
}

apply_mode() (
    [[ $# -ge 1 ]] || { usage >&2; exit 2; }
    local target_mode="$1"
    shift
    validate_mode_name "$target_mode"

    local stop_backends=false
    local skip_outbox_check=false
    local skip_systemctl=false
    local skip_public_check=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stop-backends)
                stop_backends=true
                shift
                ;;
            --skip-outbox-check)
                skip_outbox_check=true
                shift
                ;;
            --skip-systemctl)
                skip_systemctl=true
                shift
                ;;
            --skip-public-check)
                skip_public_check=true
                shift
                ;;
            *)
                die "알 수 없는 옵션입니다: $1"
                ;;
        esac
    done

    if [[ "$stop_backends" == true && "$target_mode" != stage2 ]]; then
        die "--stop-backends 옵션은 stage2 모드에서만 사용할 수 있습니다."
    fi

    load_installed_release
    [[ -s "$RUNTIME_ENV_FILE" ]] || die "runtime env 파일이 없습니다: $RUNTIME_ENV_FILE"
    [[ -s "$FIREBASE_CREDENTIALS_FILE" ]] || die "Firebase credential 파일이 없습니다: $FIREBASE_CREDENTIALS_FILE"
    [[ -d "$LETSENCRYPT_ROOT" ]] || die "Let's Encrypt 디렉터리가 없습니다: $LETSENCRYPT_ROOT"
    [[ -d "$CERTBOT_WEBROOT" ]] || die "Certbot webroot가 없습니다: $CERTBOT_WEBROOT"

    local active_slot
    active_slot="$(read_active_slot)"

    local previous_nginx_exists=false
    local previous_nginx_backup=''
    local previous_mode
    previous_mode="$(read_maintenance_mode)"
    local nginx_updated=false
    local scheduler_stopped=false
    local completed=false

    if [[ -s "$NGINX_CONFIG_FILE" ]]; then
        previous_nginx_exists=true
        previous_nginx_backup="$(mktemp)"
        cp "$NGINX_CONFIG_FILE" "$previous_nginx_backup"
    fi

    cleanup_apply() {
        if [[ "$completed" != true ]]; then
            if [[ "$nginx_updated" == true && "$previous_nginx_exists" == true && -s "$previous_nginx_backup" ]]; then
                cp "$previous_nginx_backup" "$NGINX_CONFIG_FILE" >/dev/null 2>&1 || true
                reload_or_start_nginx >/dev/null 2>&1 || true
            fi
            write_maintenance_mode "$previous_mode" >/dev/null 2>&1 || true
            if [[ "$scheduler_stopped" == true && "$previous_mode" == normal ]]; then
                enable_normal_timers "$skip_systemctl" >/dev/null 2>&1 || \
                    printf '경고: 이전 scheduler timer 복구에 실패했습니다.\n' >&2
            fi
        fi
        if [[ -n "$previous_nginx_backup" ]]; then
            rm -f "$previous_nginx_backup"
        fi
    }
    trap cleanup_apply EXIT

    case "$target_mode" in
        stage1)
            [[ "$active_slot" == blue || "$active_slot" == green ]] || \
                die "stage1 전환에는 활성 백엔드 슬롯(blue|green)이 필요합니다."
            if ! is_service_running "backend-${active_slot}"; then
                die "활성 슬롯 컨테이너(backend-${active_slot})가 실행 중이 아닙니다."
            fi
            wait_for_healthy "backend-${active_slot}"

            printf '1차 선중지(stage1): 푸시 스케줄러 중지\n'
            stop_scheduler_units "$skip_systemctl"
            scheduler_stopped=true

            if [[ "$skip_outbox_check" != true ]]; then
                printf '1차 선중지(stage1): outbox_events 미발송분 소진 대기 (최대 60초)\n'
                check_outbox_drained 60
            fi

            printf '1차 선중지(stage1): Nginx 쓰기·유료 API 503 차단 설정 반영\n'
            render_nginx_to_file stage1 "$active_slot" "$NGINX_CONFIG_FILE"
            nginx_updated=true
            reload_or_start_nginx
            verify_public_mode stage1 "$skip_public_check"
            write_maintenance_mode stage1
            ;;

        stage2)
            printf '2차 전면 중지(stage2): 푸시 스케줄러 중지\n'
            stop_scheduler_units "$skip_systemctl"
            scheduler_stopped=true

            printf '2차 전면 중지(stage2): 앞단 Nginx 전역 503 JSON 설정 반영\n'
            render_nginx_to_file stage2 "$active_slot" "$NGINX_CONFIG_FILE"
            nginx_updated=true
            reload_or_start_nginx
            verify_public_mode stage2 "$skip_public_check"
            write_maintenance_mode stage2

            if [[ "$stop_backends" == true ]]; then
                if [[ "$skip_outbox_check" != true ]] && (is_service_running backend-blue || is_service_running backend-green); then
                    printf '2차 전면 중지(stage2): 백엔드 정지 전 outbox_events 미발송분 소진 확인 (최대 60초)\n'
                    check_outbox_drained 60
                fi

                printf '2차 전면 중지(stage2): 백엔드 컨테이너(backend-blue, backend-green) 정지\n'
                compose stop --timeout 30 backend-blue backend-green
                reload_or_start_nginx
                verify_public_mode stage2 "$skip_public_check"
            fi
            ;;

        normal)
            [[ "$active_slot" == blue || "$active_slot" == green ]] || \
                die "normal 복구에는 active-slot 파일(blue|green)이 필요합니다. 최초 배포는 deploy.sh를 사용하세요."

            printf '정상 운영 복구(normal): 활성 백엔드(backend-%s) 기동 및 헬스 확인\n' "$active_slot"
            compose up -d "backend-${active_slot}"
            wait_for_healthy "backend-${active_slot}"

            printf '정상 운영 복구(normal): Nginx 정상 프록시 설정 반영\n'
            render_nginx_to_file normal "$active_slot" "$NGINX_CONFIG_FILE"
            nginx_updated=true
            reload_or_start_nginx
            verify_public_mode normal "$skip_public_check"
            write_maintenance_mode normal
            enable_normal_timers "$skip_systemctl"
            ;;
    esac

    completed=true
    trap - EXIT
    if [[ -n "$previous_nginx_backup" ]]; then
        rm -f "$previous_nginx_backup"
    fi
    printf '점검 모드 전환 완료: mode=%s, active_slot=%s, stop_backends=%s\n' \
        "$target_mode" "$active_slot" "$stop_backends"
)

main() {
    if [[ $# -eq 0 ]]; then
        usage >&2
        exit 2
    fi

    case "$1" in
        -h|--help)
            usage
            ;;
        status)
            [[ $# -eq 1 ]] || { usage >&2; exit 2; }
            show_status
            ;;
        render)
            shift
            run_render_command "$@"
            ;;
        check-outbox)
            shift
            run_check_outbox_command "$@"
            ;;
        apply)
            shift
            apply_mode "$@"
            ;;
        normal|stage1|stage2)
            apply_mode "$@"
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

main "$@"
