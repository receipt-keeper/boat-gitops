#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 3 ]] || {
    printf '사용법: install-release.sh <deploy-root> <config-root> <staging-root>\n' >&2
    exit 2
}

readonly DEPLOY_ROOT="$1"
readonly CONFIG_ROOT="$2"
readonly STAGING_ROOT="$3"

[[ "$DEPLOY_ROOT" == /opt/boatlab/prod ]] || exit 2
[[ "$CONFIG_ROOT" == /etc/boatlab/prod ]] || exit 2
[[ "$STAGING_ROOT" =~ ^/tmp/boatlab-deploy\.[A-Za-z0-9]+$ ]] || exit 2

cleanup() {
    rm -rf -- "$STAGING_ROOT"
}
trap cleanup EXIT

test -s "$STAGING_ROOT/boatlab-prod.tgz"
test -s "$STAGING_ROOT/boatlab-runtime.env"
test -s "$STAGING_ROOT/boatlab-firebase.json"

sudo tar -xzf "$STAGING_ROOT/boatlab-prod.tgz" -C "$DEPLOY_ROOT"
sudo install -m 0600 "$STAGING_ROOT/boatlab-runtime.env" "$CONFIG_ROOT/runtime.env"
sudo install -m 0600 "$STAGING_ROOT/boatlab-firebase.json" \
    "$CONFIG_ROOT/firebase/service-account.json"
sudo chown -R root:root "$DEPLOY_ROOT" "$CONFIG_ROOT"
sudo chmod 0750 "$DEPLOY_ROOT/bootstrap.sh" "$DEPLOY_ROOT/deploy.sh" \
    "$DEPLOY_ROOT/renew-certificate.sh" "$DEPLOY_ROOT/run-release.sh"
sudo install -m 0644 "$DEPLOY_ROOT/boatlab-scheduler.service" \
    /etc/systemd/system/boatlab-scheduler.service
sudo install -m 0644 "$DEPLOY_ROOT/boatlab-scheduler.timer" \
    /etc/systemd/system/boatlab-scheduler.timer
sudo install -m 0644 "$DEPLOY_ROOT/boatlab-certbot-renew.service" \
    /etc/systemd/system/boatlab-certbot-renew.service
sudo install -m 0644 "$DEPLOY_ROOT/boatlab-certbot-renew.timer" \
    /etc/systemd/system/boatlab-certbot-renew.timer
sudo systemctl daemon-reload

cleanup
trap - EXIT
