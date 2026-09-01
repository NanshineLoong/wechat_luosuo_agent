#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
COMPOSE_FILE="$ROOT_DIR/compose.yaml"
INSTANCE_DIR="$ROOT_DIR/instances"
SHARED_ENV_FILE="$ROOT_DIR/shared.env"
DEPLOY_ENV_FILE="$ROOT_DIR/deploy.env"

usage() {
  cat <<'EOF'
用法：
  deploy/manage.sh init <实例名>
  deploy/manage.sh login <实例名>
  deploy/manage.sh up <实例名>
  deploy/manage.sh stop <实例名>
  deploy/manage.sh restart <实例名>
  deploy/manage.sh logs <实例名>
  deploy/manage.sh status [实例名]
  deploy/manage.sh update-all [镜像]

实例名只能包含小写字母、数字、下划线和连字符。
EOF
}

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

validate_name() {
  local name=${1:-}
  [[ "$name" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]] \
    || die "无效实例名：${name:-<空>}"
}

read_deployed_image() {
  [[ -f "$DEPLOY_ENV_FILE" ]] || die "缺少 $DEPLOY_ENV_FILE，请先完成服务器部署"
  local image
  image=$(sed -n 's/^BOT_IMAGE=//p' "$DEPLOY_ENV_FILE" | tail -n 1)
  [[ -n "$image" ]] || die "$DEPLOY_ENV_FILE 中没有 BOT_IMAGE"
  printf '%s\n' "$image"
}

require_common_files() {
  [[ -f "$COMPOSE_FILE" ]] || die "缺少 $COMPOSE_FILE"
  [[ -f "$SHARED_ENV_FILE" ]] || die "缺少共享配置 $SHARED_ENV_FILE"
  command -v docker >/dev/null 2>&1 || die "未安装 Docker"
  docker compose version >/dev/null 2>&1 || die "未安装 Docker Compose 插件"
}

require_instance() {
  local name=$1
  [[ -d "$INSTANCE_DIR/$name" ]] || die "实例 $name 不存在，请先运行 init"
}

compose_for() {
  local name=$1
  local image=$2
  shift 2
  BOT_IMAGE="$image" \
  BOT_SHARED_ENV_FILE="$SHARED_ENV_FILE" \
    docker compose \
      --project-name "wechat-bot-$name" \
      --file "$COMPOSE_FILE" \
      "$@"
}

list_instances() {
  local path
  shopt -s nullglob
  for path in "$INSTANCE_DIR"/*; do
    [[ -d "$path" ]] && basename "$path"
  done
  shopt -u nullglob
}

command=${1:-}
case "$command" in
  init)
    name=${2:-}
    validate_name "$name"
    require_common_files
    install -d -m 700 "$INSTANCE_DIR/$name"
    printf '实例 %s 已创建；下一步运行：%s login %s\n' "$name" "$0" "$name"
    ;;
  login)
    name=${2:-}
    validate_name "$name"
    require_common_files
    require_instance "$name"
    image=$(read_deployed_image)
    compose_for "$name" "$image" stop bot >/dev/null 2>&1 || true
    compose_for "$name" "$image" run --rm --no-deps bot \
      python app.py --login-only --force-login
    printf '登录成功；运行：%s up %s\n' "$0" "$name"
    ;;
  up)
    name=${2:-}
    validate_name "$name"
    require_common_files
    require_instance "$name"
    image=$(read_deployed_image)
    compose_for "$name" "$image" up --detach --remove-orphans --wait --wait-timeout 120
    ;;
  stop)
    name=${2:-}
    validate_name "$name"
    require_common_files
    require_instance "$name"
    image=$(read_deployed_image)
    compose_for "$name" "$image" stop bot
    ;;
  restart)
    name=${2:-}
    validate_name "$name"
    require_common_files
    require_instance "$name"
    image=$(read_deployed_image)
    compose_for "$name" "$image" up --detach --force-recreate --remove-orphans --wait --wait-timeout 120
    ;;
  logs)
    name=${2:-}
    validate_name "$name"
    require_common_files
    require_instance "$name"
    image=$(read_deployed_image)
    compose_for "$name" "$image" logs --follow --tail 200 bot
    ;;
  status)
    require_common_files
    image=$(read_deployed_image)
    if [[ -n ${2:-} ]]; then
      name=$2
      validate_name "$name"
      require_instance "$name"
      compose_for "$name" "$image" ps
    else
      while IFS= read -r name; do
        printf '\n[%s]\n' "$name"
        compose_for "$name" "$image" ps
      done < <(list_instances)
    fi
    ;;
  update-all)
    require_common_files
    image=${2:-$(read_deployed_image)}
    count=0
    while IFS= read -r name; do
      printf '\n正在更新实例 %s...\n' "$name"
      compose_for "$name" "$image" up --detach --remove-orphans --wait --wait-timeout 120
      count=$((count + 1))
    done < <(list_instances)
    printf '\n已更新 %d 个实例。\n' "$count"
    ;;
  *)
    usage
    [[ -z "$command" ]] || exit 1
    ;;
esac
