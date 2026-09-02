# 腾讯云 Lighthouse 统一管理

根目录的 `manage.sh` 是本地统一入口：一条命令即可发布代码、同步模型配置或创建微信实例；它不依赖 TCR，不需要 GitHub Secrets，本地也不需要 Docker。模型配置来自本地已被 Git 忽略的 `.env`，同步时只提取允许的七个 `AI_*` 变量并保存到服务器唯一的 `shared.env`，每位朋友的微信凭证则保存在独立 Docker 命名卷中。

## 一、服务器准备

建议使用 Ubuntu 24.04、2 核 2 GB 或更高的 Lighthouse，并安装 Docker Engine 与 Docker Compose 插件。机器人不监听公网 HTTP 端口，防火墙只需保留管理用 SSH 端口。

创建专用部署用户和目录；`docker` 组具有近似 root 的权限，因此这个用户只用于部署：

```bash
sudo useradd --create-home --shell /bin/bash deploy
sudo usermod --append --groups docker deploy
sudo install -d -o deploy -g deploy -m 700 /opt/wechat-luosuo-agent
```

为本地发布创建独立 SSH Key，只把公钥加入 `/home/deploy/.ssh/authorized_keys`。发布配置必须使用在 Lighthouse 控制台核验过指纹的 ED25519 Host Key，不能依赖首次连接时盲目信任。

## 二、模型配置

在本地 `.env` 中维护以下七个变量：

```dotenv
AI_PROVIDER=openai
AI_MODEL=your-model-name
AI_API_KEY=your-api-key
AI_BASE_URL=https://your-mainland-compatible-provider.example/v1
AI_TIMEOUT_SECONDS=60
AI_MAX_TOKENS=800
AI_INSTRUCTIONS=你是一个简洁、友好的中文 AI 助手，请直接回答用户问题。
```

执行下面的命令后，脚本只会提取这七个 `AI_*` 变量，经严格校验的 SSH 加密同步到 `/opt/wechat-luosuo-agent/shared.env`，不会把配置值打印到终端，也不会上传 `.env` 中的其他字段：

```bash
./manage.sh env
```

服务器文件固定为 `deploy:deploy 600`。已有实例会逐个重建以加载新配置；若加载失败，服务器脚本会尝试恢复上一份 `shared.env` 并再次重建。

## 三、本地连接配置

复制模板：

```bash
cp deploy/release.env.example .deploy.local.env
```

填写服务器连接信息、专用私钥的绝对路径和已核验的完整 `known_hosts` 行：

```dotenv
LIGHTHOUSE_HOST=203.0.113.10
LIGHTHOUSE_SSH_PORT=22
LIGHTHOUSE_SSH_USER=deploy
LIGHTHOUSE_SSH_PRIVATE_KEY=/absolute/path/to/wechat-luosuo-actions
LIGHTHOUSE_SSH_HOST_KEY='203.0.113.10 ssh-ed25519 AAAA...'
LIGHTHOUSE_DEPLOY_PATH=/opt/wechat-luosuo-agent
DEPLOY_IMAGE_REPOSITORY=wechat-luosuo-agent
```

`.env` 和 `.deploy.local.env` 均已被 Git 忽略。SSH 私钥正文不应写进任何环境文件，配置中只保存它的本地路径。

## 四、统一命令

提交代码后，从干净的 `main` 分支发布并更新服务器上的全部实例：

```bash
./manage.sh deploy
```

发布过程会运行测试、严格校验 SSH Host Key、上传最小构建上下文、通过腾讯云 PyPI 镜像在服务器构建 Commit SHA 镜像、逐个更新实例，并在失败时尝试回滚旧镜像。GitHub Actions 只运行测试，不接触服务器或生产凭证。

创建、交互式扫码登录并启动一个新实例：

```bash
./manage.sh add alice
```

日常管理：

```bash
./manage.sh status
./manage.sh status alice
./manage.sh logs alice
./manage.sh login alice
./manage.sh up alice
./manage.sh restart alice
./manage.sh stop alice
./manage.sh update-all
```

`add` 和 `login` 会显示二维码 URL；朋友扫码并在需要时输入配对码，凭证会写入该实例独有的 Docker Volume。按 `Ctrl+C` 退出 `logs` 只会停止查看日志，不会停止机器人。

## 五、安全、备份与故障处理

不要执行 `docker compose down --volumes`，也不要手动删除名为 `wechat-bot-<实例名>_credentials` 的卷，否则对应朋友需要重新扫码。Lighthouse 系统盘快照会包含微信凭证和模型 Token，应限制快照访问并开启腾讯云账号多因素认证。

服务器上的旧 Commit SHA 镜像用于自动回滚，不要在未确认当前版本和回滚需求前批量清理镜像。更新期间每个实例会有一次约数秒到一分钟的短暂离线，这是为了确保同一个微信账号只有一个轮询进程。
