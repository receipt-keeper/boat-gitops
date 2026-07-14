#!/usr/bin/env bash
set -Eeuo pipefail

readonly DEPLOY_ROOT="/opt/boatlab/prod"
readonly IMAGE_REPOSITORY="ghcr.io/receipt-keeper/boat-backend"

[[ "$(id -u)" -eq 0 ]] || {
    printf '오류: run-release.sh는 root 권한으로 실행해야 합니다.\n' >&2
    exit 1
}
[[ "${IMAGE_TAG:-}" =~ ^sha-[0-9a-f]{7,64}$ ]] || exit 2
[[ "${LETSENCRYPT_EMAIL:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._%+-]*@([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || exit 2

expected_digest="$(< "$DEPLOY_ROOT/config/image-digest")"
[[ "$expected_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 2
resolved_digest="$(docker buildx imagetools inspect \
    "$IMAGE_REPOSITORY:$IMAGE_TAG" --format '{{.Manifest.Digest}}')"
[[ "$resolved_digest" == "$expected_digest" ]] || {
    printf '오류: GHCR image tag와 저장소 digest가 일치하지 않습니다.\n' >&2
    exit 1
}

systemctl stop boatlab-scheduler.timer >/dev/null 2>&1 || true
systemctl stop boatlab-scheduler.service >/dev/null 2>&1 || true
systemctl stop boatlab-certbot-renew.timer >/dev/null 2>&1 || true
systemctl stop boatlab-certbot-renew.service >/dev/null 2>&1 || true

LETSENCRYPT_EMAIL="$LETSENCRYPT_EMAIL" "$DEPLOY_ROOT/scripts/deploy.sh" deploy "$IMAGE_TAG"

systemctl enable --now boatlab-scheduler.timer boatlab-certbot-renew.timer
systemctl is-active --quiet boatlab-scheduler.timer
systemctl is-active --quiet boatlab-certbot-renew.timer
