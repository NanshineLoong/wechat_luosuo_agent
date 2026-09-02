#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=${1:-}
INCOMING_ENV=${2:-}
SCRIPT_PATH=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")
BACKUP_ENV=""

if [[ ! "$ROOT_DIR" =~ ^/[a-zA-Z0-9._/-]+$ ]] \
  || [[ "$INCOMING_ENV" != "$ROOT_DIR/.shared.env.incoming" ]]; then
  printf '用法：%s <部署目录> <临时配置文件>\n' "$0" >&2
  exit 1
fi

cleanup() {
  rm -f -- "$INCOMING_ENV"
  if [[ -n "$BACKUP_ENV" ]]; then
    rm -f -- "$BACKUP_ENV"
  fi
  if [[ "$SCRIPT_PATH" == "$ROOT_DIR/.server-sync-env.incoming" ]]; then
    rm -f -- "$SCRIPT_PATH"
  fi
}
trap cleanup EXIT

[[ -f "$INCOMING_ENV" ]] || {
  printf '错误：缺少待同步配置文件\n' >&2
  exit 1
}

for key in \
  AI_PROVIDER AI_MODEL AI_API_KEY AI_BASE_URL \
  AI_TIMEOUT_SECONDS AI_MAX_TOKENS AI_INSTRUCTIONS; do
  count=$(grep -c "^${key}=" "$INCOMING_ENV" || true)
  [[ "$count" == 1 ]] || {
    printf '错误：配置中的 %s 必须且只能出现一次\n' "$key" >&2
    exit 1
  }
done

if [[ -f "$ROOT_DIR/shared.env" ]]; then
  BACKUP_ENV=$(mktemp "$ROOT_DIR/.shared.env.backup.XXXXXX")
  cp "$ROOT_DIR/shared.env" "$BACKUP_ENV"
  chmod 600 "$BACKUP_ENV"
fi

chmod 600 "$INCOMING_ENV"
mv -f "$INCOMING_ENV" "$ROOT_DIR/shared.env"
chmod 600 "$ROOT_DIR/shared.env"

if [[ -x "$ROOT_DIR/deploy/manage.sh" && -f "$ROOT_DIR/deploy.env" ]]; then
  if ! "$ROOT_DIR/deploy/manage.sh" update-all; then
    printf '新配置加载失败，正在恢复上一份 shared.env...\n' >&2
    if [[ -n "$BACKUP_ENV" ]]; then
      mv -f "$BACKUP_ENV" "$ROOT_DIR/shared.env"
      BACKUP_ENV=""
      "$ROOT_DIR/deploy/manage.sh" update-all || \
        printf '自动恢复未完全成功，请立即人工检查。\n' >&2
    fi
    exit 1
  fi
fi

printf '模型配置已同步，shared.env 权限为 600。\n'
