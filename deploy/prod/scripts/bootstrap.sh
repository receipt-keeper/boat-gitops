#!/usr/bin/env bash
set -Eeuo pipefail

readonly DEPLOY_ROOT="/opt/boatlab/prod"
readonly CONFIG_ROOT="/etc/boatlab/prod"
readonly CERTBOT_WEBROOT="/var/www/boatlab-certbot"

[[ "$(id -u)" -eq 0 ]] || {
    printf '오류: bootstrap.sh는 root 권한으로 실행해야 합니다.\n' >&2
    exit 1
}

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y ca-certificates curl gnupg ufw

install -m 0755 -d /etc/apt/keyrings
if [[ ! -s /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod 0644 /etc/apt/keyrings/docker.asc
fi

version_codename="$(awk -F= '$1 == "VERSION_CODENAME" {gsub(/"/, "", $2); print $2}' /etc/os-release)"
[[ -n "$version_codename" ]] || {
    printf '오류: Ubuntu codename을 확인할 수 없습니다.\n' >&2
    exit 1
}
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$(dpkg --print-architecture)" "$version_codename" \
    > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

install -d -o root -g root -m 0750 "$DEPLOY_ROOT" "$CONFIG_ROOT" "$CONFIG_ROOT/firebase" "$CONFIG_ROOT/nginx"
install -d -o root -g root -m 0755 /etc/letsencrypt "$CERTBOT_WEBROOT"

docker version >/dev/null
docker compose version >/dev/null

printf 'Boatlab 운영 서버 bootstrap 완료\n'
