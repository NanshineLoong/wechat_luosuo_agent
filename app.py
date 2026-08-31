from __future__ import annotations

import asyncio
import logging
import os
from dataclasses import dataclass
from typing import Literal, Mapping, Protocol

from dotenv import load_dotenv
from pydantic_ai import Agent
from pydantic_ai.models.anthropic import AnthropicModel
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.providers.anthropic import AnthropicProvider
from pydantic_ai.providers.openai import OpenAIProvider
from pydantic_ai.settings import ModelSettings
from wechatbot import IncomingMessage, WeChatBot

logger = logging.getLogger(__name__)

DEFAULT_INSTRUCTIONS = "你是一个简洁、友好的中文 AI 助手，请直接回答用户问题。"
TIMEOUT_REPLY = "抱歉，回答超时了，请稍后再试。"
ERROR_REPLY = "抱歉，暂时无法回答，请稍后再试。"

ProviderName = Literal["openai", "anthropic"]


@dataclass(frozen=True, slots=True)
class Settings:
    provider: ProviderName
    model: str
    api_key: str
    base_url: str | None
    timeout_seconds: float
    max_tokens: int
    instructions: str = DEFAULT_INSTRUCTIONS


class AgentResult(Protocol):
    output: str


class ChatAgent(Protocol):
    async def run(self, user_prompt: str) -> AgentResult: ...


class ReplyBot(Protocol):
    async def send_typing(self, user_id: str) -> None: ...

    async def reply(self, msg: IncomingMessage, text: str) -> None: ...


def _required(env: Mapping[str, str], name: str) -> str:
    value = env.get(name, "").strip()
    if not value:
        raise ValueError(f"缺少必填环境变量 {name}")
    return value


def _positive_float(env: Mapping[str, str], name: str, default: str) -> float:
    raw = env.get(name, default).strip()
    try:
        value = float(raw)
    except ValueError as exc:
        raise ValueError(f"环境变量 {name} 必须是数字") from exc
    if value <= 0:
        raise ValueError(f"环境变量 {name} 必须大于 0")
    return value


def _positive_int(env: Mapping[str, str], name: str, default: str) -> int:
    raw = env.get(name, default).strip()
    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(f"环境变量 {name} 必须是整数") from exc
    if value <= 0:
        raise ValueError(f"环境变量 {name} 必须大于 0")
    return value


def load_settings(environ: Mapping[str, str] | None = None) -> Settings:
    if environ is None:
        load_dotenv()
        environ = os.environ

    provider = environ.get("AI_PROVIDER", "openai").strip().lower()
    if provider not in {"openai", "anthropic"}:
        raise ValueError("环境变量 AI_PROVIDER 只能是 openai 或 anthropic")

    base_url = environ.get("AI_BASE_URL", "").strip() or None
    instructions = environ.get("AI_INSTRUCTIONS", "").strip() or DEFAULT_INSTRUCTIONS

    return Settings(
        provider=provider,
        model=_required(environ, "AI_MODEL"),
        api_key=_required(environ, "AI_API_KEY"),
        base_url=base_url,
        timeout_seconds=_positive_float(environ, "AI_TIMEOUT_SECONDS", "60"),
        max_tokens=_positive_int(environ, "AI_MAX_TOKENS", "800"),
        instructions=instructions,
    )


def build_agent(settings: Settings) -> Agent[None, str]:
    model_settings = ModelSettings(max_tokens=settings.max_tokens)

    if settings.provider == "openai":
        model = OpenAIChatModel(
            settings.model,
            provider=OpenAIProvider(
                api_key=settings.api_key,
                base_url=settings.base_url,
            ),
            settings=model_settings,
        )
    else:
        model = AnthropicModel(
            settings.model,
            provider=AnthropicProvider(
                api_key=settings.api_key,
                base_url=settings.base_url,
            ),
            settings=model_settings,
        )

    return Agent(model, instructions=settings.instructions)


async def handle_message(
    msg: IncomingMessage,
    bot: ReplyBot,
    agent: ChatAgent,
    timeout_seconds: float,
) -> None:
    if msg.type != "text" or not msg.text.strip():
        logger.info("忽略非文本或空消息，user_id=%s，type=%s", msg.user_id, msg.type)
        return

    try:
        await bot.send_typing(msg.user_id)
    except Exception:
        logger.warning("发送输入状态失败，user_id=%s", msg.user_id, exc_info=True)

    try:
        async with asyncio.timeout(timeout_seconds):
            result = await agent.run(msg.text.strip())
        if not isinstance(result.output, str) or not result.output.strip():
            raise ValueError("模型返回了空文本")
        reply = result.output.strip()
    except TimeoutError:
        logger.warning("模型调用超时，user_id=%s", msg.user_id)
        reply = TIMEOUT_REPLY
    except Exception:
        logger.exception("模型调用失败，user_id=%s", msg.user_id)
        reply = ERROR_REPLY

    await bot.reply(msg, reply)


def _show_qr_url(url: str) -> None:
    print(f"\n请在浏览器打开以下地址，并使用微信扫码确认：\n{url}\n")


def _report_wechat_error(error: Exception) -> None:
    logger.error("微信 SDK 错误（%s）：%s", type(error).__name__, error)


def build_bot(agent: ChatAgent, settings: Settings) -> WeChatBot:
    bot = WeChatBot(
        on_qr_url=_show_qr_url,
        on_error=_report_wechat_error,
        bot_agent="WechatAIChatbot/0.1.0",
    )

    @bot.on_message
    async def on_message(msg: IncomingMessage) -> None:
        await handle_message(msg, bot, agent, settings.timeout_seconds)

    return bot


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    settings = load_settings()
    agent = build_agent(settings)
    bot = build_bot(agent, settings)

    logger.info(
        "机器人启动，provider=%s，model=%s，base_url=%s",
        settings.provider,
        settings.model,
        settings.base_url or "provider default",
    )
    try:
        bot.run()
    except KeyboardInterrupt:
        logger.info("收到停止信号，机器人已退出")


if __name__ == "__main__":
    main()
