#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 2 ]] || {
    printf '사용법: validate-runtime.sh <runtime-env> <firebase-json>\n' >&2
    exit 2
}

python3 - "$1" "$2" <<'PY'
import json
import re
import sys

env_path, firebase_path = sys.argv[1:]
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

required = (
    "DATABASE_URL",
    "JWT_SECRET_KEY",
    "REFRESH_TOKEN_PEPPER",
    "PROMOTION_BENEFICIARY_HMAC_SECRET",
    "OPENROUTER_API_KEY",
    "OPENROUTER_MODEL",
    "S3_BUCKET",
    "S3_REGION",
    "FIREBASE_PROJECT_ID",
)
missing = [key for key in required if not values.get(key)]
if missing:
    raise SystemExit("runtime env 필수 항목이 누락되었습니다: " + ", ".join(missing))

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
    "PUSH_SEND_ENABLED": "true",
    "PUSH_TOKEN_STALE_DAYS": "60",
    "OUTBOX_POLLER_ENABLED": "true",
}
invalid = [key for key, expected_value in expected.items() if values.get(key) != expected_value]
if invalid:
    raise SystemExit("runtime env 고정값이 올바르지 않습니다: " + ", ".join(invalid))
if not values["DATABASE_URL"].startswith("postgresql+asyncpg://"):
    raise SystemExit("DATABASE_URL은 postgresql+asyncpg:// 형식이어야 합니다.")
if any(values.get(key) for key in ("S3_ACCESS_KEY_ID", "S3_SECRET_ACCESS_KEY")):
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
