#!/usr/bin/env bash
set -Eeuo pipefail

readonly DEPLOY_ROOT="/opt/boatlab/prod"
readonly COMPOSE_FILE="${DEPLOY_ROOT}/compose.yaml"
readonly RELEASE_ENV_FILE="/etc/boatlab/prod/release.env"

if [[ -z "${IMAGE_TAG:-}" ]]; then
    [[ -s "$RELEASE_ENV_FILE" ]] || {
        printf '오류: release env 파일이 없습니다: %s\n' "$RELEASE_ENV_FILE" >&2
        exit 1
    }
    while IFS='=' read -r key value; do
        case "$key" in
            BACKEND_IMAGE_REPOSITORY) BACKEND_IMAGE_REPOSITORY="$value" ;;
            IMAGE_TAG) IMAGE_TAG="$value" ;;
            IMAGE_DIGEST) IMAGE_DIGEST="$value" ;;
        esac
    done < "$RELEASE_ENV_FILE"
fi

[[ "${IMAGE_TAG:-}" =~ ^sha-[0-9a-f]{7,64}$ ]] || {
    printf '오류: release image tag가 올바르지 않습니다.\n' >&2
    exit 1
}
[[ "${IMAGE_DIGEST:-}" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    printf '오류: release image digest가 올바르지 않습니다.\n' >&2
    exit 1
}

export COMPOSE_PROJECT_NAME=boatlab-prod
export BACKEND_IMAGE_REPOSITORY="${BACKEND_IMAGE_REPOSITORY:-ghcr.io/receipt-keeper/boat-backend}"
export IMAGE_TAG
export IMAGE_DIGEST
export RUNTIME_ENV_FILE=/etc/boatlab/prod/runtime.env
export NGINX_CONFIG_ROOT=/etc/boatlab/prod/nginx

docker compose --project-name "$COMPOSE_PROJECT_NAME" --file "$COMPOSE_FILE" \
    run --rm --no-deps certbot renew --webroot -w /var/www/certbot \
    --quiet --no-random-sleep-on-renew "$@"

nginx_container="$(docker compose --project-name "$COMPOSE_PROJECT_NAME" --file "$COMPOSE_FILE" ps -q nginx)"
if [[ -n "$nginx_container" ]] && [[ "$(docker inspect --format '{{.State.Running}}' "$nginx_container")" == "true" ]]; then
    docker compose --project-name "$COMPOSE_PROJECT_NAME" --file "$COMPOSE_FILE" exec -T nginx nginx -t
    docker compose --project-name "$COMPOSE_PROJECT_NAME" --file "$COMPOSE_FILE" exec -T nginx nginx -s reload
fi
