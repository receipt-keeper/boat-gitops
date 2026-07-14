#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly DEPLOY_SCRIPT="${SCRIPT_DIR}/../scripts/deploy.sh"

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export FAKE_LOG="$root/docker.log"

docker() {
    printf '%s\n' "$*" >> "$FAKE_LOG"
    if [[ "$1" == inspect ]]; then
        if [[ "$*" == *'.State.Health'* ]]; then
            printf 'healthy\n'
        else
            printf 'true\n'
        fi
        return 0
    fi
    if [[ "$1" == compose && "$*" == *' ps -q '* ]]; then
        printf 'mock-container-id\n'
        return 0
    fi
    if [[ "$1" == compose && "$*" == *' certbot certonly'* && "${FAKE_CERTBOT_FAIL:-false}" == true ]]; then
        return 23
    fi
    if [[ "$1" == compose && -n "${FAKE_STOP_FAILURE:-}" && "$*" == *" stop --timeout 30 ${FAKE_STOP_FAILURE}"* ]]; then
        return 23
    fi
    return 0
}

curl() {
    [[ "${FAKE_CURL_RESULT:-success}" == success ]]
}

sleep() {
    return 0
}

mv() {
    local destination="${*: -1}"
    if [[ "${FAKE_RELEASE_MV_FAILURE:-false}" == true && "$destination" == */release.env ]]; then
        FAKE_RELEASE_MV_FAILURE=false
        export FAKE_RELEASE_MV_FAILURE
        return 71
    fi
    command mv "$@"
}

export -f docker curl sleep mv

prepare_case() {
    local case_root="$1"
    mkdir -p "$case_root/config/firebase" "$case_root/letsencrypt" "$case_root/webroot"
    printf 'APP_ENV=prod\n' > "$case_root/config/runtime.env"
    printf '{}\n' > "$case_root/config/firebase/service-account.json"
    : > "$FAKE_LOG"
}

install_mock_certificate() {
    local case_root="$1"
    local certificate_root="$case_root/letsencrypt/live/api.boatlab.co.kr"
    mkdir -p "$certificate_root"
    printf 'cert\n' > "$certificate_root/fullchain.pem"
    printf 'key\n' > "$certificate_root/privkey.pem"
}

run_deploy() {
    local case_root="$1"
    BACKEND_IMAGE_REPOSITORY=ghcr.io/receipt-keeper/boat-backend \
    RUNTIME_ENV_FILE="$case_root/config/runtime.env" \
    RELEASE_ENV_FILE="$case_root/config/release.env" \
    ACTIVE_SLOT_FILE="$case_root/config/active-slot" \
    NGINX_CONFIG_FILE="$case_root/config/nginx.conf" \
    FIREBASE_CREDENTIALS_FILE="$case_root/config/firebase/service-account.json" \
    LETSENCRYPT_ROOT="$case_root/letsencrypt" \
    CERTBOT_WEBROOT="$case_root/webroot" \
    LETSENCRYPT_EMAIL=test@example.com \
    bash "$DEPLOY_SCRIPT" deploy sha-0000000
}

success_root="$root/success"
prepare_case "$success_root"
install_mock_certificate "$success_root"
printf 'blue\n' > "$success_root/config/active-slot"
export FAKE_CURL_RESULT=success FAKE_CERTBOT_FAIL=false FAKE_STOP_FAILURE='' FAKE_RELEASE_MV_FAILURE=false
run_deploy "$success_root" >/dev/null
[[ "$(< "$success_root/config/active-slot")" == green ]]
grep -q '^IMAGE_TAG=sha-0000000$' "$success_root/config/release.env"
grep -q 'server backend-green:8000;' "$success_root/config/nginx.conf"
migration_line="$(grep -n 'run --rm --no-deps migrate' "$FAKE_LOG" | head -1 | cut -d: -f1)"
start_line="$(grep -n 'up -d --force-recreate backend-green' "$FAKE_LOG" | head -1 | cut -d: -f1)"
[[ "$migration_line" -lt "$start_line" ]]
grep -q 'stop --timeout 30 backend-blue' "$FAKE_LOG"

failure_root="$root/health-failure"
prepare_case "$failure_root"
install_mock_certificate "$failure_root"
printf 'blue\n' > "$failure_root/config/active-slot"
printf 'BACKEND_IMAGE_REPOSITORY=old\nIMAGE_TAG=sha-1111111\n' > "$failure_root/config/release.env"
export FAKE_CURL_RESULT=failure FAKE_CERTBOT_FAIL=false
if run_deploy "$failure_root" >/dev/null 2>&1; then
    exit 1
