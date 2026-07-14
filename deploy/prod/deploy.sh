#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly COMPOSE_FILE="${COMPOSE_FILE:-${SCRIPT_DIR}/compose.yaml}"
readonly NGINX_TEMPLATE="${NGINX_TEMPLATE:-${SCRIPT_DIR}/nginx.conf.template}"
readonly NGINX_BOOTSTRAP_TEMPLATE="${NGINX_BOOTSTRAP_TEMPLATE:-${SCRIPT_DIR}/nginx-bootstrap.conf.template}"
readonly RUNTIME_ENV_FILE="${RUNTIME_ENV_FILE:-/etc/boatlab/prod/runtime.env}"
readonly RELEASE_ENV_FILE="${RELEASE_ENV_FILE:-/etc/boatlab/prod/release.env}"
readonly ACTIVE_SLOT_FILE="${ACTIVE_SLOT_FILE:-/etc/boatlab/prod/active-slot}"
readonly NGINX_CONFIG_ROOT="${NGINX_CONFIG_ROOT:-/etc/boatlab/prod/nginx}"
readonly NGINX_CONFIG_FILE="${NGINX_CONFIG_FILE:-${NGINX_CONFIG_ROOT}/default.conf}"
readonly BACKEND_IMAGE_REPOSITORY="${BACKEND_IMAGE_REPOSITORY:-ghcr.io/receipt-keeper/boat-backend}"
readonly IMAGE_DIGEST_FILE="${IMAGE_DIGEST_FILE:-${SCRIPT_DIR}/image-digest}"
readonly FIREBASE_CREDENTIALS_FILE="${FIREBASE_CREDENTIALS_FILE:-/etc/boatlab/prod/firebase/service-account.json}"
readonly LETSENCRYPT_ROOT="${LETSENCRYPT_ROOT:-/etc/letsencrypt}"
readonly CERTBOT_WEBROOT="${CERTBOT_WEBROOT:-/var/www/boatlab-certbot}"
readonly PRODUCTION_DOMAIN="api.boatlab.co.kr"

export BACKEND_IMAGE_REPOSITORY RUNTIME_ENV_FILE NGINX_CONFIG_ROOT NGINX_CONFIG_FILE
export FIREBASE_CREDENTIALS_FILE LETSENCRYPT_ROOT CERTBOT_WEBROOT
export COMPOSE_PROJECT_NAME="boatlab-prod"

die() {
    printf '오류: %s\n' "$1" >&2
    exit 1
}

usage() {
    cat <<'EOF'
사용법:
  deploy.sh deploy sha-<commit>
  deploy.sh rollback sha-<previous-commit>
EOF
}

compose() {
    docker compose --project-name "$COMPOSE_PROJECT_NAME" --file "$COMPOSE_FILE" "$@"
}

validate_image_tag() {
    local image_tag="$1"
    [[ "$image_tag" =~ ^sha-[0-9a-f]{7,64}$ ]] || die "이미지 태그는 sha-<hex> 형식이어야 합니다."
}

load_image_digest() {
    [[ -s "$IMAGE_DIGEST_FILE" ]] || die "image digest 파일이 없습니다: $IMAGE_DIGEST_FILE"
    IMAGE_DIGEST="$(< "$IMAGE_DIGEST_FILE")"
    [[ "$IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || die "image digest 형식이 올바르지 않습니다."
    export IMAGE_DIGEST
}

validate_runtime_files() {
    [[ -s "$RUNTIME_ENV_FILE" ]] || die "runtime env 파일이 없습니다: $RUNTIME_ENV_FILE"
    [[ -s "$FIREBASE_CREDENTIALS_FILE" ]] || die "Firebase credential 파일이 없습니다."
    [[ -s "$NGINX_TEMPLATE" ]] || die "Nginx template 파일이 없습니다: $NGINX_TEMPLATE"
    [[ -s "$NGINX_BOOTSTRAP_TEMPLATE" ]] || die "Nginx bootstrap template 파일이 없습니다: $NGINX_BOOTSTRAP_TEMPLATE"
    [[ -d "$LETSENCRYPT_ROOT" ]] || die "Let's Encrypt 디렉터리가 없습니다: $LETSENCRYPT_ROOT"
    [[ -d "$CERTBOT_WEBROOT" ]] || die "Certbot webroot가 없습니다: $CERTBOT_WEBROOT"
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
        *) die "active-slot 파일 값이 올바르지 않습니다." ;;
    esac
}

opposite_slot() {
    case "$1" in
        none|green) printf 'blue\n' ;;
        blue) printf 'green\n' ;;
        *) die "slot 값이 올바르지 않습니다." ;;
    esac
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

