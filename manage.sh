#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_CONFIG_FILE=${DEPLOY_CONFIG_FILE:-$ROOT_DIR/.deploy.local.env}
APP_ENV_FILE=${APP_ENV_FILE:-$ROOT_DIR/.env}
known_hosts=""
shared_env_temp=""

usage() {
  cat <<'EOF'
用法：
  ./manage.sh deploy              测试、上传、远端构建并更新全部实例
  ./manage.sh env                 同步本地 .env 的 AI_* 配置并重启全部实例
  ./manage.sh add <实例名>        创建、扫码登录并启动一个新实例
  ./manage.sh login <实例名>      重新扫码登录
  ./manage.sh up <实例名>         启动实例
  ./manage.sh stop <实例名>       停止实例
  ./manage.sh restart <实例名>    重启实例
  ./manage.sh logs <实例名>       持续查看日志
  ./manage.sh status [实例名]     查看一个或全部实例
  ./manage.sh update-all          用当前镜像重建全部实例

实例名只能包含小写字母、数字、下划线和连字符。
EOF
}

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$known_hosts" ]]; then
    rm -f -- "$known_hosts"
  fi
  if [[ -n "$shared_env_temp" ]]; then
    rm -f -- "$shared_env_temp"
  fi
}
trap cleanup EXIT

validate_name() {
  local name=${1:-}
  [[ "$name" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]] \
    || die "无效实例名：${name:-<空>}"
}

load_connection() {
  [[ -f "$DEPLOY_CONFIG_FILE" ]] \
    || die "缺少 $DEPLOY_CONFIG_FILE；请复制 deploy/release.env.example 后填写"

  # shellcheck disable=SC1090
  source "$DEPLOY_CONFIG_FILE"

  : "${LIGHTHOUSE_HOST:?缺少 LIGHTHOUSE_HOST}"
  : "${LIGHTHOUSE_SSH_PORT:?缺少 LIGHTHOUSE_SSH_PORT}"
  : "${LIGHTHOUSE_SSH_USER:?缺少 LIGHTHOUSE_SSH_USER}"
  : "${LIGHTHOUSE_SSH_PRIVATE_KEY:?缺少 LIGHTHOUSE_SSH_PRIVATE_KEY}"
  : "${LIGHTHOUSE_SSH_HOST_KEY:?缺少 LIGHTHOUSE_SSH_HOST_KEY}"
  : "${LIGHTHOUSE_DEPLOY_PATH:?缺少 LIGHTHOUSE_DEPLOY_PATH}"

  [[ "$LIGHTHOUSE_HOST" =~ ^[a-zA-Z0-9.:-]+$ ]] || die "LIGHTHOUSE_HOST 格式无效"
  [[ "$LIGHTHOUSE_SSH_PORT" =~ ^[0-9]+$ ]] || die "LIGHTHOUSE_SSH_PORT 格式无效"
  [[ "$LIGHTHOUSE_SSH_USER" =~ ^[a-zA-Z0-9._-]+$ ]] || die "LIGHTHOUSE_SSH_USER 格式无效"
  [[ "$LIGHTHOUSE_DEPLOY_PATH" =~ ^/[a-zA-Z0-9._/-]+$ ]] || die "LIGHTHOUSE_DEPLOY_PATH 格式无效"
  [[ -f "$LIGHTHOUSE_SSH_PRIVATE_KEY" ]] || die "SSH 私钥不存在：$LIGHTHOUSE_SSH_PRIVATE_KEY"

  command -v ssh >/dev/null 2>&1 || die "本机未安装 ssh"
  command -v scp >/dev/null 2>&1 || die "本机未安装 scp"

  known_hosts=$(mktemp "${TMPDIR:-/tmp}/wechat-luosuo-known-hosts.XXXXXX")
  chmod 600 "$known_hosts"
  printf '%s\n' "$LIGHTHOUSE_SSH_HOST_KEY" >"$known_hosts"
  ssh-keygen -lf "$known_hosts" >/dev/null 2>&1 \
    || die "LIGHTHOUSE_SSH_HOST_KEY 不是有效的 known_hosts 记录"

  target="$LIGHTHOUSE_SSH_USER@$LIGHTHOUSE_HOST"
  ssh_args=(
    -i "$LIGHTHOUSE_SSH_PRIVATE_KEY"
    -p "$LIGHTHOUSE_SSH_PORT"
    -o BatchMode=yes
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$known_hosts"
  )
  scp_args=(
    -i "$LIGHTHOUSE_SSH_PRIVATE_KEY"
    -P "$LIGHTHOUSE_SSH_PORT"
    -o BatchMode=yes
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$known_hosts"
  )
}

