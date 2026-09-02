#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG_FILE=${DEPLOY_CONFIG_FILE:-$ROOT_DIR/.deploy.local.env}

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

[[ -f "$CONFIG_FILE" ]] || die "缺少 $CONFIG_FILE；请复制 deploy/release.env.example 后填写"

# 这是仅由当前用户维护的本地配置文件；它已被 .gitignore 排除。
# shellcheck disable=SC1090
source "$CONFIG_FILE"

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

image_repository=${DEPLOY_IMAGE_REPOSITORY:-wechat-luosuo-agent}
[[ "$image_repository" =~ ^[a-zA-Z0-9._/-]+$ ]] || die "DEPLOY_IMAGE_REPOSITORY 格式无效"

command -v git >/dev/null 2>&1 || die "本机未安装 git"
command -v ssh >/dev/null 2>&1 || die "本机未安装 ssh"
command -v scp >/dev/null 2>&1 || die "本机未安装 scp"

branch=$(git -C "$ROOT_DIR" branch --show-current)
[[ "$branch" == "main" ]] || die "当前分支是 $branch；只允许从 main 发布"
[[ -z $(git -C "$ROOT_DIR" status --porcelain) ]] || die "工作区有未提交改动；请先提交后再发布"

git_sha=$(git -C "$ROOT_DIR" rev-parse HEAD)
image="$image_repository:$git_sha"
stage="$LIGHTHOUSE_DEPLOY_PATH/.incoming-$git_sha"
target="$LIGHTHOUSE_SSH_USER@$LIGHTHOUSE_HOST"

if [[ -x "$ROOT_DIR/.venv/bin/python" ]]; then
  python_bin="$ROOT_DIR/.venv/bin/python"
else
  python_bin=${PYTHON_BIN:-python3}
fi

printf '运行测试...\n'
"$python_bin" -m pytest -q

known_hosts=$(mktemp "${TMPDIR:-/tmp}/wechat-luosuo-known-hosts.XXXXXX")
trap 'rm -f "$known_hosts"' EXIT
chmod 600 "$known_hosts"
printf '%s\n' "$LIGHTHOUSE_SSH_HOST_KEY" >"$known_hosts"
ssh-keygen -lf "$known_hosts" >/dev/null 2>&1 || die "LIGHTHOUSE_SSH_HOST_KEY 不是有效的 known_hosts 记录"

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

printf '上传 %s 的构建文件...\n' "$git_sha"
ssh "${ssh_args[@]}" "$target" "install -d -m 700 '$stage/deploy'"
scp "${scp_args[@]}" \
  "$ROOT_DIR/.dockerignore" \
  "$ROOT_DIR/Dockerfile" \
  "$ROOT_DIR/app.py" \
  "$ROOT_DIR/compose.yaml" \
  "$ROOT_DIR/requirements.txt" \
  "$target:$stage/"
scp "${scp_args[@]}" \
  "$ROOT_DIR/deploy/manage.sh" \
  "$ROOT_DIR/deploy/server-sync-env.sh" \
  "$ROOT_DIR/deploy/server-update.sh" \
  "$ROOT_DIR/deploy/shared.env.example" \
  "$target:$stage/deploy/"

printf '在 Lighthouse 构建并更新全部实例...\n'
ssh "${ssh_args[@]}" "$target" \
  "chmod 700 '$stage/deploy/server-update.sh' && '$stage/deploy/server-update.sh' '$LIGHTHOUSE_DEPLOY_PATH' '$stage' '$image'"

printf '发布完成：%s\n' "$image"
