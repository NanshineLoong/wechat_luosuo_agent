#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=${1:-}
STAGE_DIR=${2:-}
NEW_IMAGE=${3:-}

if [[ ! "$ROOT_DIR" =~ ^/[a-zA-Z0-9._/-]+$ ]] \
  || [[ ! "$STAGE_DIR" =~ ^/[a-zA-Z0-9._/-]+$ ]] \
  || [[ -z "$NEW_IMAGE" || ! "$NEW_IMAGE" =~ ^[a-zA-Z0-9./_:@-]+$ ]]; then
  printf '用法：%s <部署目录> <构建目录> <镜像名称>\n' "$0" >&2
  exit 1
fi

stage_name=$(basename -- "$STAGE_DIR")
if [[ $(dirname -- "$STAGE_DIR") != "$ROOT_DIR" ]] \
  || [[ ! "$stage_name" =~ ^\.incoming-[0-9a-f]{40}$ ]]; then
  printf '错误：构建目录不属于部署目录或名称无效：%s\n' "$STAGE_DIR" >&2
  exit 1
fi

cleanup() {
  if [[ -n ${tmp_file:-} ]]; then
    rm -f -- "$tmp_file"
  fi
  rm -rf -- "$STAGE_DIR"
}
trap cleanup EXIT

for required_file in \
  Dockerfile app.py compose.yaml requirements.txt \
  deploy/manage.sh deploy/server-update.sh deploy/shared.env.example; do
  [[ -f "$STAGE_DIR/$required_file" ]] || {
    printf '错误：构建目录缺少 %s\n' "$required_file" >&2
    exit 1
  }
done

[[ -f "$ROOT_DIR/shared.env" ]] || {
  printf '错误：缺少 %s/shared.env，请先创建共享模型配置\n' "$ROOT_DIR" >&2
  exit 1
}

printf '在服务器构建镜像 %s...\n' "$NEW_IMAGE"
docker build --tag "$NEW_IMAGE" "$STAGE_DIR"

install -d -m 700 "$ROOT_DIR/deploy" "$ROOT_DIR/instances"
install -m 600 "$STAGE_DIR/compose.yaml" "$ROOT_DIR/compose.yaml"
install -m 700 "$STAGE_DIR/deploy/manage.sh" "$ROOT_DIR/deploy/manage.sh"
install -m 700 "$STAGE_DIR/deploy/server-update.sh" "$ROOT_DIR/deploy/server-update.sh"
install -m 600 "$STAGE_DIR/deploy/shared.env.example" "$ROOT_DIR/deploy/shared.env.example"

OLD_IMAGE=""
if [[ -f "$ROOT_DIR/deploy.env" ]]; then
  OLD_IMAGE=$(sed -n 's/^BOT_IMAGE=//p' "$ROOT_DIR/deploy.env" | tail -n 1)
fi

if ! "$ROOT_DIR/deploy/manage.sh" update-all "$NEW_IMAGE"; then
  printf '新版本部署失败。\n' >&2
  if [[ -n "$OLD_IMAGE" && "$OLD_IMAGE" != "$NEW_IMAGE" ]]; then
    printf '正在将所有实例回滚到 %s...\n' "$OLD_IMAGE" >&2
    "$ROOT_DIR/deploy/manage.sh" update-all "$OLD_IMAGE" || \
      printf '自动回滚未完全成功，请立即人工检查。\n' >&2
  fi
  exit 1
fi

tmp_file=$(mktemp "$ROOT_DIR/.deploy.env.tmp.XXXXXX")
chmod 600 "$tmp_file"
printf 'BOT_IMAGE=%s\n' "$NEW_IMAGE" >"$tmp_file"
mv -f "$tmp_file" "$ROOT_DIR/deploy.env"
tmp_file=""

printf '全部实例已切换到 %s。\n' "$NEW_IMAGE"
