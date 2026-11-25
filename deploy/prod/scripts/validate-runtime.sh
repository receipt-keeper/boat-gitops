#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    printf '사용법: validate-runtime.sh [--mode normal|stage1|stage2] <runtime-env> <firebase-json>\n' >&2
}

mode="${MAINTENANCE_MODE:-normal}"
if [[ $# -ge 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
    usage
    exit 0
fi
if [[ $# -ge 2 && "$1" == "--mode" ]]; then
    mode="$2"
    shift 2
fi

case "$mode" in
    normal|stage1|stage2) ;;
    *)
        printf '오류: 지원하지 않는 점검 모드입니다: %s\n' "$mode" >&2
        usage
        exit 2
        ;;
esac

[[ $# -eq 2 ]] || {
    usage
    exit 2
}

python3 - "$1" "$2" "$mode" <<'PY'
import json
import re
import sys

env_path, firebase_path, mode = sys.argv[1:]
values: dict[str, str] = {}
key_pattern = re.compile(r"^[A-Z][A-Z0-9_]*$")

with open(env_path, encoding="utf-8") as env_file:
    for line_number, raw_line in enumerate(env_file, start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise SystemExit(f"runtime env {line_number}행 형식이 올바르지 않습니다.")
        key, value = line.split("=", 1)
        if not key_pattern.fullmatch(key) or key in values:
            raise SystemExit(f"runtime env {line_number}행 key가 올바르지 않습니다.")
        values[key] = value

required = [
    "DB_HOST",
    "DB_PORT",
    "DB_NAME",
    "DB_USER",
    "DB_PASSWORD",
    "JWT_SECRET_KEY",
    "REFRESH_TOKEN_PEPPER",
    "PROMOTION_BENEFICIARY_HMAC_SECRET",
    "OPENROUTER_MODEL",
    "S3_BUCKET",
    "S3_REGION",
    "FIREBASE_PROJECT_ID",
]
if mode == "normal":
    required.append("OPENROUTER_API_KEY")

missing = [key for key in required if not values.get(key)]
if missing:
    raise SystemExit("runtime env 필수 항목이 누락되었습니다: " + ", ".join(missing))
if "DATABASE_URL" in values:
    raise SystemExit("운영 runtime env에는 DATABASE_URL을 넣지 않습니다.")

expected = {
    "APP_ENV": "prod",
    "JWT_ALGORITHM": "HS256",
    "JWT_ISSUER": "boat-backend",
    "JWT_AUDIENCE": "boat-api",
    "ACCESS_TOKEN_EXPIRES_MINUTES": "60",
    "REFRESH_TOKEN_EXPIRES_DAYS": "30",
    "FILE_STORAGE_BACKEND": "s3",
    "S3_REGION": "ap-northeast-2",
    "S3_ENDPOINT_URL": "",
    "FIREBASE_CHECK_REVOKED": "true",
    "PUSH_TOKEN_STALE_DAYS": "60",
}
if mode == "normal":
    expected["PUSH_SEND_ENABLED"] = "true"
    expected["OUTBOX_POLLER_ENABLED"] = "true"

invalid = [key for key, expected_value in expected.items() if values.get(key) != expected_value]
if mode != "normal":
    for bool_key in ("PUSH_SEND_ENABLED", "OUTBOX_POLLER_ENABLED"):
        if values.get(bool_key) not in ("true", "false"):
            invalid.append(bool_key)

if invalid:
    raise SystemExit("runtime env 고정값이 올바르지 않습니다: " + ", ".join(invalid))
if values["DB_PORT"] != "5432":
    raise SystemExit("DB_PORT는 5432여야 합니다.")
if any(
    values.get(key)
    for key in (
        "S3_ACCESS_KEY_ID",
        "S3_SECRET_ACCESS_KEY",
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN",
    )
):
    raise SystemExit("운영 runtime env에는 정적 S3 key를 넣지 않습니다.")

with open(firebase_path, encoding="utf-8") as firebase_file:
    firebase = json.load(firebase_file)
firebase_required = ("project_id", "private_key", "client_email")
if firebase.get("type") != "service_account" or any(
    not isinstance(firebase.get(key), str) or not firebase[key]
    for key in firebase_required
):
    raise SystemExit("Firebase 서비스 계정 JSON 형식이 올바르지 않습니다.")
if firebase["project_id"] != values["FIREBASE_PROJECT_ID"]:
    raise SystemExit("Firebase JSON project_id와 FIREBASE_PROJECT_ID가 다릅니다.")
PY
