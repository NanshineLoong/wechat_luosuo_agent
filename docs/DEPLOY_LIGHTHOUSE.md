# 腾讯云 Lighthouse SSH 一键部署

这套部署从本地执行一次 `deploy/release.sh`，脚本先运行测试，再严格校验 Lighthouse SSH Host Key、上传最小构建上下文、在服务器构建 `linux/amd64` 镜像并逐个更新全部实例；不依赖 TCR，不需要 GitHub Secrets，本地也不需要 Docker。模型配置只保存在服务器唯一的 `shared.env` 中，每位朋友的微信凭证则保存在独立 Docker 命名卷中。

## 一、服务器准备

建议使用 Ubuntu 24.04、2 核 2 GB 或更高的 Lighthouse，并安装 Docker Engine 与 Docker Compose 插件。机器人不监听公网 HTTP 端口，防火墙只需保留管理用 SSH 端口。

创建专用部署用户和目录；`docker` 组具有近似 root 的权限，因此这个用户只用于部署：

```bash
sudo useradd --create-home --shell /bin/bash deploy
sudo usermod --append --groups docker deploy
sudo install -d -o deploy -g deploy -m 700 /opt/wechat-luosuo-agent
```

为本地发布创建独立 SSH Key，只把公钥加入 `/home/deploy/.ssh/authorized_keys`。发布配置必须使用在 Lighthouse 控制台核验过指纹的 ED25519 Host Key，不能依赖首次连接时盲目信任。

## 二、创建唯一共享模型配置

在 Lighthouse 控制台终端中创建 `/opt/wechat-luosuo-agent/shared.env`，不要在本地创建后上传，以免 API Key 进入文件同步范围或 Shell 历史：

```bash
sudo -iu deploy nano /opt/wechat-luosuo-agent/shared.env
```

填写以下内容并替换示例值：

```dotenv
AI_PROVIDER=openai
AI_MODEL=your-model-name
AI_API_KEY=your-api-key
AI_BASE_URL=https://your-mainland-compatible-provider.example/v1
AI_TIMEOUT_SECONDS=60
AI_MAX_TOKENS=800
AI_INSTRUCTIONS=你是一个简洁、友好的中文 AI 助手，请直接回答用户问题。
```

保存后限制并验证权限，不要输出文件内容：

```bash
sudo chown deploy:deploy /opt/wechat-luosuo-agent/shared.env
sudo chmod 600 /opt/wechat-luosuo-agent/shared.env
sudo stat -c '%U:%G %a %n' /opt/wechat-luosuo-agent/shared.env
```

预期输出为 `deploy:deploy 600`。所有实例共用这一个文件，修改模型或 Key 后再次运行一键发布，所有实例会重建并加载新值。

## 三、本地发布配置

复制配置模板：

```bash
cp deploy/release.env.example .deploy.local.env
```

填写 Lighthouse 地址、SSH 端口、部署用户、专用私钥绝对路径、已核验的完整 `known_hosts` 行和部署目录：

```dotenv
LIGHTHOUSE_HOST=203.0.113.10
LIGHTHOUSE_SSH_PORT=22
LIGHTHOUSE_SSH_USER=deploy
LIGHTHOUSE_SSH_PRIVATE_KEY=/absolute/path/to/wechat-luosuo-actions
LIGHTHOUSE_SSH_HOST_KEY='203.0.113.10 ssh-ed25519 AAAA...'
LIGHTHOUSE_DEPLOY_PATH=/opt/wechat-luosuo-agent
DEPLOY_IMAGE_REPOSITORY=wechat-luosuo-agent
```

`.deploy.local.env` 已被 Git 忽略。发布脚本只允许从干净的 `main` 分支发布，镜像使用完整 Git Commit SHA 标签，因此上线内容与提交一一对应。

## 四、一键发布

确保改动已经提交到 `main`，然后在本地项目根目录执行：

```bash
./deploy/release.sh
```

脚本会依次：

1. 使用本地 `.venv` 或 `python3` 运行 `pytest`；
2. 严格校验固定的 SSH Host Key；
3. 上传 Dockerfile、运行源码、Compose 与部署脚本；
4. 通过腾讯云 PyPI 镜像源在 Lighthouse 上构建以 Git Commit SHA 命名的镜像；
5. 逐个重建已有实例并等待健康检查；
6. 全部成功后更新 `deploy.env`，失败则尝试回滚所有实例到上一镜像。

首次发布时可以还没有微信实例，脚本会安装服务器部署文件并记录初始镜像。GitHub Actions 只在推送时运行测试，不接触服务器或任何生产凭证。

## 五、添加朋友实例

首次一键发布成功后登录服务器：

```bash
cd /opt/wechat-luosuo-agent
./deploy/manage.sh init alice
./deploy/manage.sh login alice
```

`login` 会启动交互式临时容器并显示二维码 URL；朋友扫码并在需要时输入配对码，凭证会写入该实例独有的 Docker Volume。登录完成后启动后台机器人：

```bash
./deploy/manage.sh up alice
```

其他常用命令：

```bash
./deploy/manage.sh status
./deploy/manage.sh logs alice
./deploy/manage.sh restart alice
./deploy/manage.sh stop alice
./deploy/manage.sh update-all
```

不要执行 `docker compose down --volumes`，也不要手动删除名为 `wechat-bot-<实例名>_credentials` 的卷，否则对应朋友需要重新扫码登录。

## 六、安全、备份与故障处理

微信凭证保存在 Docker 命名卷中，Lighthouse 系统盘快照会包含这些数据；快照同样包含敏感 Token，应限制访问并开启腾讯云账号多因素认证。建议配置定期快照，并关注容器 `unhealthy`、反复重启或日志中的 `Session expired`。

凭证失效时执行：

```bash
cd /opt/wechat-luosuo-agent
./deploy/manage.sh login alice
./deploy/manage.sh up alice
```

服务器上的旧 Commit SHA 镜像用于自动回滚，不要在未确认当前版本和回滚需求前批量清理镜像。更新期间每个实例会有一次约数秒到一分钟的短暂离线，这是为了确保同一个微信账号只有一个轮询进程。
