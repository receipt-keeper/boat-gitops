#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROD_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly PROD_ROOT
readonly DEPLOY_ROOT="/opt/boatlab/prod"
readonly CONFIG_ROOT="/etc/boatlab/prod"

source "$SCRIPT_DIR/release-contract.sh"

die() {
    printf '오류: %s\n' "$1" >&2
    exit 1
}

require_env() {
    local name="$1"
    [[ -n "${!name:-}" ]] || die "$name 값이 없습니다."
}

validate_inputs() {
    local name
    for name in RELEASE_VERSION PRODUCTION_HOST PRODUCTION_USER PRODUCTION_RUNTIME_ENV \
        PRODUCTION_FIREBASE_JSON PRODUCTION_LETSENCRYPT_EMAIL \
        PRODUCTION_SSH_PRIVATE_KEY PRODUCTION_KNOWN_HOSTS; do
        require_env "$name"
    done

    local requested_version="$RELEASE_VERSION"
    [[ "$requested_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || die "RELEASE_VERSION 형식이 올바르지 않습니다."
    [[ "$PRODUCTION_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || die "PRODUCTION_HOST 형식이 올바르지 않습니다."
    [[ "$PRODUCTION_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "PRODUCTION_USER 형식이 올바르지 않습니다."
    [[ "$PRODUCTION_LETSENCRYPT_EMAIL" =~ ^[A-Za-z0-9][A-Za-z0-9._%+-]*@([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || die "PRODUCTION_LETSENCRYPT_EMAIL 형식이 올바르지 않습니다."

    load_release_manifest "$PROD_ROOT/config/release.env" || die "release manifest 검증에 실패했습니다."
    [[ "$requested_version" == "$RELEASE_VERSION" ]] || die "요청 버전은 저장소 RELEASE_VERSION과 일치해야 합니다."
}

mode="${1:-deploy}"
case "$mode" in
    deploy) ;;
    --validate-only) ;;
    -h|--help)
        printf '사용법: github-deploy.sh [--validate-only]\n'
        exit 0
        ;;
    *)
        printf '사용법: github-deploy.sh [--validate-only]\n' >&2
        exit 2
        ;;
esac

validate_inputs

if [[ "$mode" == deploy ]]; then
    "$SCRIPT_DIR/validate-release.sh" --remote
fi

runner_base="${RUNNER_TEMP:-/tmp}"
runner_root="$(mktemp -d "${runner_base%/}/boatlab-prod.XXXXXX")"
readonly runner_root
remote_stage=''
target=''
ssh_ready=false
deployment_complete=false
ssh_opts=()

cleanup() {
    set +e
    if [[ "$ssh_ready" == true ]]; then
        if [[ -n "$remote_stage" ]]; then
            ssh "${ssh_opts[@]}" "$target" rm -rf -- "$remote_stage" >/dev/null 2>&1
        fi
        if [[ "$deployment_complete" != true ]]; then
            ssh "${ssh_opts[@]}" "$target" \
                'if sudo test -s /etc/boatlab/prod/release.env; then sudo systemctl enable --now boatlab-scheduler.timer boatlab-certbot-renew.timer; fi' \
                >/dev/null 2>&1
        fi
    fi
    rm -rf "$runner_root"
}
trap cleanup EXIT

umask 077
runtime_file="$runner_root/boatlab-runtime.env"
firebase_file="$runner_root/boatlab-firebase.json"
archive_file="$runner_root/boatlab-prod.tgz"
printf '%s\n' "$PRODUCTION_RUNTIME_ENV" > "$runtime_file"
printf '%s\n' "$PRODUCTION_FIREBASE_JSON" > "$firebase_file"
"$SCRIPT_DIR/validate-runtime.sh" "$runtime_file" "$firebase_file"

tar -C "$PROD_ROOT" -czf "$archive_file" \
    compose.yaml config/release.env nginx systemd \
    scripts/bootstrap.sh scripts/deploy.sh scripts/renew-certificate.sh \
    scripts/release-contract.sh scripts/run-release.sh

if [[ "$mode" == --validate-only ]]; then
    printf '운영 배포 입력 검증 완료\n'
    exit 0
fi

ssh_root="$runner_root/ssh"
install -d -m 0700 "$ssh_root"
printf '%s\n' "$PRODUCTION_SSH_PRIVATE_KEY" > "$ssh_root/id"
printf '%s\n' "$PRODUCTION_KNOWN_HOSTS" > "$ssh_root/known_hosts"
chmod 0600 "$ssh_root/id" "$ssh_root/known_hosts"
ssh-keygen -y -f "$ssh_root/id" >/dev/null

ssh_opts=(
    -i "$ssh_root/id"
    -o BatchMode=yes
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$ssh_root/known_hosts"
)
target="$PRODUCTION_USER@$PRODUCTION_HOST"
ssh_ready=true

ssh "${ssh_opts[@]}" "$target" \
    'command -v docker >/dev/null && sudo docker compose version >/dev/null && sudo test -d /opt/boatlab/prod && sudo test -d /etc/boatlab/prod/firebase && sudo test -d /etc/boatlab/prod/nginx && sudo test -d /etc/letsencrypt && sudo test -d /var/www/boatlab-certbot'

remote_stage="$(ssh "${ssh_opts[@]}" "$target" mktemp -d /tmp/boatlab-deploy.XXXXXX)"
[[ "$remote_stage" =~ ^/tmp/boatlab-deploy\.[A-Za-z0-9]+$ ]] || die "원격 staging 경로가 올바르지 않습니다."

scp "${ssh_opts[@]}" "$archive_file" "$runtime_file" "$firebase_file" \
    "$target:$remote_stage/"
ssh "${ssh_opts[@]}" "$target" bash -s -- \
    "$DEPLOY_ROOT" "$CONFIG_ROOT" "$remote_stage" < "$SCRIPT_DIR/install-release.sh"
remote_stage=''

ssh "${ssh_opts[@]}" "$target" sudo env \
    "RELEASE_VERSION=$RELEASE_VERSION" \
    "LETSENCRYPT_EMAIL=$PRODUCTION_LETSENCRYPT_EMAIL" \
    /opt/boatlab/prod/scripts/run-release.sh

active_slot="$(ssh "${ssh_opts[@]}" "$target" sudo cat /etc/boatlab/prod/active-slot)"
[[ "$active_slot" == blue || "$active_slot" == green ]] || die "배포 후 active slot을 확인할 수 없습니다."

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        printf 'release_version=%s\n' "$RELEASE_VERSION"
        printf 'git_tag=%s\n' "$GIT_TAG"
        printf 'git_revision=%s\n' "$GIT_REVISION"
        printf 'image_tag=%s\n' "$IMAGE_TAG"
        printf 'image_digest=%s\n' "$IMAGE_DIGEST"
        printf 'active_slot=%s\n' "$active_slot"
    } >> "$GITHUB_OUTPUT"
fi

deployment_complete=true
printf '운영 배포 완료: %s, %s 슬롯\n' "$RELEASE_VERSION" "$active_slot"
