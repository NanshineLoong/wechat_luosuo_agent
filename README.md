# 微信 ClawBot 最小 AI Chatbot

这是一个不依赖 OpenClaw 的最小微信 AI Chatbot：使用发布版 `wechatbot-sdk` 登录微信 iLink Bot/ClawBot、接收文本消息，再通过 PydanticAI 调用 OpenAI Chat Completions 或 Anthropic Messages 兼容接口并回复。

第一版只支持独立的文本问答，每条微信消息都是一次全新模型调用，不保存或传递历史记录，也不包含工具、数据库、长期记忆、图片理解、语音处理、群聊或主动消息。

## 环境要求

- Python 3.11+
- 可以扫码确认的微信客户端
- OpenAI Chat Completions 或 Anthropic Messages 兼容的模型 API

本地如存在 `pydantic-ai/` 与 `wechatbot/` 目录，它们仅用于阅读上游源码且已被 Git 忽略，本项目运行时不会导入它们；实际依赖来自 `requirements.txt` 中固定的 PyPI 发布版本。

## 安装

```bash
python3.11 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
cp .env.example .env
```

然后编辑 `.env`，填写 Provider、模型名称、API Key 和可选的 Base URL。

## Provider 配置

### OpenAI 或 OpenAI-compatible

此模式固定使用 Chat Completions API，兼容服务需要实现 `/chat/completions`。

```dotenv
AI_PROVIDER=openai
AI_MODEL=gpt-5-mini
AI_API_KEY=your-api-key
AI_BASE_URL=https://api.openai.com/v1
```

使用 OpenAI 官方服务时可以把 `AI_BASE_URL` 留空；使用第三方兼容服务时通常需要填写包含 `/v1` 的地址，具体以服务商文档为准。

### Anthropic 或 Anthropic-compatible

此模式通过 PydanticAI 的原生 `AnthropicModel` 和 `AnthropicProvider` 调用 Anthropic Messages API，而不是 OpenAI 协议。

```dotenv
AI_PROVIDER=anthropic
AI_MODEL=claude-sonnet-4-6
AI_API_KEY=your-api-key
AI_BASE_URL=https://api.anthropic.com
```

使用 Anthropic 官方服务时也可以把 `AI_BASE_URL` 留空；第三方服务必须兼容 Anthropic Python SDK 使用的 Messages API、鉴权头和响应格式，仅提供 OpenAI-compatible 接口的服务仍应选择 `AI_PROVIDER=openai`。

其他配置：

```dotenv
AI_TIMEOUT_SECONDS=60
AI_MAX_TOKENS=800
AI_INSTRUCTIONS=你是一个简洁、友好的中文 AI 助手，请直接回答用户问题。
```

`AI_INSTRUCTIONS` 可以留空以使用内置指令，`AI_MAX_TOKENS` 用于限制模型输出长度，避免一条回答被微信拆成多条消息。

## 启动

```bash
source .venv/bin/activate
python app.py
```

首次启动时终端会打印二维码内容地址，在浏览器中打开后使用微信扫码并确认；登录凭证由 SDK 默认保存到 `~/.wechatbot/credentials.json`，正常情况下重启无需再次扫码。按 `Ctrl+C` 停止机器人。

同一个微信 Bot 账号不要同时运行多个进程，否则多个长轮询实例可能互相干扰消息游标。

只完成扫码登录并保存凭证、不启动消息轮询时，可以运行：

```bash
python app.py --login-only
```

忽略已有凭证并强制重新扫码时，增加 `--force-login`。

可通过 `WECHAT_CRED_PATH` 指定凭证文件位置；这主要用于容器化多实例部署，本地留空时仍使用 `~/.wechatbot/credentials.json`。

## 腾讯云 Lighthouse 多实例部署

仓库包含非 root Docker 镜像、每位朋友独立凭证卷的 Compose 配置，以及统一的本地 `manage.sh`：`./manage.sh deploy` 通过 SSH 上传源码、在 Lighthouse 构建镜像并更新全部实例，`./manage.sh env` 安全同步本地 `.env` 中的模型配置，`./manage.sh add alice` 则创建、扫码登录并启动新实例。本地无需 Docker，GitHub Actions 只负责运行测试，也不需要配置云端部署 Secrets；完整说明见 [部署文档](docs/DEPLOY_LIGHTHOUSE.md)。

## 行为说明

- 文本消息会去除首尾空白后交给模型，并将纯文本输出回复到原会话。
- 图片、语音、文件、视频和空消息会被直接忽略，不会传给模型。
- 每次只调用 `agent.run(text)`，不传 `message_history`，因此连续消息之间没有上下文。
- 模型调用超过 `AI_TIMEOUT_SECONDS` 会回复统一超时提示，其他模型错误会回复统一错误提示，具体异常只写入本地日志。
- 当前 SDK 串行处理消息，模型回答期间后续消息需要等待；这能保证最小版本的回复顺序，但只适合低流量使用。
- 微信消息内容会被发送给 `.env` 中配置的模型服务商，请根据所用服务的隐私政策决定是否部署。

## 测试

```bash
source .venv/bin/activate
python -m pip install -r requirements-dev.txt
pytest -q
```

测试会禁止真实模型请求，并覆盖两种 Provider 构建、配置校验、文本回复、无多轮历史、非文本忽略、模型错误、超时、空输出和输入状态失败等路径。

真实微信验收建议依次验证：首次扫码、重启免扫码、普通中文问答、连续两条关联问题不继承历史、非文本不调用模型、错误 API Key 不导致进程退出，以及包含 Markdown 和下划线的回复在微信客户端中的显示效果。

## 安全注意事项

- `.env` 已加入 `.gitignore`，不要提交真实 API Key。
- SDK 的微信登录凭证同样属于敏感信息，不要复制到仓库或发送给他人。
- 日志不会记录用户消息正文和 API Key，但会记录微信用户 ID 与错误堆栈。
