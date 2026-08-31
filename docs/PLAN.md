# 微信 ClawBot 最小 AI Chatbot 实现计划

## 一、目标

使用 `corespeed-io/wechatbot` 接入微信 ClawBot，以 `PydanticAI` 调用大模型，实现一个仅支持文本问答的最小 Python AI Chatbot，完全不依赖 OpenClaw，也不包含工具、记忆、数据库或多轮上下文。

## 二、技术方案

- Python 3.11+
- `wechatbot-sdk`：微信登录、接收消息和发送回复
- `pydantic-ai`：定义 Agent 并调用模型
- `python-dotenv`：读取本地环境变量
- `pytest`：基础测试
- 支持 OpenAI Chat Completions-compatible 与 Anthropic Messages-compatible 模型接口，通过环境变量切换 Provider、模型、API Key 和 Base URL

数据流程：

```text
微信文本消息
    → wechatbot-sdk 消息处理函数
    → PydanticAI Agent
    → 大模型 API
    → 将文本结果回复至微信
```

## 三、项目结构

```text
wechat-ai-chatbot/
├── app.py
├── requirements.txt
├── requirements-dev.txt
├── .env.example
├── .gitignore
├── pytest.ini
├── README.md
└── tests/
    └── test_chatbot.py
```

## 四、实现步骤

1. 初始化 Python 项目，加入 `wechatbot-sdk`、`pydantic-ai-slim[openai,anthropic]`、`python-dotenv` 和测试依赖。
2. 在 `.env.example` 中定义 `AI_PROVIDER`、`AI_MODEL`、`AI_API_KEY` 和可选的 `AI_BASE_URL`，真实密钥只保存在未提交的 `.env`。
3. 创建无工具的 `PydanticAI Agent`，设置简短中文 instructions，例如“你是一个简洁、友好的中文 AI 助手”。
4. 创建 `WeChatBot`，注册文本消息处理函数，将消息文本传入 `agent.run()`。
5. 获取 `result.output` 后调用微信 SDK 回复原消息；不传入 `message_history`，每条消息均为独立会话。
6. 对非文本消息返回“不支持此消息类型”或直接忽略；模型超时或调用失败时记录异常并回复统一错误提示。
7. 在 README 中记录安装依赖、配置 `.env`、二维码登录、启动和停止方法。
8. OpenAI-compatible 接口显式使用 `OpenAIChatModel`，Anthropic-compatible 接口显式使用 `AnthropicModel`，避免把两种协议混用。

## 五、测试与验收

- 模拟文本消息，确认消息内容被传入 Agent，并将模型输出回复至原微信会话。
- 模拟模型异常，确认机器人回复错误提示且主进程不退出。
- 扫码登录 ClawBot，发送普通中文问题并收到有效 AI 回复。
- 连续发送两条有关联的问题，确认第二条不会自动获得第一条的历史。
- 发送图片或语音，确认机器人不会错误传给文本模型。
- 检查代码和日志，确认 API Key 不会被输出或提交。
- 分别构造 OpenAI 与 Anthropic Provider，确认自定义 Base URL 被正确传入发布版 SDK。

## 六、范围与默认约定

第一版只支持个人微信 ClawBot 的文本问答，不支持群聊、图片理解、语音、流式输出、工具调用、长期记忆、多轮历史、用户权限、主动消息和管理后台；OpenClaw 不安装、不启动，也不参与人格、工具或上下文管理。