remote_manage() {
  local mode=$1
  local command=$2
  local name=${3:-}
  local remote_command="'$LIGHTHOUSE_DEPLOY_PATH/deploy/manage.sh' '$command'"
  if [[ -n "$name" ]]; then
    remote_command+=" '$name'"
  fi
  if [[ "$mode" == interactive ]]; then
    ssh -t "${ssh_args[@]}" "$target" "$remote_command"
  else
    ssh "${ssh_args[@]}" "$target" "$remote_command"
  fi
}

sync_env() {
  [[ -f "$APP_ENV_FILE" ]] || die "缺少 $APP_ENV_FILE"
  shared_env_temp=$(mktemp "${TMPDIR:-/tmp}/wechat-luosuo-shared-env.XXXXXX")
  chmod 600 "$shared_env_temp"

  awk -F= '
    /^(AI_PROVIDER|AI_MODEL|AI_API_KEY|AI_BASE_URL|AI_TIMEOUT_SECONDS|AI_MAX_TOKENS|AI_INSTRUCTIONS)=/ { print }
  ' "$APP_ENV_FILE" >"$shared_env_temp"

  local key count
  for key in \
    AI_PROVIDER AI_MODEL AI_API_KEY AI_BASE_URL \
    AI_TIMEOUT_SECONDS AI_MAX_TOKENS AI_INSTRUCTIONS; do
    count=$(grep -c "^${key}=" "$shared_env_temp" || true)
    [[ "$count" == 1 ]] || {
      die "$APP_ENV_FILE 中的 $key 必须且只能出现一次"
    }
  done
  grep -q '^AI_PROVIDER=..*' "$shared_env_temp" || die "AI_PROVIDER 不能为空"
  grep -q '^AI_MODEL=..*' "$shared_env_temp" || die "AI_MODEL 不能为空"
  grep -q '^AI_API_KEY=..*' "$shared_env_temp" || die "AI_API_KEY 不能为空"

  printf '同步模型配置并重启全部实例；配置值不会显示在终端...\n'
  scp "${scp_args[@]}" \
    "$shared_env_temp" \
    "$target:$LIGHTHOUSE_DEPLOY_PATH/.shared.env.incoming"
  scp "${scp_args[@]}" \
    "$ROOT_DIR/deploy/server-sync-env.sh" \
    "$target:$LIGHTHOUSE_DEPLOY_PATH/.server-sync-env.incoming"
  rm -f -- "$shared_env_temp"
  shared_env_temp=""

  ssh "${ssh_args[@]}" "$target" \
    "chmod 700 '$LIGHTHOUSE_DEPLOY_PATH/.server-sync-env.incoming' && '$LIGHTHOUSE_DEPLOY_PATH/.server-sync-env.incoming' '$LIGHTHOUSE_DEPLOY_PATH' '$LIGHTHOUSE_DEPLOY_PATH/.shared.env.incoming'"
}

command=${1:-help}
case "$command" in
  help|-h|--help)
    usage
    ;;
  deploy)
    exec "$ROOT_DIR/deploy/release.sh"
    ;;
  env)
    load_connection
    sync_env
    ;;
  add)
    name=${2:-}
    validate_name "$name"
    load_connection
    remote_manage normal init "$name"
    remote_manage interactive login "$name"
    remote_manage normal up "$name"
    remote_manage normal status "$name"
    ;;
  login|logs)
    name=${2:-}
    validate_name "$name"
    load_connection
    remote_manage interactive "$command" "$name"
    ;;
  up|stop|restart)
    name=${2:-}
    validate_name "$name"
    load_connection
    remote_manage normal "$command" "$name"
    ;;
  status)
    name=${2:-}
    if [[ -n "$name" ]]; then
      validate_name "$name"
    fi
    load_connection
    remote_manage normal status "$name"
    ;;
  update-all)
    load_connection
    remote_manage normal update-all
    ;;
  *)
    usage
    exit 1
    ;;
esac