install_nginx_config() {
    local source_file="$1"
    local temporary_file

    install -d -m 0750 "$(dirname -- "$NGINX_CONFIG_FILE")"
    temporary_file="$(mktemp "${NGINX_CONFIG_FILE}.tmp.XXXXXX")"
    install -m 0644 "$source_file" "$temporary_file"
    mv -f "$temporary_file" "$NGINX_CONFIG_FILE"
}

render_nginx_config() {
    local target_slot="$1"
    local temporary_file

    temporary_file="$(mktemp)"
    sed "s/__BACKEND_SLOT__/backend-${target_slot}/g" "$NGINX_TEMPLATE" > "$temporary_file"
    install_nginx_config "$temporary_file"
    rm -f "$temporary_file"
}

validate_nginx_config() {
    compose run --rm --no-deps nginx nginx -t
}

switch_nginx() {
    local nginx_container
    nginx_container="$(compose ps -q nginx)"

    if [[ -n "$nginx_container" ]] && [[ "$(docker inspect --format '{{.State.Running}}' "$nginx_container")" == "true" ]]; then
        compose exec -T nginx nginx -t
        compose exec -T nginx nginx -s reload
    else
        compose up -d nginx
    fi
}

ensure_certificate() {
    local certificate_path="${LETSENCRYPT_ROOT}/live/${PRODUCTION_DOMAIN}/fullchain.pem"
    local private_key_path="${LETSENCRYPT_ROOT}/live/${PRODUCTION_DOMAIN}/privkey.pem"

    if [[ -s "$certificate_path" && -s "$private_key_path" ]]; then
        return 0
    fi

    [[ -n "${LETSENCRYPT_EMAIL:-}" ]] || die "최초 인증서 발급에는 LETSENCRYPT_EMAIL이 필요합니다."
    [[ "$LETSENCRYPT_EMAIL" =~ ^[A-Za-z0-9][A-Za-z0-9._%+-]*@([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || die "LETSENCRYPT_EMAIL 형식이 올바르지 않습니다."

    printf '최초 TLS 인증서 발급 준비: %s\n' "$PRODUCTION_DOMAIN"
    install_nginx_config "$NGINX_BOOTSTRAP_TEMPLATE"
    nginx_config_changed=true
    validate_nginx_config
    compose up -d nginx

    compose run --rm --no-deps certbot certonly \
        --webroot \
        --webroot-path /var/www/certbot \
        --domain "$PRODUCTION_DOMAIN" \
        --email "$LETSENCRYPT_EMAIL" \
        --agree-tos \
        --non-interactive \
        --no-eff-email

    [[ -s "$certificate_path" && -s "$private_key_path" ]] || die "TLS 인증서 파일이 생성되지 않았습니다."
}

wait_for_public_health() {
    command -v curl >/dev/null 2>&1 || die "Nginx health check에 curl이 필요합니다."

    for _ in {1..30}; do
        if curl --fail --silent --show-error --max-time 5 \
            --resolve "${PRODUCTION_DOMAIN}:443:127.0.0.1" \
            "https://${PRODUCTION_DOMAIN}/health" > /dev/null; then
            return 0
        fi
        sleep 2
    done

    die "Nginx를 통한 backend health check가 실패했습니다."
}

write_release_env() {
    local image_tag="$1"
    local temporary_file

    install -d -m 0750 "$(dirname -- "$RELEASE_ENV_FILE")"
    temporary_file="$(mktemp "${RELEASE_ENV_FILE}.tmp.XXXXXX")"
    printf 'BACKEND_IMAGE_REPOSITORY=%s\nIMAGE_TAG=%s\nIMAGE_DIGEST=%s\n' \
        "$BACKEND_IMAGE_REPOSITORY" "$image_tag" "$IMAGE_DIGEST" > "$temporary_file"
    chmod 0640 "$temporary_file"
    mv -f "$temporary_file" "$RELEASE_ENV_FILE"
}

write_active_slot() {
    local slot="$1"
    install -d -m 0750 "$(dirname -- "$ACTIVE_SLOT_FILE")"
    printf '%s\n' "$slot" > "${ACTIVE_SLOT_FILE}.tmp"
    chmod 0640 "${ACTIVE_SLOT_FILE}.tmp"
    mv -f "${ACTIVE_SLOT_FILE}.tmp" "$ACTIVE_SLOT_FILE"
}

deploy_image() {
    local image_tag="$1"
    local current_slot
    local target_slot
    local target_service
    local current_service
    local previous_release_exists=false
    local previous_release_content=''
    local state_changed=false
    local nginx_config_changed=false
    local nginx_switched=false
    local completed=false

    validate_image_tag "$image_tag"
    load_image_digest
    validate_runtime_files
    export IMAGE_TAG="$image_tag"

    current_slot="$(read_active_slot)"
    target_slot="$(opposite_slot "$current_slot")"
    target_service="backend-${target_slot}"
    current_service="backend-${current_slot}"
    if [[ -f "$RELEASE_ENV_FILE" ]]; then
        previous_release_exists=true
        previous_release_content="$(< "$RELEASE_ENV_FILE")"
    fi

    restore_previous_slot() {
        [[ "$current_slot" != none ]] || return 0
        render_nginx_config "$current_slot" || return 1
        validate_nginx_config || return 1

        local nginx_container
        nginx_container="$(compose ps -q nginx)"
        if [[ -n "$nginx_container" ]] && [[ "$(docker inspect --format '{{.State.Running}}' "$nginx_container")" == "true" ]]; then
            compose exec -T nginx nginx -s reload || return 1
        fi
    }

    restore_previous_state() {
        if [[ "$current_slot" == none ]]; then
            rm -f "$ACTIVE_SLOT_FILE" "$RELEASE_ENV_FILE"
            return 0
        fi

        write_active_slot "$current_slot"
        if [[ "$previous_release_exists" == true ]]; then
            local temporary_file
            temporary_file="$(mktemp "${RELEASE_ENV_FILE}.tmp.XXXXXX")"
            printf '%s\n' "$previous_release_content" > "$temporary_file"
            chmod 0640 "$temporary_file"
            mv -f "$temporary_file" "$RELEASE_ENV_FILE"
        else
            rm -f "$RELEASE_ENV_FILE"
        fi
    }

    cleanup_deployment() {
        if [[ "$completed" != true ]]; then
            if [[ "$nginx_config_changed" == true && "$nginx_switched" != true && "$current_slot" != none ]]; then
                restore_previous_slot >/dev/null 2>&1 || \
                    printf '경고: 이전 Nginx upstream 복구에 실패했습니다.\n' >&2
            fi
            if [[ "$nginx_switched" == true && "$current_slot" != none ]]; then
                if ! compose start "$current_service" >/dev/null 2>&1 || \
                    ! (wait_for_healthy "$current_service") >/dev/null 2>&1; then
                    printf '경고: 기존 슬롯을 재시작하지 못해 새 슬롯을 유지합니다.\n' >&2
                    return
                fi
                if ! restore_previous_slot >/dev/null 2>&1; then
                    printf '경고: 기존 Nginx upstream 복구에 실패해 새 슬롯을 유지합니다.\n' >&2
                    return
                fi
            fi
            if [[ "$state_changed" == true ]]; then
                restore_previous_state >/dev/null 2>&1 || {
                    printf '경고: 이전 배포 상태 파일 복구에 실패했습니다.\n' >&2
                    return
                }
            fi
            compose stop --timeout 30 "$target_service" >/dev/null 2>&1 || true
        fi
    }
    trap cleanup_deployment EXIT

    printf '새 이미지 준비: %s\n' "$image_tag"
    compose pull migrate "$target_service"

    printf '데이터베이스 migration 실행\n'
    compose run --rm --no-deps migrate

    printf '비활성 슬롯 시작: %s\n' "$target_slot"
    compose up -d --force-recreate "$target_service"
    wait_for_healthy "$target_service"

    ensure_certificate
    render_nginx_config "$target_slot"
    nginx_config_changed=true
    validate_nginx_config
    nginx_switched=true
    switch_nginx
    wait_for_public_health

    state_changed=true
    write_active_slot "$target_slot"
    write_release_env "$image_tag"

    if [[ "$current_slot" != none ]]; then
        compose stop --timeout 30 "$current_service"
    fi

    completed=true
    trap - EXIT
    printf '배포 완료: %s 슬롯, %s\n' "$target_slot" "$image_tag"
}

main() {
    if [[ $# -eq 1 ]] && [[ "$1" == "-h" || "$1" == "--help" ]]; then
        usage
        return 0
    fi

    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    case "$1" in
        deploy|rollback) deploy_image "$2" ;;
        *) usage >&2; exit 2 ;;
    esac
}

main "$@"