fi
[[ "$(< "$failure_root/config/active-slot")" == blue ]]
grep -q '^IMAGE_TAG=sha-1111111$' "$failure_root/config/release.env"
grep -q 'stop --timeout 30 backend-green' "$FAKE_LOG"
grep -q 'server backend-blue:8000;' "$failure_root/config/nginx.conf"

stop_failure_root="$root/stop-failure"
prepare_case "$stop_failure_root"
install_mock_certificate "$stop_failure_root"
printf 'blue\n' > "$stop_failure_root/config/active-slot"
printf 'BACKEND_IMAGE_REPOSITORY=old\nIMAGE_TAG=sha-1111111\n' > "$stop_failure_root/config/release.env"
export FAKE_CURL_RESULT=success FAKE_CERTBOT_FAIL=false FAKE_STOP_FAILURE=backend-blue
if run_deploy "$stop_failure_root" >/dev/null 2>&1; then
    exit 1
fi
[[ "$(< "$stop_failure_root/config/active-slot")" == blue ]]
grep -q '^IMAGE_TAG=sha-1111111$' "$stop_failure_root/config/release.env"
grep -q 'server backend-blue:8000;' "$stop_failure_root/config/nginx.conf"
grep -q 'start backend-blue' "$FAKE_LOG"
grep -q 'stop --timeout 30 backend-green' "$FAKE_LOG"

release_failure_root="$root/release-failure"
prepare_case "$release_failure_root"
install_mock_certificate "$release_failure_root"
printf 'blue\n' > "$release_failure_root/config/active-slot"
printf 'BACKEND_IMAGE_REPOSITORY=old\nIMAGE_TAG=sha-1111111\n' > "$release_failure_root/config/release.env"
export FAKE_CURL_RESULT=success FAKE_CERTBOT_FAIL=false FAKE_STOP_FAILURE='' FAKE_RELEASE_MV_FAILURE=true
if run_deploy "$release_failure_root" >/dev/null 2>&1; then
    exit 1
fi
[[ "$(< "$release_failure_root/config/active-slot")" == blue ]]
grep -q '^IMAGE_TAG=sha-1111111$' "$release_failure_root/config/release.env"
grep -q 'server backend-blue:8000;' "$release_failure_root/config/nginx.conf"
grep -q 'start backend-blue' "$FAKE_LOG"
grep -q 'stop --timeout 30 backend-green' "$FAKE_LOG"

certificate_root="$root/certificate-failure"
prepare_case "$certificate_root"
export FAKE_CURL_RESULT=success FAKE_CERTBOT_FAIL=true FAKE_STOP_FAILURE='' FAKE_RELEASE_MV_FAILURE=false
if run_deploy "$certificate_root" >/dev/null 2>&1; then
    exit 1
fi
[[ ! -e "$certificate_root/config/active-slot" ]]
[[ ! -e "$certificate_root/config/release.env" ]]
grep -q 'certbot certonly' "$FAKE_LOG"
grep -q 'stop --timeout 30 backend-blue' "$FAKE_LOG"

existing_certificate_root="$root/existing-slot-certificate-failure"
prepare_case "$existing_certificate_root"
printf 'blue\n' > "$existing_certificate_root/config/active-slot"
printf 'BACKEND_IMAGE_REPOSITORY=old\nIMAGE_TAG=sha-1111111\n' > \
    "$existing_certificate_root/config/release.env"
printf 'upstream backend_upstream { server backend-blue:8000; }\n' > \
    "$existing_certificate_root/config/nginx.conf"
export FAKE_CURL_RESULT=success FAKE_CERTBOT_FAIL=true FAKE_STOP_FAILURE='' FAKE_RELEASE_MV_FAILURE=false
if run_deploy "$existing_certificate_root" >/dev/null 2>&1; then
    exit 1
fi
[[ "$(< "$existing_certificate_root/config/active-slot")" == blue ]]
grep -q '^IMAGE_TAG=sha-1111111$' "$existing_certificate_root/config/release.env"
grep -q 'server backend-blue:8000;' "$existing_certificate_root/config/nginx.conf"
grep -q 'certbot certonly' "$FAKE_LOG"
grep -q 'exec -T nginx nginx -s reload' "$FAKE_LOG"
grep -q 'stop --timeout 30 backend-green' "$FAKE_LOG"

printf 'deploy state machine: OK\n'
